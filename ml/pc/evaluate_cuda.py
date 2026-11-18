"""Évaluation complète de l'assistant EquiPay sur GPU (PyTorch), avec les mêmes métriques que le Mac.

Utilisé à la fin de train_cuda.py (même run MLflow), ou seul pour réévaluer un run existant :

  python evaluate_cuda.py --run-id <RUN_ID>            → adaptateur du run, + modèle de base
  python evaluate_cuda.py --run-id <RUN_ID> --limit 40 → essai rapide

Ce qui est enregistré dans MLflow (préfixe gpu_eval_ pour le modèle affiné, gpu_base_eval_
pour le modèle de base sans adaptateur, afin de mesurer le gain de l'entraînement) :
  - toutes les métriques de metrics.score_rows (score global, infos clés, similarité de sens,
    ROUGE, BLEU, chrF, perplexité, routage, hallucinations, refus, longueur…)
  - les tableaux prédictions / par sujet / par catégorie
  - la matrice de confusion et un graphique par catégorie
"""

import argparse
import json
import math
import re
import tempfile
import time
from pathlib import Path

import torch

import metrics as M

HERE = Path(__file__).resolve().parent
DATA = HERE / "data" / "processed"
MAX_NEW_TOKENS = 160  # identique au Mac


def load_eval(limit: int | None = None) -> list[dict]:
    with open(DATA / "eval.jsonl", encoding="utf-8") as f:
        samples = [json.loads(line) for line in f]
    if limit:  # échantillon réparti sur tout le test (toutes catégories et comportements)
        samples = samples[:: max(1, len(samples) // limit)][:limit]
    return samples


def prompt_text(tokenizer, system: str, question: str) -> str:
    messages = [{"role": "system", "content": system}, {"role": "user", "content": question}]
    return tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)


@torch.no_grad()
def generate_answers(model, tokenizer, samples: list[dict], batch_size: int = 16) -> list[tuple[str, float, int]]:
    """Réponses en génération gloutonne (déterministe). Renvoie (réponse, secondes, tokens)."""
    model.eval()
    side = tokenizer.padding_side
    tokenizer.padding_side = "left"  # la génération continue à droite du prompt
    out = []
    try:
        for i in range(0, len(samples), batch_size):
            batch = samples[i:i + batch_size]
            prompts = [prompt_text(tokenizer, s["system"], s["question"]) for s in batch]
            enc = tokenizer(prompts, return_tensors="pt", padding=True, add_special_tokens=False).to(model.device)
            torch.cuda.synchronize() if torch.cuda.is_available() else None
            start = time.perf_counter()
            generated = model.generate(
                **enc, max_new_tokens=MAX_NEW_TOKENS, do_sample=False, temperature=None, top_p=None,
                top_k=None, pad_token_id=tokenizer.pad_token_id,
            )
            torch.cuda.synchronize() if torch.cuda.is_available() else None
            per_answer = (time.perf_counter() - start) / len(batch)  # temps amorti par question
            for row in generated[:, enc["input_ids"].shape[1]:]:
                text = tokenizer.decode(row, skip_special_tokens=True)
                text = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
                n_tokens = int((row != tokenizer.pad_token_id).sum())
                out.append((text, per_answer, n_tokens))
            print(f"  génération {min(i + batch_size, len(samples))}/{len(samples)}", flush=True)
    finally:
        tokenizer.padding_side = side
    return out


@torch.no_grad()
def reference_nll(model, tokenizer, samples: list[dict], batch_size: int = 16) -> list[tuple[float, int]]:
    """Somme des pertes sur les tokens de la réponse de référence (→ perplexité), comme sur le Mac."""
    model.eval()
    results = []
    for i in range(0, len(samples), batch_size):
        batch = samples[i:i + batch_size]
        ids, starts = [], []
        for s in batch:
            prompt = prompt_text(tokenizer, s["system"], s["question"])
            p_ids = tokenizer(prompt, add_special_tokens=False)["input_ids"]
            full = tokenizer(prompt + s["reference"], add_special_tokens=False)["input_ids"]
            ids.append(full)
            starts.append(len(p_ids))
        width = max(len(x) for x in ids)
        pad = tokenizer.pad_token_id
        input_ids = torch.tensor([x + [pad] * (width - len(x)) for x in ids], device=model.device)
        mask = torch.tensor([[1] * len(x) + [0] * (width - len(x)) for x in ids], device=model.device)
        logits = model(input_ids=input_ids, attention_mask=mask).logits.float()
        losses = torch.nn.functional.cross_entropy(
            logits[:, :-1].transpose(1, 2), input_ids[:, 1:], reduction="none"
        )
        for row, (x, start) in enumerate(zip(ids, starts)):
            answer = losses[row, start - 1:len(x) - 1]
            results.append((float(answer.sum()), int(answer.numel())))
    return results


def evaluate(model, tokenizer, samples: list[dict], batch_size: int = 16) -> tuple[dict, list[dict]]:
    """Génère, note et agrège : (métriques, lignes détaillées)."""
    if torch.cuda.is_available():
        torch.cuda.reset_peak_memory_stats()
    answers = generate_answers(model, tokenizer, samples, batch_size)
    nlls = reference_nll(model, tokenizer, samples, batch_size)
    rows = []
    for s, (answer, latency, n_tokens), (nll, n_ref) in zip(samples, answers, nlls):
        rows.append({
            "topic": s["topic"], "category": s.get("category", s["kind"]), "kind": s["kind"],
            "question": s["question"], "answer": answer, "reference": s["reference"],
            **M.score_answer(answer, s),
            "latency_s": latency, "tokens": n_tokens, "ref_nll": nll, "ref_tokens": n_ref,
        })
    device = "cuda" if torch.cuda.is_available() else "cpu"  # MPS non utilisé pour les embeddings
    sims = M.semantic_similarities([r["answer"] for r in rows], [r["reference"] for r in rows], device)
    for r, sim in zip(rows, sims):
        r["semantic_similarity"] = sim
    result = M.score_rows(rows)
    if torch.cuda.is_available():
        result["peak_gpu_mem_gb"] = torch.cuda.max_memory_allocated() / 1e9
    return result, rows


# ------------------------------------------------------------------ MLflow

def _save_fig(fig, name: str, folder: str) -> None:
    import mlflow

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / name
        fig.savefig(path, dpi=120, bbox_inches="tight")
        mlflow.log_artifact(str(path), folder)


def confusion_figure(rows: list[dict], title: str):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    matrix = M.confusion_matrix(rows)
    labels = [M.CLASS_LABELS[c] for c in M.CLASSES]
    fig, ax = plt.subplots(figsize=(6, 5))
    totals = [max(sum(r), 1) for r in matrix]
    ax.imshow([[v / t for v in r] for r, t in zip(matrix, totals)], cmap="Greens", vmin=0, vmax=1)
    for i, row in enumerate(matrix):
        for j, value in enumerate(row):
            share = value / totals[i]
            ax.text(j, i, f"{value}\n{share:.0%}", ha="center", va="center",
                    color="white" if share > 0.6 else "black", fontsize=11)
    ax.set_xticks(range(len(labels)), labels)
    ax.set_yticks(range(len(labels)), labels)
    ax.set_xlabel("Comportement du modèle (prédit)")
    ax.set_ylabel("Comportement attendu")
    ax.set_title(f"Matrice de confusion — {title}")
    fig.tight_layout()
    return fig


def category_figure(table: list[dict], title: str):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    names = [t["category"] for t in table]
    fig, ax = plt.subplots(figsize=(12, 5))
    width = 0.2
    for k, (key, label) in enumerate([("keyword_recall", "Infos clés"), ("semantic_similarity", "Sens"),
                                      ("rouge_l", "ROUGE-L"), ("routing_ok", "Bon comportement")]):
        values = [t[key] if t[key] is not None else 0 for t in table]
        ax.bar([i + (k - 1.5) * width for i in range(len(names))], values, width, label=label)
    ax.set_xticks(range(len(names)), names, rotation=30, ha="right")
    ax.set_ylim(0, 1)
    ax.set_title(f"Scores par catégorie — {title}")
    ax.legend(fontsize=8)
    fig.tight_layout()
    return fig


def log_evaluation(prefix: str, result: dict, rows: list[dict], title: str) -> None:
    """Enregistre une évaluation complète dans le run MLflow actif."""
    import mlflow
    import pandas as pd

    mlflow.log_metrics({f"{prefix}_{k}": v for k, v in result.items()
                        if isinstance(v, (int, float)) and not math.isnan(v)})
    mlflow.log_table(pd.DataFrame(rows), f"{prefix}/predictions.json")
    mlflow.log_table(pd.DataFrame(M.per_topic(rows)), f"{prefix}/per_topic.json")
    categories = M.per_category(rows)
    mlflow.log_table(pd.DataFrame(categories), f"{prefix}/per_category.json")
    for c in categories:  # une métrique par catégorie, pratique pour comparer dans l'interface
        mlflow.log_metric(f"{prefix}_cat_{c['category']}_routing_ok", c["routing_ok"])
        if c["semantic_similarity"] is not None:
            mlflow.log_metric(f"{prefix}_cat_{c['category']}_semantic_similarity", c["semantic_similarity"])
            mlflow.log_metric(f"{prefix}_cat_{c['category']}_keyword_recall", c["keyword_recall"])
    import matplotlib.pyplot as plt

    for fig, name in [(confusion_figure(rows, title), "confusion_matrix.png"),
                      (category_figure(categories, title), "per_category.png")]:
        _save_fig(fig, name, prefix)
        plt.close(fig)


def comparison_figure(base: dict, tuned: dict):
    """Modèle de base vs modèle affiné sur les principales métriques."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    keys = [("score", "Score global"), ("keyword_recall", "Infos clés"), ("semantic_similarity", "Sens"),
            ("rouge_l", "ROUGE-L"), ("routing_macro_f1", "Routage F1"),
            ("support_redirect_rate", "Redirection support"), ("off_topic_refusal_rate", "Refus hors sujet"),
            ("hallucination_rate", "Hallucinations (bas = mieux)")]
    fig, ax = plt.subplots(figsize=(12, 5))
    x = range(len(keys))
    ax.bar([i - 0.2 for i in x], [base[k] for k, _ in keys], 0.4, label="Modèle de base", color="#94A3B8")
    ax.bar([i + 0.2 for i in x], [tuned[k] for k, _ in keys], 0.4, label="Modèle affiné", color="#0D9488")
    ax.set_xticks(list(x), [label for _, label in keys], rotation=25, ha="right")
    ax.set_ylim(0, 1)
    ax.set_title("Gain de l'entraînement (même jeu de test)")
    ax.legend()
    fig.tight_layout()
    return fig


def full_evaluation(model, tokenizer, title: str, batch_size: int = 16, limit: int | None = None,
                    with_baseline: bool = True) -> dict:
    """Évalue le modèle affiné, puis le modèle de base (adaptateur désactivé), dans le run actif."""
    import matplotlib.pyplot as plt

    samples = load_eval(limit)
    print(f"Évaluation du modèle affiné sur {len(samples)} questions…", flush=True)
    tuned, rows = evaluate(model, tokenizer, samples, batch_size)
    log_evaluation("gpu_eval", tuned, rows, f"{title} (affiné)")
    print(f"  score affiné = {tuned['score']:.3f}", flush=True)
    if with_baseline:
        print("Évaluation du modèle de base (sans adaptateur)…", flush=True)
        with model.disable_adapter():
            base, base_rows = evaluate(model, tokenizer, samples, batch_size)
        log_evaluation("gpu_base_eval", base, base_rows, f"{title} (base)")
        import mlflow

        mlflow.log_metric("gpu_eval_score_gain", tuned["score"] - base["score"])
        fig = comparison_figure(base, tuned)
        _save_fig(fig, "base_vs_affine.png", "gpu_eval")
        plt.close(fig)
        print(f"  score base = {base['score']:.3f} → gain {tuned['score'] - base['score']:+.3f}", flush=True)
    return tuned


def main() -> None:
    import mlflow
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run-id", required=True, help="run MLflow qui contient l'artefact adapter/")
    parser.add_argument("--tracking-uri", default="http://192.168.1.23:5000")
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--limit", type=int, help="nombre de questions (essai rapide)")
    parser.add_argument("--no-baseline", action="store_true", help="ne pas évaluer le modèle de base")
    args = parser.parse_args()

    mlflow.set_tracking_uri(args.tracking_uri)
    run = mlflow.get_run(args.run_id)
    base_model = run.data.tags["base_model"]
    with tempfile.TemporaryDirectory() as tmp:
        adapter = mlflow.artifacts.download_artifacts(run_id=args.run_id, artifact_path="adapter", dst_path=tmp)
        tokenizer = AutoTokenizer.from_pretrained(base_model)
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token
        device = "cuda" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu")
        model = AutoModelForCausalLM.from_pretrained(base_model, dtype=torch.bfloat16).to(device)
        model = PeftModel.from_pretrained(model, adapter)
        with mlflow.start_run(run_id=args.run_id):
            full_evaluation(model, tokenizer, run.info.run_name, args.batch_size, args.limit,
                            not args.no_baseline)


if __name__ == "__main__":
    main()
