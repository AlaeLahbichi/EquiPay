"""Construit les jeux train / valid / test à partir de data/source/.

Sources :
  qa.yaml            textes communs (prompt système, refus, redirection support)
  topics/*.yaml      sujets par catégorie (app, compte, thème, concurrents…)
  support.yaml       questions sur EquiPay sans réponse connue
  off_topic.yaml     questions sans rapport

3 comportements : répondre (topics), rediriger vers le support (support_questions),
refuser le hors sujet (off_topic).

Contrôles qualité (le script s'arrête en cas d'erreur) : formulation en double,
mot-clé absent de la réponse, réponse de référence mal routée, sujet trop petit.

Découpe sans fuite : pour chaque sujet, 3 formulations vont en test et 2 en validation ;
le test ne contient que des formulations jamais vues à l'entraînement. Les questions
support / hors sujet sont découpées par blocs de 8 (3 test, 1 validation, 4 train).

Le train est augmenté : minuscules, sans accents, formules de politesse, fautes de frappe,
abréviations SMS et petits mots de fin (stp, svp, 3afak…) pour imiter l'écriture réelle
sur téléphone.

Sorties (data/processed/) :
  train.jsonl, valid.jsonl, test.jsonl   format chat de mlx-lm
  eval.jsonl                             test + métadonnées pour la notation (catégorie…)
  manifest.json                          tailles, catégories et empreinte (traçabilité MLflow)
"""

import hashlib
import json
import random
import re
import sys
import unicodedata
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent))
from common import normalize, route  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "data" / "source"
SOURCE = SOURCE_DIR / "qa.yaml"
OUT = ROOT / "data" / "processed"
SEED = 42
MIN_QUESTIONS = 8  # 3 test + 2 validation + au moins 3 pour l'entraînement


def source_files() -> list[Path]:
    """Fichiers qui définissent le jeu (ordre stable → empreinte reproductible)."""
    files = [SOURCE, *sorted((SOURCE_DIR / "topics").glob("*.yaml"))]
    files += [f for f in (SOURCE_DIR / "support.yaml", SOURCE_DIR / "off_topic.yaml") if f.exists()]
    return files


def load_source() -> dict:
    """Assemble qa.yaml, topics/*.yaml, support.yaml et off_topic.yaml en un seul dictionnaire."""
    src = yaml.safe_load(SOURCE.read_text(encoding="utf-8"))
    src.setdefault("topics", [])
    for t in src["topics"]:
        t.setdefault("category", "app")
    for path in source_files()[1:]:
        part = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for t in part.get("topics", []):
            t["category"] = part.get("category", path.stem)
            src["topics"].append(t)
        for key in ("support_questions", "off_topic"):
            src[key] = src.get(key, []) + part.get(key, [])
    return src


def check(src: dict, contact: str) -> None:
    """Contrôles qualité : arrête le script avec la liste des problèmes."""
    errors, seen = [], {}
    ids = [t["id"] for t in src["topics"]]
    errors += [f"sujet en double : {i}" for i in sorted({i for i in ids if ids.count(i) > 1})]
    blocks = [(t["id"], t["questions"]) for t in src["topics"]]
    blocks += [("support", src["support_questions"]), ("off_topic", src["off_topic"])]
    for owner, questions in blocks:
        for q in questions:
            if not isinstance(q, str):
                errors.append(f"{owner} : formulation mal lue par YAML (guillemets ?) → {q!r}")
                continue
            key = normalize(q).strip(" ?!.")
            if key in seen:
                errors.append(f"formulation en double ({seen[key]} / {owner}) : {q}")
            seen[key] = owner
    for t in src["topics"]:
        answer = normalize(clean(t["answer"], contact))
        errors += [f"{t['id']} : mot-clé absent de la réponse → {k}"
                   for k in t["keywords"] if normalize(str(k)) not in answer]
        if len(t["questions"]) < MIN_QUESTIONS:
            errors.append(f"{t['id']} : {len(t['questions'])} formulations (minimum {MIN_QUESTIONS})")
    if errors:
        raise SystemExit("Jeu de données invalide :\n  " + "\n  ".join(errors))

PREFIXES = [
    "Bonjour, ", "Salut, ", "Stp ", "S'il te plaît, ", "Dis-moi, ", "Question : ",
    "Je voudrais savoir, ", "Excuse-moi, ", "Hello, ", "Petite question, ",
]


SUFFIXES = [" stp", " svp", " merci", " 3afak", " please", " vite fait", " !!"]

# Abréviations courantes à l'écrit sur téléphone (appliquées mot entier)
SMS = {
    "comment": "cmt", "pourquoi": "pk", "quelque": "qq", "beaucoup": "bcp",
    "aujourd'hui": "auj", "toujours": "tjrs", "rendez-vous": "rdv", "message": "msg",
    "quoi": "koi", "c'est": "c", "je ne": "j", "je suis": "chui", "tu es": "t",
    "s'il te plaît": "stp", "s'il vous plaît": "svp", "bonjour": "bjr", "salut": "slt",
    "application": "appli", "dépenses": "depenses", "activité": "activite",
}


