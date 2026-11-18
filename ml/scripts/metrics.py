"""Métriques d'évaluation de l'assistant EquiPay.

Fichier partagé entre le Mac (MLX) et le PC (CUDA) : les deux machines notent les
réponses avec exactement le même code, donc leurs scores sont comparables.
Dépendances : sacrebleu, sentence-transformers (pour la similarité de sens).
"""

import math
import re
import unicodedata
from collections import Counter, defaultdict

EMBEDDING_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"

# Score global utilisé pour choisir le meilleur modèle (somme des poids = 1)
SCORE_WEIGHTS = {
    "keyword_recall": 0.30,       # contient les informations clés
    "semantic_similarity": 0.25,  # même sens que la réponse de référence
    "rouge_l": 0.15,              # mêmes formulations
    "routing_macro_f1": 0.30,     # bon comportement : répondre / support / refuser
}

# Les 3 comportements attendus (matrice de confusion)
CLASSES = ["in_scope", "support", "off_topic"]
CLASS_LABELS = {"in_scope": "réponse", "support": "support", "off_topic": "refus"}

REFUSAL_MARKERS = [
    "je peux seulement", "je ne peux aider que", "que pour equipay",
    "pas de rapport", "aucun rapport", "hors sujet",
]
SUPPORT_MARKERS = ["contacte le support", "contacter le support", "support equipay", "support@"]


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFD", text.lower())
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return re.sub(r"\s+", " ", text)


def tokens(text: str) -> list[str]:
    return re.findall(r"\w+", normalize(text))


def keyword_recall(answer: str, keywords: list) -> float:
    if not keywords:
        return 1.0
    a = normalize(answer)
    return sum(normalize(str(k)) in a for k in keywords) / len(keywords)


def _f1(overlap: int, n_answer: int, n_reference: int) -> float:
    if overlap == 0:
        return 0.0
    p, r = overlap / n_answer, overlap / n_reference
    return 2 * p * r / (p + r)


def rouge_n(answer: str, reference: str, n: int) -> float:
    """F1 des n-grammes communs (ROUGE-1, ROUGE-2)."""
    grams = lambda t: Counter(zip(*[t[i:] for i in range(n)]))  # noqa: E731
    a, r = grams(tokens(answer)), grams(tokens(reference))
    return _f1(sum((a & r).values()), sum(a.values()), sum(r.values()))


def rouge_l(answer: str, reference: str) -> float:
    """F1 de la plus longue sous-séquence commune (ROUGE-L)."""
    a, r = tokens(answer), tokens(reference)
    if not a or not r:
        return 0.0
    prev = [0] * (len(r) + 1)
    for x in a:
        cur = [0]
        for j, y in enumerate(r, 1):
            cur.append(prev[j - 1] + 1 if x == y else max(prev[j], cur[j - 1]))
        prev = cur
    return _f1(prev[-1], len(a), len(r))


def is_refusal(answer: str) -> bool:
    a = normalize(answer)
    return any(normalize(m) in a for m in REFUSAL_MARKERS)


def route(answer: str) -> str:
    """Comportement détecté dans une réponse : refus, support ou vraie réponse."""
    if is_refusal(answer):
        return "off_topic"
    a = normalize(answer)
    if any(normalize(m) in a for m in SUPPORT_MARKERS):
        return "support"
    return "in_scope"


def confusion_matrix(rows: list[dict]) -> list[list[int]]:
    """matrix[attendu][prédit] dans l'ordre de CLASSES."""
    idx = {c: i for i, c in enumerate(CLASSES)}
    matrix = [[0] * len(CLASSES) for _ in CLASSES]
    for r in rows:
        matrix[idx[r["kind"]]][idx[r["predicted"]]] += 1
    return matrix


def routing_metrics(rows: list[dict]) -> dict:
    """Exactitude, précision / rappel / F1 par comportement et F1 macro."""
    m = confusion_matrix(rows)
    out, f1s = {}, []
    for i, c in enumerate(CLASSES):
        tp = m[i][i]
        predicted = sum(m[j][i] for j in range(len(CLASSES)))
        actual = sum(m[i])
        precision = tp / predicted if predicted else 0.0
        recall = tp / actual if actual else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        out.update({f"{c}_precision": precision, f"{c}_recall": recall, f"{c}_f1": f1})
        f1s.append(f1)
    out["routing_accuracy"] = sum(m[i][i] for i in range(len(CLASSES))) / max(len(rows), 1)
    out["routing_macro_f1"] = sum(f1s) / len(f1s)
    return out


_ENCODERS: dict = {}


def semantic_similarities(answers: list[str], references: list[str], device: str = "cpu") -> list[float]:
    """Similarité de sens (cosinus d'embeddings multilingues), de 0 à 1."""
    from sentence_transformers import SentenceTransformer, util

    if device not in _ENCODERS:  # chargé une seule fois (évaluations répétées pendant l'entraînement)
        _ENCODERS[device] = SentenceTransformer(EMBEDDING_MODEL, device=device)
    encoder = _ENCODERS[device]
    a = encoder.encode(answers, convert_to_tensor=True, normalize_embeddings=True)
    r = encoder.encode(references, convert_to_tensor=True, normalize_embeddings=True)
    return [max(0.0, float(x)) for x in util.cos_sim(a, r).diagonal()]


