"""Métriques du modèle « Décrire la dépense » : exactitude par champ, participants (P/R/F1), répartition,
articles, détection des non-dépenses (matrice de confusion), champs inventés, détail par style."""
import json
import re
import unicodedata
from difflib import SequenceMatcher
from statistics import mean

FIELDS = ["title", "merchant", "amount", "currency", "date", "paid_by", "participants", "split", "items"]
NULLABLE = ["merchant", "currency", "date", "paid_by", "participants", "split"]
SCORE_WEIGHTS = {"is_expense_accuracy": 0.10, "amount_accuracy": 0.20, "participants_accuracy": 0.15, "paid_by_accuracy": 0.10,
                 "date_accuracy": 0.10, "split_accuracy": 0.10, "currency_accuracy": 0.05, "title_accuracy": 0.05,
                 "merchant_accuracy": 0.05, "items_f1": 0.05, "json_valid_rate": 0.05}


def parse_json(text):
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        return None
    try:
        v = json.loads(m.group())
    except json.JSONDecodeError:
        return None
    return v if isinstance(v, dict) else None


def norm(t):
    t = unicodedata.normalize("NFKD", str(t or "")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"\s+", " ", re.sub(r"[^\w]+", " ", t)).strip()


def sim(a, b):
    a, b = norm(a), norm(b)
    return 1.0 if a == b else SequenceMatcher(None, a, b).ratio()


def num(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v).replace(",", ".").replace(" ", ""))
    except ValueError:
        return None


def canon(name, members, me):
    """Nom donné par le modèle → nom de la liste (« moi » pour l'utilisateur), ou None si inconnu."""
    if not isinstance(name, str):
        return None
    if norm(name) in ("moi", "me", "ana", norm(me), f"{norm(me)} moi"):
        return "moi"
    best = max(members, key=lambda m: sim(name, m))
    return best if sim(name, best) >= 0.8 and best != me else None


def percentages(split, participants, members, me):
    """Répartition effective en % par personne (None = parts égales entre les participants indiqués)."""
    people = participants
    if isinstance(split, dict) and split.get("type") in ("percent", "amounts", "shares") and isinstance(split.get("values"), dict):
        vals = {canon(k, members, me): num(v) for k, v in split["values"].items()}
        vals = {k: v for k, v in vals.items() if k and v is not None and v > 0}
        total = sum(vals.values())
        return {k: round(100 * v / total, 1) for k, v in vals.items()} if total else None
    if not people:
        return None  # pas de participants indiqués : le formulaire applique ses valeurs par défaut
    return {p: round(100 / len(people), 1) for p in people}


