"""Construit le jeu de données « Décrire la dépense » dans ml/describe/data/.

  train.jsonl / valid.jsonl / test.jsonl : format chat (system, user, assistant) pour mlx-lm
  test_meta.jsonl / manual_meta.jsonl    : phrase, réponse attendue et contexte (pour l'évaluation)
Le test « manuel » contient 50 phrases écrites à la main, hors des modèles du générateur.
"""
import datetime as dt
import hashlib
import json
from collections import Counter
from pathlib import Path

from generate import Gen
from schema import SYSTEM, dump, empty, user_message

HERE = Path(__file__).resolve().parent
OUT = HERE / "data"
SIZES = {"train": 12000, "valid": 500, "test": 800}

TODAY = dt.date(2026, 10, 11)  # dimanche
G1 = (["Alae", "Sara", "Yassine", "Karim"], "Alae", "MAD")
G2 = (["Alae", "Hugo", "Lea", "Thomas", "Camille"], "Alae", "EUR")
G3 = (["Alae", "Imane", "Omar"], "Alae", "EUR")


def exp(**kw):
    t = empty(True)
    t["items"] = []
    t.update(kw)
    if t["amount"] is None:  # total non dit : somme des articles, sinon 0
        t["amount"] = round(sum(i["price"] for i in t["items"]), 2) if t["items"] else 0
    return t


