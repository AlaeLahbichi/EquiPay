"""Construit le jeu de données v2 du scanner de reçus (4 sources) dans ml/receipts/pc/data/prepared/.

Chaque exemple : image + cible JSON complète + liste des champs RÉELLEMENT annotés (« fields »).
Les champs non annotés valent null et sont exclus de la perte et des métriques.

  ../../.venv/bin/python build_dataset.py
"""
import datetime as dt
import hashlib
import io
import json
import random
import re
import sys
from collections import Counter
from pathlib import Path

import pyarrow.parquet as pq
from PIL import Image

HERE = Path(__file__).resolve().parent
RAW = HERE.parent / "raw"
OUT = HERE.parent / "pc" / "data" / "prepared"
sys.path.insert(0, str(HERE.parent / "pc"))
import receipt_metrics as M  # noqa: E402  (to_number partagé)
import synth  # noqa: E402

MAX_SIDE = 1024
ALL_FIELDS = ["merchant", "address", "date", "amount_text", "amount", "currency", "items"]
MONTHS = {m: i + 1 for i, m in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}
SIZES = {  # (entraînement, validation, test) par source
    "cord": None, "sroie": (None, 60, 120), "wildreceipt": (None, 100, 150), "synth": (2400, 120, 250),
}


def resize(image):
    image = image.convert("RGB")
    scale = MAX_SIDE / max(image.size)
    if scale < 1:
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    return image


def year(y):
    y = int(y)
    return y + 2000 if y < 100 else y


def parse_date(text, month_first=None):
    """Date imprimée → AAAA-MM-JJ. None si illisible ou ambiguë (ex. 05/06/18 sans indice du pays)."""
    if not text:
        return None
    t = str(text).strip().lower().replace("'", " ").replace(",", " ")
    try:
        m = re.search(r"(\d{4})[/.\-](\d{1,2})[/.\-](\d{1,2})", t)
        if m:
            return dt.date(int(m[1]), int(m[2]), int(m[3])).isoformat()
        m = re.search(r"(\d{1,2})\s*[\-/ ]?\s*([a-z]{3})[a-z]*\.?\s*[\-/ ]?\s*(\d{2,4})", t)
        if m and m[2] in MONTHS:
            return dt.date(year(m[3]), MONTHS[m[2]], int(m[1])).isoformat()
        m = re.search(r"([a-z]{3})[a-z]*\.?\s*[\-/ ]?\s*(\d{1,2})\s*[\-/ ]\s*(\d{2,4})", t)
        if m and m[1] in MONTHS:
            return dt.date(year(m[3]), MONTHS[m[1]], int(m[2])).isoformat()
        m = re.search(r"(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})", t)
        if m:
            a, b, y = int(m[1]), int(m[2]), year(m[3])
            if a > 12:
                return dt.date(y, b, a).isoformat()
            if b > 12:
                return dt.date(y, a, b).isoformat()
            if month_first is None:
                return None  # ambigu : on n'invente pas
            return dt.date(y, a, b).isoformat() if month_first else dt.date(y, b, a).isoformat()
    except ValueError:
        return None
    return None


def clean(text):
    text = re.sub(r"\s+", " ", str(text or "")).strip(" ,;")
    return text or None


def example(source, image, target, fields, other=None):
    full = {k: target.get(k) for k in ALL_FIELDS}
    for k in ALL_FIELDS:
        if k not in fields:
            full[k] = None
    return {"source": source, "image_obj": image, "target": full, "fields": [k for k in ALL_FIELDS if k in fields],
            "other_amounts": other or {}, "currency": full["currency"] or "?"}


# ------------------------------------------------------------------ CORD (Indonésie, IDR)

def first(v):
    while isinstance(v, list):
        v = v[0] if v else None
    return v


def cord():
    out = {}
    for split in ["train", "validation", "test"]:
        files = sorted((RAW / "cord-v2" / "data").glob(f"{split}-*.parquet"))
        rows = [r for f in files for r in pq.read_table(f).to_pylist()]
        exs = []
        for r in rows:
            gp = json.loads(r["ground_truth"])["gt_parse"]
            total = gp.get("total")
            total = (total[0] if total else {}) if isinstance(total, list) else (total or {})
            raw = first(total.get("total_price"))
            digits = re.sub(r"[^\d]", "", str(raw or ""))
            if not digits:
                continue
            menu = gp.get("menu") or []
            menu = [menu] if isinstance(menu, dict) else menu
            items = []
            for m in menu:
                label, price = first(m.get("nm")), re.sub(r"[^\d]", "", str(first(m.get("price")) or ""))
                if not label or not price:
                    continue
                q = re.search(r"\d+", str(first(m.get("cnt")) or ""))
                items.append({"label": clean(label), "qty": int(q.group()) if q else None, "price": float(price)})
            sub = gp.get("sub_total") or {}
            sub = (sub[0] if sub else {}) if isinstance(sub, list) else sub
            other = {k: float(re.sub(r"[^\d]", "", str(first(v)))) for k, v in {
                "subtotal": sub.get("subtotal_price"), "tax": sub.get("tax_price"), "service": sub.get("service_price"),
                "cash": total.get("cashprice"), "change": total.get("changeprice"), "card": total.get("creditcardprice"),
            }.items() if v and re.sub(r"[^\d]", "", str(first(v)))}
            img = Image.open(io.BytesIO(r["image"]["bytes"]))
            exs.append(example("cord", img, {"amount_text": clean(raw), "amount": float(digits), "currency": "IDR",
                                             "items": items}, ["amount_text", "amount", "currency", "items"], other))
        out[split] = exs
    return out


# ------------------------------------------------------------------ SROIE (Malaisie, MYR)

