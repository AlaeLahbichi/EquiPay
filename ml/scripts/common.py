"""Outils partagés : chemins, MLflow, génération et métriques d'évaluation."""

import json
import math
import os
import re
import time
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import mlflow  # noqa: E402

from metrics import (  # noqa: E402,F401  (réexportés pour run.py et build_dataset.py)
    CLASS_LABELS, CLASSES, EMBEDDING_MODEL, SCORE_WEIGHTS, confusion_matrix, keyword_recall,
    normalize, per_category, per_topic, route, rouge_l, rouge_n, routing_metrics, score_answer,
    score_rows, semantic_similarities, tokens,
)

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data" / "processed"
MODELS = ROOT / "models"

EXPERIMENT = "Equipay"
REGISTERED_MODEL = "equipay-assistant"
# Serveur MLflow lancé par ml/mlflow_server.sh (partagé avec le PC d'entraînement)
TRACKING_URI = os.environ.get("EQUIPAY_MLFLOW_URI", "http://127.0.0.1:5000")


def setup_mlflow() -> None:
    mlflow.set_tracking_uri(TRACKING_URI)
    if mlflow.get_experiment_by_name(EXPERIMENT) is None:
        # Fichiers (adaptateurs, prédictions…) toujours rangés dans ml/mlartifacts
        mlflow.create_experiment(EXPERIMENT, artifact_location="mlflow-artifacts:/equipay")
    mlflow.set_experiment(EXPERIMENT)


def system_prompt() -> str:
    """Prompt système exactement comme à l'entraînement (adresse du support remplacée)."""
    import yaml

    src = yaml.safe_load((ROOT / "data" / "source" / "qa.yaml").read_text(encoding="utf-8"))
    return " ".join(src["system"].replace("{support_contact}", src["support_contact"]).split())


def dataset_info() -> dict:
    return json.loads((DATA / "manifest.json").read_text())


def load_eval() -> list[dict]:
    with open(DATA / "eval.jsonl", encoding="utf-8") as f:
        return [json.loads(line) for line in f]


# ---------------------------------------------------------------- génération

def _mx_memory(action: str):
    import mlx.core as mx

    fn = getattr(mx, f"{action}_peak_memory", None) or getattr(mx.metal, f"{action}_peak_memory")
    return fn()


class Generator:
    """Charge un modèle MLX (avec adaptateur LoRA optionnel) et répond aux questions."""

    def __init__(self, model: str, adapter: str | None = None, max_tokens: int = 160):
        from mlx.utils import tree_flatten
        from mlx_lm import load

        start = time.perf_counter()
        self.model, self.tokenizer = load(model, adapter_path=adapter)
        self.load_time_s = time.perf_counter() - start
        self.max_tokens = max_tokens
        # Taille réelle des poids chargés (quantifiés en 4 bits)
        self.model_size_gb = sum(v.nbytes for _, v in tree_flatten(self.model.parameters())) / 1e9

    def prompt(self, system: str, question: str) -> str:
        messages = [{"role": "system", "content": system}, {"role": "user", "content": question}]
        try:
            return self.tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False
            )
        except Exception:
            # Certains modèles (ex. Gemma) n'acceptent pas le rôle système
            merged = [{"role": "user", "content": f"{system}\n\n{question}"}]
            return self.tokenizer.apply_chat_template(
                merged, add_generation_prompt=True, tokenize=False
            )

    def answer(self, system: str, question: str) -> tuple[str, float, int]:
        """Renvoie (réponse, secondes, nombre de tokens générés)."""
        from mlx_lm import generate

        start = time.perf_counter()
        text = generate(
            self.model, self.tokenizer, prompt=self.prompt(system, question),
            max_tokens=self.max_tokens, verbose=False,
        )
        elapsed = time.perf_counter() - start
        text = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
        return text, elapsed, len(self.tokenizer.encode(text))

    def reference_nll(self, system: str, question: str, reference: str) -> tuple[float, int]:
        """Somme des pertes du modèle sur les tokens de la réponse de référence (→ perplexité)."""
        import mlx.core as mx
        import mlx.nn as nn

        prompt = self.prompt(system, question)
        encode = lambda t: self.tokenizer.encode(t, add_special_tokens=False)  # noqa: E731
        n_prompt, full_ids = len(encode(prompt)), encode(prompt + reference)
        if len(full_ids) <= n_prompt:
            return 0.0, 0
        ids = mx.array(full_ids)[None]
        losses = nn.losses.cross_entropy(self.model(ids[:, :-1]), ids[:, 1:], reduction="none")[0]
        answer_losses = losses[n_prompt - 1:]
        return float(answer_losses.sum()), int(answer_losses.size)


def evaluate(generator: Generator, limit: int | None = None) -> tuple[dict, list[dict]]:
    _mx_memory("reset")
    samples = load_eval()
    if limit:  # échantillon réparti sur tout le test (les 3 comportements)
        samples = samples[:: max(1, len(samples) // limit)][:limit]
    rows = []
    for i, s in enumerate(samples, 1):
        answer, latency, n_tokens = generator.answer(s["system"], s["question"])
        nll, n_ref = generator.reference_nll(s["system"], s["question"], s["reference"])
        rows.append({
            "topic": s["topic"], "category": s.get("category", s["kind"]), "kind": s["kind"],
            "question": s["question"], "answer": answer, "reference": s["reference"],
            **score_answer(answer, s),
            "latency_s": latency, "tokens": n_tokens,
            "ref_nll": nll, "ref_tokens": n_ref,
        })
        print(f"  [{i}/{len(samples)}] {s['question'][:50]}", flush=True)

    peak_gb = _mx_memory("get") / 1e9
    sims = semantic_similarities([r["answer"] for r in rows], [r["reference"] for r in rows])
    for r, sim in zip(rows, sims):
        r["semantic_similarity"] = sim

    metrics = score_rows(rows)
    metrics.update({
        "peak_memory_gb": peak_gb,
        "load_time_s": generator.load_time_s,
        "model_size_gb": generator.model_size_gb,
    })
    return metrics, rows