MANUAL = [
    (G1, "resto hier soir avec Sara et Yassine, 450 dh, j'ai payé", exp(title="Restaurant", amount=450, currency="MAD", date="2026-10-10", paid_by="moi", participants=["moi", "Sara", "Yassine"])),
    (G1, "Taxi de l'aéroport 120dh payé par Karim", exp(title="Taxi", amount=120, currency="MAD", paid_by="Karim")),
    (G1, "courses chez Marjane 836,50 dh pour tout le monde sauf Karim", exp(title="Courses", merchant="Marjane", amount=836.5, currency="MAD", participants=["moi", "Sara", "Yassine"])),
    (G1, "khlest l3cha f Dar Moha 600 dh m3a Sara", exp(title="Restaurant", merchant="Dar Moha", amount=600, currency="MAD", paid_by="moi", participants=["moi", "Sara"])),
    (G1, "essence 300dh vendredi, Yassine a payé, on partage à 4", exp(title="Essence", amount=300, currency="MAD", date="2026-10-09", paid_by="Yassine", participants=["moi", "Sara", "Yassine", "Karim"], split={"type": "equal"})),
    (G1, "riad 2 nuits 1800 dh, 60% pour moi et 40% pour Sara", exp(title="Hébergement", amount=1800, currency="MAD", participants=["moi", "Sara"], split={"type": "percent", "values": {"moi": 60, "Sara": 40}})),
    (G1, "c'est quoi mon solde ?", empty(False)),
    (G1, "quad avec karim et yassine 900dh le 3", exp(title="Sortie", amount=900, currency="MAD", date="2026-10-03", participants=["moi", "Karim", "Yassine"])),
    (G1, "Sara a payé le hammam pour elle et moi, 250 dh", exp(title="Sortie", amount=250, currency="MAD", paid_by="Sara", participants=["Sara", "moi"])),
    (G1, "petit déj au café de France : 2 cafés 30 dh, 2 msemen 20 dh", exp(title="Café", merchant="Café de France", items=[{"label": "Café", "qty": 2, "price": 30}, {"label": "Msemen", "qty": 2, "price": 20}])),
    (G1, "ajoute le péage 45 dh d'avant-hier", exp(title="Parking / péage", amount=45, currency="MAD", date="2026-10-09")),
    (G1, "loc voiture chez Avis 2400 dh, Karim paie 1000, moi 1400", exp(title="Location de voiture", merchant="Avis", amount=2400, currency="MAD", participants=["Karim", "moi"], split={"type": "amounts", "values": {"Karim": 1000, "moi": 1400}})),
    (G1, "billets ONCF pour Casa 3 x 150 dh = 450 dh, j'ai avancé pour Sara et Karim", exp(title="Transport", merchant="ONCF", amount=450, currency="MAD", paid_by="moi", participants=["Sara", "Karim"], items=[{"label": "Billet", "qty": 3, "price": 450}])),
    (G1, "merci pour hier les gars", empty(False)),
    (G1, "pharmacie 85,40 dh", exp(title="Pharmacie", amount=85.4, currency="MAD")),
    (G1, "dîner samedi 1 250,00 dh tout le monde, Yassine a réglé", exp(title="Restaurant", amount=1250, currency="MAD", date="2026-10-10", paid_by="Yassine", participants=["moi", "Sara", "Yassine", "Karim"])),
    (G1, "cinéma avec Sarra 140 dh mercredi", exp(title="Sortie", amount=140, currency="MAD", date="2026-10-07", participants=["moi", "Sara"])),
    (G1, "lwifi dial had chher 349 dh, khlass Karim", exp(title="Factures", amount=349, currency="MAD", paid_by="Karim")),
    (G1, "concert 2 places 700 dh entre moi et Sara 50/50", exp(title="Sortie", amount=700, currency="MAD", participants=["moi", "Sara"], split={"type": "percent", "values": {"moi": 50, "Sara": 50}}, items=[{"label": "Place", "qty": 2, "price": 700}])),
    (G1, "glaces chez Venezia Ice 90 dh pour nous tous", exp(title="Café", merchant="Venezia Ice", amount=90, currency="MAD", participants=["moi", "Sara", "Yassine", "Karim"])),
    (G2, "Dîner chez Big Mama 86,40 € avec Hugo et Léa, j'ai payé", exp(title="Restaurant", merchant="Big Mama", amount=86.4, currency="EUR", paid_by="moi", participants=["moi", "Hugo", "Lea"])),
    (G2, "Thomas a payé l'Airbnb : 540 €, tout le monde", exp(title="Hébergement", merchant="Airbnb", amount=540, currency="EUR", paid_by="Thomas", participants=["moi", "Hugo", "Lea", "Thomas", "Camille"])),
    (G2, "courses Monoprix hier 63,27€ pour moi et Camille", exp(title="Courses", merchant="Monoprix", amount=63.27, currency="EUR", date="2026-10-10", participants=["moi", "Camille"])),
    (G2, "essence 72€ jeudi dernier, réglé par Hugo, sans Léa", exp(title="Essence", amount=72, currency="EUR", date="2026-10-08", paid_by="Hugo", participants=["moi", "Hugo", "Thomas", "Camille"])),
    (G2, "billets de train 4 x 39 € = 156 €", exp(title="Transport", amount=156, currency="EUR", items=[{"label": "Billet", "qty": 4, "price": 156}])),
    (G2, "apéro au Comptoir : 3 bières 18€ et 2 cocktails 22€, Camille a payé", exp(title="Bar", merchant="Le Comptoir", paid_by="Camille", items=[{"label": "Bière", "qty": 3, "price": 18}, {"label": "Cocktail", "qty": 2, "price": 22}])),
    (G2, "musée 2 entrées 30€ le 28 septembre avec Thomas", exp(title="Sortie", amount=30, currency="EUR", date="2026-09-28", participants=["moi", "Thomas"], items=[{"label": "Entrée", "qty": 2, "price": 30}])),
    (G2, "on fait les comptes ce soir ?", empty(False)),
    (G2, "parking 12,50 eur", exp(title="Parking / péage", amount=12.5, currency="EUR")),
    (G2, "resto 120 € : 2 parts pour moi, 1 pour Hugo, 1 pour Léa", exp(title="Restaurant", amount=120, currency="EUR", participants=["moi", "Hugo", "Lea"], split={"type": "shares", "values": {"moi": 2, "Hugo": 1, "Lea": 1}})),
    (G2, "taxi 25$ à New York payé par Léa", exp(title="Taxi", amount=25, currency="USD", paid_by="Lea")),
    (G2, "cadeau pour l'anniv de Camille 80 € entre Hugo, Léa et Thomas", exp(title="Cadeau", amount=80, currency="EUR", participants=["Hugo", "Lea", "Thomas"])),
    (G2, "loyer octobre 1 450 € payé par moi, parts égales", exp(title="Loyer", amount=1450, currency="EUR", paid_by="moi", split={"type": "equal"})),
    (G2, "bowling ce soir 48 €, Thomas 20 €, moi 28 €", exp(title="Sortie", amount=48, currency="EUR", date="2026-10-11", participants=["Thomas", "moi"], split={"type": "amounts", "values": {"Thomas": 20, "moi": 28}})),
    (G2, "facture EDF 94,30€, Hugo a payé, tout le monde sauf Camille et Thomas", exp(title="Factures", merchant="EDF", amount=94.3, currency="EUR", paid_by="Hugo", participants=["moi", "Hugo", "Lea"])),
    (G2, "dinner at Sushi Box 64 euros with hugo, I paid", exp(title="Restaurant", merchant="Sushi Box", amount=64, currency="EUR", paid_by="moi", participants=["moi", "Hugo"])),
    (G2, "groceries yesterday 41.80€ for everyone", exp(title="Courses", amount=41.8, currency="EUR", date="2026-10-10", participants=["moi", "Hugo", "Lea", "Thomas", "Camille"])),
    (G2, "Hugo paid the gas, 55 euros, last Friday", exp(title="Essence", amount=55, currency="EUR", date="2026-10-09", paid_by="Hugo")),
    (G2, "who still owes money?", empty(False)),
    (G2, "train tickets 2 x 45€ between me and Camille, 70/30", exp(title="Transport", amount=90, currency="EUR", participants=["moi", "Camille"], split={"type": "percent", "values": {"moi": 70, "Camille": 30}}, items=[{"label": "Billet", "qty": 2, "price": 90}])),
    (G3, "resto ac imane 52e jai payé", exp(title="Restaurant", amount=52, currency="EUR", paid_by="moi", participants=["moi", "Imane"])),
    (G3, "taxi 18e hier omar a paye", exp(title="Taxi", amount=18, currency="EUR", date="2026-10-10", paid_by="Omar")),
    (G3, "crs carrefour 37,65e pr tt le monde", exp(title="Courses", merchant="Carrefour", amount=37.65, currency="EUR", participants=["moi", "Imane", "Omar"])),
    (G3, "brunch samedi 45 euros", exp(title="Café", amount=45, currency="EUR", date="2026-10-10")),
    (G3, "uber 23,40 € pour Omar et Imane, payé par moi", exp(title="Taxi", merchant="Uber", amount=23.4, currency="EUR", paid_by="moi", participants=["Omar", "Imane"])),
    (G3, "hôtel Ibis 2 nuits 178 € avec Imane, 50% chacun", exp(title="Hébergement", merchant="Ibis", amount=178, currency="EUR", participants=["moi", "Imane"], split={"type": "percent", "values": {"moi": 50, "Imane": 50}})),
    (G3, "salut ça va ?", empty(False)),
    (G3, "souvenirs 300 dh au souk, Omar a payé", exp(title="Cadeau", amount=300, currency="MAD", paid_by="Omar")),
    (G3, "ciné mardi avec omar", exp(title="Sortie", date="2026-10-06", participants=["moi", "Omar"])),
    (G3, "Pizza Hut 31,90€ : 2 pizzas 25,90€, 2 cocas 6€", exp(title="Restaurant", merchant="Pizza Hut", amount=31.9, currency="EUR", items=[{"label": "Pizza", "qty": 2, "price": 25.9}, {"label": "Coca", "qty": 2, "price": 6}])),
]