def sroie():
    out = {}
    for split, file in [("train", "train-00000-of-00001.parquet"), ("test", "test-00000-of-00001.parquet")]:
        exs = []
        for r in pq.read_table(RAW / "sroie" / "data" / file, columns=["image", "entities"]).to_pylist():
            e = r["entities"]
            amount = M.to_number(e.get("total"))
            if amount is None:
                continue
            target = {"merchant": clean(e.get("company")), "address": clean(e.get("address")),
                      "date": parse_date(e.get("date"), month_first=False), "amount_text": clean(e.get("total")),
                      "amount": amount, "currency": "MYR"}
            fields = [k for k in ["merchant", "address", "date"] if target[k]] + ["amount_text", "amount", "currency"]
            exs.append(example("sroie", Image.open(io.BytesIO(r["image"]["bytes"])), target, fields))
        out[split] = exs
    return out


# ------------------------------------------------------------------ WildReceipt (international)

SYMBOLS = {"$": "USD", "£": "GBP", "￡": "GBP", "€": "EUR", "EUR": "EUR", "CHF": "CHF", "RM": "MYR"}


def wildreceipt():
    out = {}
    for split in ["train", "val", "test"]:
        exs = []
        folder = RAW / "wildreceipt" / split
        for line in open(folder / "metadata.jsonl"):
            r = json.loads(line)
            gp = json.loads(r["ground_truth"])["gt_parse"]
            total_raw = first(gp.get("Total_value"))
            amount = M.to_number(total_raw)
            if amount is None:
                continue
            texts = [str(total_raw)] + [str(first(p.get("Prod_price_value")) or "") for p in gp.get("Prod_list") or []]
            currency = next((c for s, c in SYMBOLS.items() for t in texts if s in t), None)
            items = []
            for p in gp.get("Prod_list") or []:
                label, price = clean(first(p.get("Prod_item_value"))), M.to_number(first(p.get("Prod_price_value")))
                if not label or price is None:
                    continue
                q = re.search(r"\d+", str(first(p.get("Prod_quantity_value")) or ""))
                items.append({"label": label, "qty": int(q.group()) if q else None, "price": price})
            target = {"merchant": clean(first(gp.get("Store_name_value"))), "address": clean(first(gp.get("Store_addr_value"))),
                      "date": parse_date(first(gp.get("Date_value")), month_first=True if currency == "USD" else
                                         (False if currency else None)),
                      "amount_text": clean(total_raw), "amount": amount, "currency": currency, "items": items}
            fields = [k for k in ["merchant", "address", "date", "currency"] if target[k]] + ["amount_text", "amount"]
            if gp.get("Prod_list"):
                fields.append("items")
            exs.append(example("wildreceipt", Image.open(folder / r["file_name"]), target, fields))
        out["validation" if split == "val" else split] = exs
    return out


# ------------------------------------------------------------------ Synthétiques (FR, MA, US, UK, CH)

def synthetic():
    out = {}
    for split, (n, seed) in {"train": (SIZES["synth"][0], 1), "validation": (SIZES["synth"][1], 2),
                             "test": (SIZES["synth"][2], 3)}.items():
        rng = random.Random(1000 * seed)
        exs = []
        for _ in range(n):
            img, target, other, _ = synth.make_ticket(rng)
            exs.append(example("synth", img, target, ALL_FIELDS, other))
        out[split] = exs
    return out


def main():
    rng = random.Random(42)
    splits = {"train": [], "validation": [], "test": []}
    print("CORD…", flush=True)
    for k, v in cord().items():
        splits[k] += v
    print("SROIE…", flush=True)
    s = sroie()
    rng.shuffle(s["train"])
    splits["validation"] += s["train"][: SIZES["sroie"][1]]
    splits["train"] += s["train"][SIZES["sroie"][1]:]
    splits["test"] += rng.sample(s["test"], min(SIZES["sroie"][2], len(s["test"])))
    print("WildReceipt…", flush=True)
    w = wildreceipt()
    splits["train"] += w["train"]
    splits["validation"] += rng.sample(w["validation"], min(SIZES["wildreceipt"][1], len(w["validation"])))
    splits["test"] += rng.sample(w["test"], min(SIZES["wildreceipt"][2], len(w["test"])))
    print("Synthétiques…", flush=True)
    for k, v in synthetic().items():
        splits[k] += v

    (OUT / "images").mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    stats = {}
    for split, exs in splits.items():
        rng.shuffle(exs)
        with open(OUT / f"{split}.jsonl", "w", encoding="utf-8") as f:
            for i, ex in enumerate(exs):
                name = f"images/{ex['source']}-{split}-{i:05d}.jpg"
                resize(ex.pop("image_obj")).save(OUT / name, quality=85)
                ex["image"] = name
                line = json.dumps({"image": name, **ex}, ensure_ascii=False)
                digest.update(line.encode())
                f.write(line + "\n")
        stats[split] = {"total": len(exs), "par_source": dict(Counter(e["source"] for e in exs)),
                        "par_devise": dict(Counter(e["currency"] for e in exs)),
                        "avec_decimales": sum(1 for e in exs if e["target"]["amount"] and e["target"]["amount"] % 1),
                        "champs_annotes": dict(Counter(f for e in exs for f in e["fields"]))}
        print(split, json.dumps(stats[split], ensure_ascii=False), flush=True)
    manifest = {"version": 2, "dataset_sha": digest.hexdigest()[:12],
                "sources": {"cord": "naver-clova-ix/cord-v2", "sroie": "jsdnrs/ICDAR2019-SROIE (CC BY 4.0)",
                            "wildreceipt": "podbilabs/wildreceipt-donut", "synth": "générés (build/synth.py)"},
                "fields": ALL_FIELDS, "splits": stats}
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False))
    print("dataset_sha", manifest["dataset_sha"])


if __name__ == "__main__":
    main()
