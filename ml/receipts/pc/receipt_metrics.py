"""Métriques du scanner de reçus EquiPay, v2 (identiques sur le PC et le Mac : ne pas modifier).

Chaque ticket a une liste « fields » : les champs réellement annotés dans sa source. Un champ n'est
noté que sur les tickets où il est annoté (ex. SROIE n'annote pas les articles, CORD pas la date).
"""
import json
import re
import unicodedata
from difflib import SequenceMatcher
from statistics import mean, median

LABEL_THRESHOLD = 0.8
FIELDS = ["merchant", "address", "date", "amount_text", "amount", "currency", "items"]
FIELD_NAMES = {"merchant": "enseigne", "address": "adresse", "date": "date", "amount_text": "total (texte)",
               "amount": "total", "currency": "devise", "items": "articles (tous exacts)"}
OUTCOMES = ["correct", "incorrect", "manquant"]
TOTAL_ERRORS = ["correct", "virgule ignorée", "décimales en trop", "sous-total", "espèces données", "monnaie rendue",
                "carte", "taxe / service", "prix d'un article", "autre montant", "absent"]
SCORE_WEIGHTS = {"amount_accuracy": 0.35, "items_f1": 0.15, "currency_accuracy": 0.10, "date_accuracy": 0.10,
                 "merchant_accuracy": 0.10, "amount_text_accuracy": 0.05, "address_accuracy": 0.05,
                 "json_valid_rate": 0.10}