def to_chat(sentence, target, meta):
    return {"messages": [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": user_message(sentence, meta["members"], meta["me"], dt.date.fromisoformat(meta["today"]) if isinstance(meta["today"], str) else meta["today"], meta["currency"])},
        {"role": "assistant", "content": dump(target)},
    ]}


def main():
    OUT.mkdir(exist_ok=True)
    digest = hashlib.sha256()
    seen = set()
    stats = {}
    for split, seed in [("train", 11), ("valid", 22), ("test", 33)]:
        gen = Gen(seed, split)
        rows = []
        while len(rows) < SIZES[split]:
            ex = gen.make()
            key = ex["sentence"].lower()
            # Aucune phrase de validation ou de test déjà vue à l'entraînement (doublons tolérés dans le train)
            if key in seen and (split != "train" or ex["target"]["is_expense"]):
                continue
            seen.add(key)
            rows.append(ex)
        with open(OUT / f"{split}.jsonl", "w") as f, open(OUT / f"{split}_meta.jsonl", "w") as fm:
            for ex in rows:
                line = json.dumps(to_chat(ex["sentence"], ex["target"], ex["meta"]), ensure_ascii=False)
                digest.update(line.encode())
                f.write(line + "\n")
                fm.write(json.dumps(ex, ensure_ascii=False) + "\n")
        stats[split] = {"total": len(rows), "styles": dict(Counter(r["meta"]["style"] for r in rows)),
                        "participants": dict(Counter(r["meta"]["kind"] for r in rows)),
                        "split_types": dict(Counter((r["target"]["split"] or {}).get("type", "aucune") for r in rows)),
                        "avec_articles": sum(bool(r["target"].get("items")) for r in rows),
                        "non_depenses": sum(not r["target"]["is_expense"] for r in rows)}
        print(split, json.dumps(stats[split], ensure_ascii=False))
    with open(OUT / "manual_meta.jsonl", "w") as fm:
        for (members, me, currency), sentence, target in MANUAL:
            meta = {"style": "manuel", "members": members, "me": me, "today": TODAY.isoformat(), "currency": currency, "kind": "manuel"}
            fm.write(json.dumps({"sentence": sentence, "target": target, "meta": meta}, ensure_ascii=False) + "\n")
            digest.update(sentence.encode())
    manifest = {"dataset_sha": digest.hexdigest()[:12], "sizes": {**SIZES, "manual": len(MANUAL)}, "stats": stats,
                "system_prompt": SYSTEM}
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False))
    print("dataset_sha", manifest["dataset_sha"], "| manuel :", len(MANUAL))


if __name__ == "__main__":
    main()