def score(pred, gold, meta):
    members, me = meta["members"], meta["me"]
    valid = pred is not None
    pred = pred or {}
    s = {"style": meta["style"], "kind": meta.get("kind"), "json_valid": valid, "gold_expense": bool(gold["is_expense"]),
         "pred_expense": bool(pred.get("is_expense", True)) if valid else None,
         "split_type": (gold.get("split") or {}).get("type", "aucune") if gold["is_expense"] else "non-dépense"}
    if not gold["is_expense"]:
        s["ok_all"] = valid and s["pred_expense"] is False
        return s
    if not valid or not s["pred_expense"]:
        for f in FIELDS:
            s[f] = False
        s.update(invented={}, part_tp=0, part_pred=0, part_gold=len(gold["participants"] or []), unknown_names=0, pred_names=0,
                 item_tp=0, item_pred=0, item_gold=len(gold["items"] or []), ok_all=False)
        return s

    s["title"] = sim(pred.get("title"), gold["title"]) >= 0.8
    s["merchant"] = (gold["merchant"] is None and not pred.get("merchant")) or (gold["merchant"] is not None and sim(pred.get("merchant"), gold["merchant"]) >= 0.8)
    pa, ga = num(pred.get("amount")), num(gold["amount"])
    s["amount"] = pa is not None and ga is not None and abs(pa - ga) <= 0.01
    s["currency"] = (str(pred.get("currency") or "").upper() or None) == gold["currency"]
    s["date"] = (str(pred.get("date"))[:10] if pred.get("date") else None) == gold["date"]
    s["paid_by"] = canon(pred.get("paid_by"), members, me) == gold["paid_by"] if gold["paid_by"] else not pred.get("paid_by")

    raw_names = pred.get("participants") if isinstance(pred.get("participants"), list) else None
    p_part = [canon(n, members, me) for n in raw_names] if raw_names is not None else None
    s["pred_names"] = len(raw_names or [])
    s["unknown_names"] = sum(1 for n in (p_part or []) if n is None)
    p_set = {n for n in (p_part or []) if n}
    g_set = set(gold["participants"] or [])
    s["participants"] = (gold["participants"] is None and not raw_names) or (gold["participants"] is not None and p_set == g_set)
    s["part_tp"], s["part_pred"], s["part_gold"] = len(p_set & g_set), len(p_set), len(g_set)

    gp = percentages(gold["split"], gold["participants"], members, me)
    pp = percentages(pred.get("split"), sorted(p_set) if raw_names is not None else None, members, me)
    s["split"] = (gp is None and pp is None) or (gp is not None and pp is not None and gp.keys() == pp.keys()
                                                    and all(abs(gp[k] - pp[k]) <= 0.6 for k in gp))
    s["split_type_pred"] = (pred.get("split") or {}).get("type", "aucune") if isinstance(pred.get("split"), dict) else "aucune"

    g_items = gold["items"] or []
    p_items = [i for i in (pred.get("items") or []) if isinstance(i, dict)]
    used, tp = set(), 0
    for p in p_items:
        for j, g in enumerate(g_items):
            if j not in used and sim(p.get("label"), g["label"]) >= 0.8 and num(p.get("price")) is not None and abs(num(p.get("price")) - g["price"]) <= 0.01:
                used.add(j)
                tp += 1
                break
    s["item_tp"], s["item_pred"], s["item_gold"] = tp, len(p_items), len(g_items)
    s["items"] = tp == len(g_items) == len(p_items)
    # Champ inventé : absent de la phrase (null) mais rempli par le modèle
    s["invented"] = {f: gold[f] in (None, []) and pred.get(f) not in (None, [], "", {}) for f in NULLABLE}
    s["ok_all"] = all(s[f] for f in FIELDS)
    return s


def _prf(tp, npred, ngold):
    p = tp / npred if npred else (1.0 if not ngold else 0.0)
    r = tp / ngold if ngold else 1.0
    return p, r, (2 * p * r / (p + r) if p + r else 0.0)


def aggregate(scores, latencies=None):
    n = len(scores)
    m = {"examples": n, "json_valid_rate": sum(s["json_valid"] for s in scores) / max(n, 1)}
    # Détection des non-dépenses (classe positive = « pas une dépense »)
    tp = sum(1 for s in scores if not s["gold_expense"] and s["pred_expense"] is False)
    fp = sum(1 for s in scores if s["gold_expense"] and s["pred_expense"] is False)
    fn = sum(1 for s in scores if not s["gold_expense"] and s["pred_expense"] is not False)
    tn = n - tp - fp - fn
    m["is_expense_accuracy"] = (tp + tn) / max(n, 1)
    m["non_expense_precision"], m["non_expense_recall"], m["non_expense_f1"] = _prf(tp, tp + fp, tp + fn)
    exp = [s for s in scores if s["gold_expense"]]
    for f in FIELDS:
        m[f"{f}_accuracy"] = sum(bool(s[f]) for s in exp) / max(len(exp), 1)
    m["participants_precision"], m["participants_recall"], m["participants_f1"] = _prf(
        sum(s["part_tp"] for s in exp), sum(s["part_pred"] for s in exp), sum(s["part_gold"] for s in exp))
    m["unknown_member_rate"] = sum(s["unknown_names"] for s in exp) / max(sum(s["pred_names"] for s in exp), 1)
    m["items_precision"], m["items_recall"], m["items_f1"] = _prf(
        sum(s["item_tp"] for s in exp), sum(s["item_pred"] for s in exp), sum(s["item_gold"] for s in exp))
    with_split = [s for s in exp if s["split_type"] not in ("aucune",)]
    m["split_type_accuracy"] = sum(s.get("split_type_pred") == s["split_type"] for s in with_split) / max(len(with_split), 1)
    for f in NULLABLE:
        cand = [s for s in exp if s.get("invented") is not None and f in s["invented"]]
        m[f"invented_{f}_rate"] = sum(s["invented"][f] for s in cand) / max(len(cand), 1)
    m["invented_any_rate"] = sum(any((s.get("invented") or {}).values()) for s in exp) / max(len(exp), 1)
    m["exact_match"] = sum(bool(s["ok_all"]) for s in scores) / max(n, 1)
    if latencies:
        m["latency_s"] = mean(latencies)
    m["score"] = sum(w * m[k] for k, w in SCORE_WEIGHTS.items())
    return m