def parse_json(text):
    """Premier objet JSON de la réponse (tolère ```json … ```). None si illisible."""
    match = re.search(r"\{.*\}", text or "", re.S)
    if not match:
        return None
    try:
        value = json.loads(match.group())
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def to_number(value):
    """Montant imprimé → nombre : 75000, « 75,000 », « 11,50 », « 1.250,50 », « $1,234.56 », « CHF 164,20 »."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = re.sub(r"[^\d,.\-']", "", str(value)).replace("'", "")
    text = text.strip(".,-") if not re.match(r"^-\d", text) else text.rstrip(".,")
    if not re.search(r"\d", text):
        return None
    if re.fullmatch(r"-?\d{1,3}([.,]\d{3})+", text) and len(set(re.findall(r"[.,]", text))) == 1:
        # 75,000 ou 1.250.000 : séparateurs de milliers (aucune décimale)
        text = re.sub(r"[.,]", "", text)
    else:
        last = max(text.rfind(","), text.rfind("."))
        if last >= 0:
            text = re.sub(r"[.,]", "", text[:last]) + "." + text[last + 1:]
    try:
        return float(text)
    except ValueError:
        return None


def same_amount(a, b):
    return a is not None and b is not None and abs(a - b) <= max(0.005, 1e-6 * abs(b))


def norm(text):
    text = unicodedata.normalize("NFKD", str(text or "")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"\s+", " ", re.sub(r"[^\w]+", " ", text)).strip()


def similarity(a, b):
    a, b = norm(a), norm(b)
    if not a and not b:
        return 1.0
    return SequenceMatcher(None, a, b).ratio()


def _items(value):
    return [{"label": it.get("label") or it.get("name") or "", "price": to_number(it.get("price"))}
            for it in (value if isinstance(value, list) else []) if isinstance(it, dict)]


def _match(pred, gold, use_label, use_price):
    used, tp, sims = set(), 0, []
    for p in pred:
        best, best_sim = None, -1.0
        for j, g in enumerate(gold):
            if j in used or (use_price and not same_amount(p["price"], g["price"])):
                continue
            sim = similarity(p["label"], g["label"])
            if use_label and sim < LABEL_THRESHOLD:
                continue
            if sim > best_sim:
                best, best_sim = j, sim
        if best is not None:
            used.add(best)
            tp += 1
            sims.append(best_sim)
    return tp, sims


def _present(v):
    return v not in (None, "", [])


def score_ticket(pred, gold, fields, other_amounts=None, source=None):
    """pred : JSON du modèle (None si illisible) ; gold : cible complète ; fields : champs annotés."""
    other_amounts = other_amounts or {}
    valid = pred is not None
    pred = pred or {}
    s = {"source": source, "currency_gold": gold.get("currency") or "?", "json_valid": valid,
         "has_decimals": bool(gold.get("amount") and gold["amount"] % 1)}
    s["currency_pred"] = (str(pred.get("currency")).strip().upper() if _present(pred.get("currency")) else "absent")
    checks = {
        "merchant": lambda: similarity(pred.get("merchant"), gold["merchant"]) >= 0.8,
        "address": lambda: similarity(pred.get("address"), gold["address"]) >= 0.7,
        "date": lambda: str(pred.get("date") or "")[:10] == gold["date"],
        "amount_text": lambda: re.sub(r"\s", "", str(pred.get("amount_text") or "")) == re.sub(r"\s", "", gold["amount_text"]),
        "amount": lambda: same_amount(to_number(pred.get("amount")), to_number(gold["amount"])),
        "currency": lambda: s["currency_pred"] == str(gold["currency"]).upper(),
    }
    for f, check in checks.items():
        if f in fields:
            s[f + "_ok"] = bool(check()) if valid else False
            s[f + "_missing"] = not _present(pred.get(f))
        else:
            s[f + "_ok"] = s[f + "_missing"] = None

    g_amount, p_amount = to_number(gold.get("amount")), to_number(pred.get("amount"))
    if p_amount is None:
        err = "absent"
    elif same_amount(p_amount, g_amount):
        err = "correct"
    elif any(same_amount(p_amount, g_amount * k) for k in (10, 100, 1000)):
        err = "virgule ignorée"
    elif any(same_amount(p_amount * k, g_amount) for k in (10, 100, 1000)):
        err = "décimales en trop"
    else:
        names = {"subtotal": "sous-total", "cash": "espèces données", "change": "monnaie rendue", "card": "carte",
                 "tax": "taxe / service", "service": "taxe / service"}
        err = next((names[k] for k, v in other_amounts.items() if k in names and same_amount(p_amount, float(v))), None)
        if err is None:
            gold_prices = [g["price"] for g in _items(gold.get("items"))]
            err = "prix d'un article" if any(same_amount(p_amount, x) for x in gold_prices) else "autre montant"
    s["total_error"] = err
    s["amount_abs_error"] = abs(p_amount - g_amount) if p_amount is not None and g_amount else None
    s["amount_rel_error"] = abs(p_amount - g_amount) / g_amount if p_amount is not None and g_amount else None

    if "items" in fields:
        g_items, p_items = _items(gold.get("items")), _items(pred.get("items"))
        tp, _ = _match(p_items, g_items, use_label=True, use_price=True)
        tp_price, sims = _match(p_items, g_items, use_label=False, use_price=True)
        tp_label, _ = _match(p_items, g_items, use_label=True, use_price=False)
        s.update(n_gold=len(g_items), n_pred=len(p_items), tp=tp, tp_price=tp_price, tp_label=tp_label,
                 label_similarity=mean(sims) if sims else None, item_count_ok=len(p_items) == len(g_items),
                 items_ok=tp == len(g_items) == len(p_items), items_missing=not isinstance(pred.get("items"), list))
    else:
        s.update(n_gold=None, items_ok=None, items_missing=None)
    s["ticket_exact"] = all(s[f + "_ok"] in (None, True) for f in FIELDS)
    return s


def _prf(tp, n_pred, n_gold):
    p = tp / n_pred if n_pred else (1.0 if not n_gold else 0.0)
    r = tp / n_gold if n_gold else 1.0
    return p, r, (2 * p * r / (p + r) if p + r else 0.0)


def _slug(label):
    a = unicodedata.normalize("NFKD", label).encode("ascii", "ignore").decode().lower().replace("'", "")
    return re.sub(r"[^a-z0-9]+", "_", a).strip("_")


def aggregate(scores, latencies=None):
    n = len(scores)
    m = {"tickets": n, "json_valid_rate": sum(s["json_valid"] for s in scores) / max(n, 1)}
    for f in FIELDS[:-1]:
        noted = [s for s in scores if s[f + "_ok"] is not None]
        m[f + "_accuracy"] = sum(s[f + "_ok"] for s in noted) / len(noted) if noted else 0.0
        m[f + "_tickets"] = len(noted)
    dec = [s for s in scores if s["has_decimals"] and s["amount_ok"] is not None]
    m["amount_accuracy_decimals"] = sum(s["amount_ok"] for s in dec) / len(dec) if dec else 0.0
    m["amount_decimals_tickets"] = len(dec)
    whole = [s for s in scores if not s["has_decimals"] and s["amount_ok"] is not None]
    m["amount_accuracy_integers"] = sum(s["amount_ok"] for s in whole) / len(whole) if whole else 0.0
    items = [s for s in scores if s["n_gold"] is not None]
    gold, pred, tp = (sum(s[k] for s in items) for k in ("n_gold", "n_pred", "tp"))
    m["items_tickets"] = len(items)
    m["items_precision"], m["items_recall"], m["items_f1"] = _prf(tp, pred, gold)
    for kind in ("price", "label"):
        m[f"item_{kind}_precision"], m[f"item_{kind}_recall"], m[f"item_{kind}_f1"] = _prf(
            sum(s["tp_" + kind] for s in items), pred, gold)
    m["items_f1_macro"] = mean(_prf(s["tp"], s["n_pred"], s["n_gold"])[2] for s in items) if items else 0.0
    m["hallucinated_item_rate"] = (pred - tp) / pred if pred else 0.0
    m["missed_item_rate"] = (gold - tp) / gold if gold else 0.0
    m["item_count_accuracy"] = sum(s["item_count_ok"] for s in items) / len(items) if items else 0.0
    m["items_exact_rate"] = sum(s["items_ok"] for s in items) / len(items) if items else 0.0
    sims = [s["label_similarity"] for s in items if s.get("label_similarity") is not None]
    m["label_similarity_mean"] = mean(sims) if sims else 0.0
    m["ticket_exact_match"] = sum(s["ticket_exact"] for s in scores) / max(n, 1)
    rels = [s["amount_rel_error"] for s in scores if s["amount_rel_error"] is not None]
    m["amount_median_rel_error"] = median(rels) if rels else 0.0
    m["amount_within_1pct"] = sum(r <= 0.01 for r in rels) / max(n, 1)
    for label in TOTAL_ERRORS:
        m[f"total_{_slug(label)}_rate"] = sum(s["total_error"] == label for s in scores) / max(n, 1)
    if latencies:
        lat = sorted(latencies)
        m["latency_s"] = mean(lat)
        m["latency_p95_s"] = lat[min(len(lat) - 1, int(0.95 * len(lat)))]
    # Score global : poids renormalisés sur les champs annotés dans ce groupe de tickets
    counts = {k: m.get(k.replace("_accuracy", "_tickets"), n) for k in SCORE_WEIGHTS}
    counts["items_f1"] = m["items_tickets"]
    weights = {k: w for k, w in SCORE_WEIGHTS.items() if counts[k]}
    m["score"] = sum(w * m[k] for k, w in weights.items()) / sum(weights.values()) if weights else 0.0
    return m


BREAKDOWN_KEYS = ["tickets", "score", "amount_accuracy", "amount_accuracy_decimals", "currency_accuracy",
                  "date_accuracy", "merchant_accuracy", "items_f1", "ticket_exact_match", "total_virgule_ignoree_rate"]


def breakdown(scores, key):
    """Métriques principales par source (key='source') ou par devise (key='currency_gold')."""
    groups = {}
    for s in scores:
        groups.setdefault(s[key], []).append(s)
    out = {}
    for g, items in sorted(groups.items()):
        m = aggregate(items)
        out[g] = {k: v for k, v in m.items() if k in BREAKDOWN_KEYS
                  and (not k.endswith(("_accuracy", "_decimals"))
                       or m.get({"amount_accuracy_decimals": "amount_decimals_tickets"}.get(k, k.replace("_accuracy", "_tickets")), 1))
                  and not (k == "items_f1" and not m["items_tickets"])}
    return out


def confusion_items(scores):
    items = [s for s in scores if s["n_gold"] is not None]
    tp = sum(s["tp"] for s in items)
    return [[tp, sum(s["n_gold"] for s in items) - tp], [sum(s["n_pred"] for s in items) - tp, 0]]


def field_outcomes(scores):
    rows = []
    for f in FIELDS:
        noted = [s for s in scores if s[f + "_ok"] is not None]
        ok = sum(s[f + "_ok"] for s in noted)
        missing = sum(1 for s in noted if not s[f + "_ok"] and s[f + "_missing"])
        rows.append([ok, len(noted) - ok - missing, missing])
    return rows


def currency_confusion(scores):
    noted = [s for s in scores if s["currency_ok"] is not None]
    real = sorted({s["currency_gold"] for s in noted})
    cols = real + ["autre", "absent"]
    matrix = [[0] * len(cols) for _ in real]
    for s in noted:
        p = s["currency_pred"]
        j = cols.index(p) if p in real else (cols.index("absent") if p == "absent" else cols.index("autre"))
        matrix[real.index(s["currency_gold"])][j] += 1
    return real, cols, matrix


def total_error_counts(scores):
    return {label: sum(s["total_error"] == label for s in scores) for label in TOTAL_ERRORS}


# ------------------------------------------------------------------ graphiques

def _heatmap(ax, matrix, rows, cols, title):
    import numpy as np
    data = np.array(matrix, dtype=float)
    ax.imshow(data, cmap="Blues")
    ax.set_xticks(range(len(cols)), cols, rotation=30, ha="right")
    ax.set_yticks(range(len(rows)), rows)
    ax.set_title(title)
    top = data.max() or 1
    for i in range(len(rows)):
        for j in range(len(cols)):
            ax.text(j, i, f"{int(data[i, j])}", ha="center", va="center",
                    color="white" if data[i, j] > top / 2 else "black", fontsize=10)


def figures(scores, title):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    out = {}
    fig, ax = plt.subplots(figsize=(5, 4))
    _heatmap(ax, confusion_items(scores), ["réel : présent", "réel : absent"], ["prédit : présent", "prédit : absent"],
             f"Articles — {title}")
    fig.tight_layout()
    out["confusion_articles.png"] = fig

    fig, ax = plt.subplots(figsize=(7, 5))
    _heatmap(ax, field_outcomes(scores), [FIELD_NAMES[f] for f in FIELDS], OUTCOMES, f"Résultat par champ — {title}")
    fig.tight_layout()
    out["confusion_champs.png"] = fig

    real, cols, matrix = currency_confusion(scores)
    if real:
        fig, ax = plt.subplots(figsize=(1.2 * len(cols) + 2, 0.8 * len(real) + 2))
        _heatmap(ax, matrix, [f"réel : {r}" for r in real], cols, f"Devise — {title}")
        fig.tight_layout()
        out["confusion_devises.png"] = fig

    counts = total_error_counts(scores)
    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.barh(list(counts), list(counts.values()), color=["#16a34a"] + ["#dc2626"] * (len(counts) - 1))
    ax.invert_yaxis()
    ax.set_xlabel("tickets")
    ax.set_title(f"Ce que le modèle a mis comme total — {title}")
    fig.tight_layout()
    out["erreurs_total.png"] = fig
    return out


def comparison_figure(results):
    """results : {nom du modèle: métriques}."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    keys = ["score", "amount_accuracy", "amount_accuracy_decimals", "currency_accuracy", "date_accuracy",
            "merchant_accuracy", "items_f1", "ticket_exact_match"]
    fig, ax = plt.subplots(figsize=(11, 4.5))
    width = 0.8 / max(len(results), 1)
    for i, (name, m) in enumerate(results.items()):
        ax.bar([k + i * width - 0.4 + width / 2 for k in range(len(keys))], [m.get(k, 0) for k in keys], width, label=name)
    ax.set_xticks(range(len(keys)), keys, rotation=25, ha="right")
    ax.set_ylim(0, 1)
    ax.legend()
    ax.set_title("Comparaison sur le jeu de test v2")
    fig.tight_layout()
    return fig