def score_rows(rows: list[dict]) -> dict:
    """Agrège toutes les métriques sur le jeu de test."""
    import sacrebleu

    ins = [r for r in rows if r["kind"] == "in_scope"]
    support = [r for r in rows if r["kind"] == "support"]
    off = [r for r in rows if r["kind"] == "off_topic"]
    mean = lambda xs: sum(xs) / len(xs) if xs else 0.0  # noqa: E731
    hyps, refs = [r["answer"] for r in ins], [r["reference"] for r in ins]
    latencies = sorted(r["latency_s"] for r in rows)
    routing = routing_metrics(rows)
    nll, n_tok = sum(r["ref_nll"] for r in ins), sum(r["ref_tokens"] for r in ins)

    metrics = {
        # Qualité des réponses aux questions sur EquiPay
        "keyword_recall": mean([r["keyword_recall"] for r in ins]),
        "semantic_similarity": mean([r["semantic_similarity"] for r in ins]),
        "rouge_1": mean([r["rouge_1"] for r in ins]),
        "rouge_2": mean([r["rouge_2"] for r in ins]),
        "rouge_l": mean([r["rouge_l"] for r in ins]),
        "bleu": sacrebleu.corpus_bleu(hyps, [refs]).score / 100,
        "chrf": sacrebleu.corpus_chrf(hyps, [refs]).score / 100,
        "perplexity": math.exp(nll / n_tok) if n_tok else float("nan"),
        # Comportement : répondre / rediriger vers le support / refuser le hors sujet
        **routing,
        "off_topic_refusal_rate": routing["off_topic_recall"],
        "support_redirect_rate": routing["support_recall"],
        "false_refusal_rate": mean([float(r["predicted"] == "off_topic") for r in ins]),
        # Question EquiPay sans réponse connue mais le modèle répond quand même (invention)
        "hallucination_rate": mean([float(r["predicted"] == "in_scope") for r in support]),
        # Question hors sujet à laquelle le modèle répond au lieu de refuser
        "off_topic_answered_rate": mean([float(r["predicted"] == "in_scope") for r in off]),
        # Question sur l'app renvoyée au support alors que la réponse était connue
        "false_support_rate": mean([float(r["predicted"] == "support") for r in ins]),
        "exact_match": mean([r.get("exact_match", 0.0) for r in ins]),
        "keyword_full_recall": mean([float(r["keyword_recall"] == 1.0) for r in ins]),
        "semantic_similarity_p10": sorted(r["semantic_similarity"] for r in ins)[len(ins) // 10]
        if ins else 0.0,
        "empty_answer_rate": mean([float(not r["answer"].strip()) for r in rows]),
        "answer_words": mean([len(tokens(r["answer"])) for r in rows]),
        # Performance
        "latency_s": mean(latencies),
        "latency_p95_s": latencies[min(len(latencies) - 1, int(0.95 * len(latencies)))],
        "tokens_per_s": sum(r["tokens"] for r in rows) / max(sum(latencies), 1e-9),
        "answer_tokens": mean([r["tokens"] for r in rows]),
        "length_ratio": mean(
            [len(tokens(r["answer"])) / max(len(tokens(r["reference"])), 1) for r in ins]
        ),
    }
    metrics["score"] = sum(metrics[k] * w for k, w in SCORE_WEIGHTS.items())
    return metrics


def per_topic(rows: list[dict]) -> list[dict]:
    """Scores moyens par sujet : montre où le modèle est bon ou faible."""
    groups = defaultdict(list)
    for r in rows:
        groups[r["topic"] if r["kind"] == "in_scope" else r["kind"]].append(r)
    table = []
    for topic, rs in sorted(groups.items()):
        n = len(rs)
        table.append({
            "topic": topic, "questions": n,
            "keyword_recall": sum(r["keyword_recall"] for r in rs) / n,
            "semantic_similarity": sum(r["semantic_similarity"] for r in rs) / n,
            "rouge_l": sum(r["rouge_l"] for r in rs) / n,
            "routing_ok": sum(r["predicted"] == r["kind"] for r in rs) / n,
        })
    return table


def score_answer(answer: str, sample: dict) -> dict:
    """Métriques d'une réponse (avant la similarité de sens, calculée par lot)."""
    return {
        "keyword_recall": keyword_recall(answer, sample["keywords"]),
        "rouge_1": rouge_n(answer, sample["reference"], 1),
        "rouge_2": rouge_n(answer, sample["reference"], 2),
        "rouge_l": rouge_l(answer, sample["reference"]),
        "exact_match": float(normalize(answer).strip() == normalize(sample["reference"]).strip()),
        "predicted": route(answer),
    }


def per_category(rows: list[dict]) -> list[dict]:
    """Scores moyens par catégorie (app, compte, thème, concurrents, support, hors sujet…)."""
    groups = defaultdict(list)
    for r in rows:
        groups[r.get("category") or r["kind"]].append(r)
    table = []
    for category, rs in sorted(groups.items()):
        n, ins = len(rs), [r for r in rs if r["kind"] == "in_scope"]
        mean = lambda xs: sum(xs) / len(xs) if xs else None  # noqa: E731
        table.append({
            "category": category, "questions": n,
            "keyword_recall": mean([r["keyword_recall"] for r in ins]),
            "semantic_similarity": mean([r["semantic_similarity"] for r in ins]),
            "rouge_l": mean([r["rouge_l"] for r in ins]),
            "routing_ok": sum(r["predicted"] == r["kind"] for r in rs) / n,
        })
    return table