def breakdown(scores, key):
    groups = {}
    for s in scores:
        groups.setdefault(s.get(key) or "?", []).append(s)
    keep = ["examples", "score", "exact_match", "amount_accuracy", "participants_accuracy", "paid_by_accuracy", "date_accuracy",
            "split_accuracy", "currency_accuracy", "is_expense_accuracy"]
    return {g: {k: v for k, v in aggregate(items).items() if k in keep} for g, items in sorted(groups.items())}


def confusions(scores):
    tp = sum(1 for s in scores if not s["gold_expense"] and s["pred_expense"] is False)
    fp = sum(1 for s in scores if s["gold_expense"] and s["pred_expense"] is False)
    fn = sum(1 for s in scores if not s["gold_expense"] and s["pred_expense"] is not False)
    tn = len(scores) - tp - fp - fn
    types = ["aucune", "equal", "percent", "amounts", "shares"]
    split_m = [[0] * (len(types) + 1) for _ in types]
    for s in scores:
        if s["gold_expense"] and s["split_type"] in types:
            p = s.get("split_type_pred", "invalide")
            split_m[types.index(s["split_type"])][types.index(p) if p in types else len(types)] += 1
    exp = [s for s in scores if s["gold_expense"]]
    fields = [[sum(bool(s[f]) for s in exp), sum(not s[f] for s in exp)] for f in FIELDS]
    return {"depense": {"rows": ["réel : dépense", "réel : pas une dépense"], "cols": ["prédit : dépense", "prédit : pas une dépense"],
                        "matrix": [[tn, fp], [fn, tp]]},
            "repartition": {"rows": types, "cols": types + ["autre/invalide"], "matrix": split_m},
            "champs": {"rows": FIELDS, "cols": ["correct", "incorrect"], "matrix": fields}}


def figures(scores, title):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    out = {}
    for key, conf in confusions(scores).items():
        data = np.array(conf["matrix"], dtype=float)
        fig, ax = plt.subplots(figsize=(1.3 * len(conf["cols"]) + 2.5, 0.55 * len(conf["rows"]) + 2))
        ax.imshow(data, cmap="Blues")
        ax.set_xticks(range(len(conf["cols"])), conf["cols"], rotation=25, ha="right")
        ax.set_yticks(range(len(conf["rows"])), conf["rows"])
        top = data.max() or 1
        for i in range(data.shape[0]):
            for j in range(data.shape[1]):
                ax.text(j, i, int(data[i, j]), ha="center", va="center", color="white" if data[i, j] > top / 2 else "black")
        ax.set_title(f"{ {'depense': 'Dépense ou non', 'repartition': 'Type de répartition', 'champs': 'Résultat par champ'}[key]} — {title}")
        fig.tight_layout()
        out[f"confusion_{key}.png"] = fig
    return out
