"""Données du scanner de reçus v2 : prompt, sérialisation de la cible, préparation des lots.

Les champs non annotés dans une source (ex. la date pour CORD) sont écrits « null » dans la réponse,
mais leurs jetons sont EXCLUS de la perte : le modèle n'apprend pas à les laisser vides.
"""
import json
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
DATA = HERE / "data" / "prepared"
FIELDS = ["merchant", "address", "date", "amount_text", "amount", "currency", "items"]

PROMPT = (
    "Tu es le scanner de reçus de l'application EquiPay. Lis ce ticket de caisse et réponds uniquement "
    "avec un JSON de la forme "
    '{"merchant": "<enseigne>", "address": "<adresse>", "date": "<AAAA-MM-JJ>", '
    '"amount_text": "<total exactement comme imprimé>", "amount": <total payé en nombre>, '
    '"currency": "<code ISO 4217>", "items": [{"label": "<article>", "qty": <quantité ou null>, "price": <prix de la ligne>}]}. '
    "Attention aux séparateurs : selon le pays, la virgule ou le point marque les décimales (11,50 € = 11.5) "
    "ou les milliers (75.000 IDR = 75000). Dans « amount » et « price », utilise le point décimal sans séparateur "
    "de milliers. Mets null pour une information absente du ticket."
)

# Prompt de la v1 (pour évaluer l'ancien modèle dans ses conditions d'entraînement)
PROMPT_V1 = (
    "Tu es le scanner de reçus de l'application EquiPay. Lis ce ticket de caisse et réponds "
    "uniquement avec un JSON de la forme "
    '{"amount": <total payé>, "currency": "<code ISO 4217>", '
    '"items": [{"label": "<article>", "qty": <quantité ou null>, "price": <prix de la ligne>}]}. '
    "Les montants sont des nombres, sans séparateur de milliers."
)


def resize(image, max_side):
    image = image.convert("RGB")
    w, h = image.size
    scale = max_side / max(w, h)
    if scale < 1:
        image = image.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
    return image


def read_split(split, limit=None, stratify=False):
    rows = [json.loads(line) for line in open(DATA / f"{split}.jsonl", encoding="utf-8")]
    if limit and stratify:  # même proportion de chaque source
        by = {}
        for r in rows:
            by.setdefault(r["source"], []).append(r)
        picked, i = [], 0
        while len(picked) < min(limit, len(rows)):
            for group in by.values():
                if i < len(group) and len(picked) < limit:
                    picked.append(group[i])
            i += 1
        return picked
    return rows[:limit] if limit else rows


def load_image(row, max_side):
    return resize(Image.open(DATA / row["image"]), max_side)


def user_message(prompt=PROMPT):
    return {"role": "user", "content": [{"type": "image"}, {"type": "text", "text": prompt}]}


def prompt_text(processor, prompt=PROMPT):
    return processor.apply_chat_template([user_message(prompt)], tokenize=False, add_generation_prompt=True)


def serialize(target, fields):
    """Cible → (texte JSON, zones [début, fin) à exclure de la perte = valeurs des champs non annotés)."""
    parts, ignore, pos = ["{"], [], 1
    for i, key in enumerate(FIELDS):
        head = ("" if i == 0 else ", ") + json.dumps(key) + ": "
        value = json.dumps(target.get(key), ensure_ascii=False)
        parts += [head, value]
        pos += len(head)
        if key not in fields:
            ignore.append((pos, pos + len(value)))
        pos += len(value)
    parts.append("}")
    return "".join(parts), ignore


class TrainCollator:
    """Image + prompt + réponse attendue. La perte ne porte que sur les champs annotés de la réponse."""

    def __init__(self, processor, max_side, max_len):
        self.processor, self.max_side, self.max_len = processor, max_side, max_len
        self.prompt = prompt_text(processor)
        self.tokenizer = processor.tokenizer
        self.stats = {"masked_tokens": 0, "answer_tokens": 0, "misaligned": 0}

    def __call__(self, rows):
        texts, images, answers = [], [], []
        for row in rows:
            image = load_image(row, self.max_side)
            answer, ignore = serialize(row["target"], row["fields"])
            texts.append(self.prompt + answer + "<|im_end|>\n")
            images.append([image])
            answers.append((answer, ignore))
        batch = self.processor(text=texts, images=images, return_tensors="pt", padding=True)
        labels = batch["input_ids"].clone()
        labels[batch["attention_mask"] == 0] = -100
        for i, (answer, ignore) in enumerate(answers):
            enc = self.tokenizer(answer + "<|im_end|>\n", add_special_tokens=False, return_offsets_mapping=True)
            ids, offsets = enc["input_ids"], enc["offset_mapping"]
            real = batch["input_ids"][i][batch["attention_mask"][i] == 1]
            start = (batch["attention_mask"][i] == 1).nonzero()[0].item() + len(real) - len(ids)
            if real[len(real) - len(ids):].tolist() != ids:
                # Découpage différent (très rare) : on garde la perte sur toute la réponse
                self.stats["misaligned"] += 1
                labels[i, :start] = -100
                continue
            labels[i, :start] = -100  # prompt et image
            for j, (a, b) in enumerate(offsets):
                if any(a < e and b > s for s, e in ignore):
                    labels[i, start + j] = -100
                    self.stats["masked_tokens"] += 1
            self.stats["answer_tokens"] += len(ids)
        if labels.shape[1] > self.max_len:  # ne tronque jamais l'image : on coupe la fin de la réponse
            for key, value in batch.items():
                if hasattr(value, "shape") and tuple(value.shape[:2]) == tuple(labels.shape):
                    batch[key] = value[:, : self.max_len]
            labels = labels[:, : self.max_len]
        batch["labels"] = labels
        return batch