def sms(text: str) -> str:
    """Version « SMS » : abréviations courantes, sans majuscule ni point final."""
    out = re.sub(r"\s*[?!.]+$", "", text).lower()
    for long, short in SMS.items():
        out = re.sub(rf"(?<!\w){re.escape(long)}(?!\w)", short, out)
    return out


def strip_accents(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")


def typo(text: str, rng: random.Random) -> str:
    """Inverse deux lettres voisines dans un mot de plus de 4 lettres."""
    words = text.split()
    candidates = [i for i, w in enumerate(words) if len(w) > 4 and w.isalpha()]
    if not candidates:
        return text
    i = rng.choice(candidates)
    w = words[i]
    j = rng.randrange(len(w) - 1)
    words[i] = w[:j] + w[j + 1] + w[j] + w[j + 2:]
    return " ".join(words)


def variants(question: str, rng: random.Random) -> list[str]:
    """Formulations « téléphone » d'une question (sans doublon)."""
    casual = re.sub(r"\s*[?!.]+$", "", question).lower()
    lower_first = question[0].lower() + question[1:]
    polite_1, polite_2 = rng.sample(PREFIXES, 2)
    return list(dict.fromkeys([
        question,
        casual,
        strip_accents(casual),
        polite_1 + lower_first,
        polite_2 + strip_accents(casual),
        typo(question, rng),
        typo(strip_accents(casual), rng),
        sms(question),
        casual + rng.choice(SUFFIXES),
        strip_accents(sms(question)) + rng.choice(SUFFIXES),
    ]))


def chat(system: str, question: str, answer: str) -> dict:
    return {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": question},
            {"role": "assistant", "content": answer},
        ]
    }


def clean(text: str, contact: str) -> str:
    return " ".join(text.replace("{support_contact}", contact).split())


def main() -> None:
    src = load_source()
    contact = src["support_contact"]
    check(src, contact)
    system = clean(src["system"], contact)
    refusal, support = clean(src["refusal"], contact), clean(src["support"], contact)
    rng = random.Random(SEED)

    # (sujet, questions, réponse, mots-clés, comportement, nb test, nb validation, catégorie)
    groups = [
        (t["id"], t["questions"], clean(t["answer"], contact), t["keywords"], "in_scope", 3, 2,
         t["category"])
        for t in src["topics"]
    ]
    for kind, questions, answer in [
        ("support", src["support_questions"], support),
        ("off_topic", src["off_topic"], refusal),
    ]:
        qs = list(questions)
        rng.shuffle(qs)
        groups += [(f"{kind}_{i // 8}", qs[i:i + 8], answer, [], kind, 3, 1, kind)
                   for i in range(0, len(qs), 8)]

    # Contrôle : chaque réponse de référence doit être reconnue avec le bon comportement
    for topic, _, answer, _, kind, _, _, _ in groups:
        if route(answer) != kind:
            raise SystemExit(f"Réponse de référence mal routée ({topic}) : {route(answer)} au lieu de {kind}")

    splits = {"train": [], "valid": [], "test": []}
    evaluation = []
    for topic, questions, answer, keywords, kind, n_test, n_valid, category in groups:
        qs = list(questions)
        rng.shuffle(qs)
        test, valid, train = qs[:n_test], qs[n_test:n_test + n_valid], qs[n_test + n_valid:]
        for q in train:
            splits["train"] += [chat(system, v, answer) for v in variants(q, rng)]
        splits["valid"] += [chat(system, q, answer) for q in valid]
        for q in test:
            splits["test"].append(chat(system, q, answer))
            evaluation.append({
                "topic": topic, "category": category, "kind": kind, "question": q,
                "reference": answer, "keywords": keywords, "system": system,
            })

    rng.shuffle(splits["train"])
    OUT.mkdir(parents=True, exist_ok=True)
    files = {**splits, "eval": evaluation}
    for name, rows in files.items():
        with open(OUT / f"{name}.jsonl", "w", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")

    count = lambda k: sum(1 for e in evaluation if e["kind"] == k)  # noqa: E731
    digest = hashlib.sha256()
    for path in source_files():
        digest.update(path.relative_to(SOURCE_DIR).as_posix().encode() + b"\0" + path.read_bytes())
    categories = sorted({g[7] for g in groups})
    manifest = {
        "dataset_version": src.get("version", 1),
        "source_sha256": digest.hexdigest()[:12],
        "seed": SEED,
        "topics": len(src["topics"]),
        "questions_source": sum(len(g[1]) for g in groups),
        "sizes": {k: len(v) for k, v in files.items()},
        "test_by_behaviour": {k: count(k) for k in ["in_scope", "support", "off_topic"]},
        "topics_by_category": {c: sum(1 for t in src["topics"] if t["category"] == c)
                               for c in categories if c not in ("support", "off_topic")},
        "questions_by_category": {c: sum(len(g[1]) for g in groups if g[7] == c) for c in categories},
        "test_by_category": {c: sum(1 for e in evaluation if e["category"] == c) for c in categories},
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
