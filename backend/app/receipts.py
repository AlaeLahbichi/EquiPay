"""Scanner de reçus EquiPay : photo d'un ticket → champs de la dépense (modèle equipay-receipt v2).

Le modèle (Qwen3-VL-4B affiné, fusionné) tourne sur le GPU du Mac (Metal), au choix (RECEIPT_ENGINE) :
  - « mlx » : version quantifiée de model/equipay-receipt-scanner/mlx_model_*bit (moins de mémoire) ;
  - « torch » : version bf16 de model/equipay-receipt-scanner/model, gardée en référence et en secours. Il ne crée jamais la dépense : l'app pré-remplit le formulaire
et l'utilisateur valide.
"""

import datetime as dt
import io
import json
import logging
import re
import threading
import time
from pathlib import Path

from . import config

log = logging.getLogger("equipay.receipts")

MAX_SIDE = 1024  # même taille d'image qu'à l'entraînement


def parse_json(text: str) -> dict | None:
    match = re.search(r"\{.*\}", text or "", re.S)
    if not match:
        return None
    try:
        value = json.loads(match.group())
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def to_number(value) -> float | None:
    """Montant → nombre : 75000, « 75,000 », « 11,50 », « 1.250,50 », « $1,234.56 » (règles de l'évaluation)."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = re.sub(r"[^\d,.\-']", "", str(value)).replace("'", "")
    text = text.strip(".,-") if not re.match(r"^-\d", text) else text.rstrip(".,")
    if not re.search(r"\d", text):
        return None
    if re.fullmatch(r"-?\d{1,3}([.,]\d{3})+", text) and len(set(re.findall(r"[.,]", text))) == 1:
        text = re.sub(r"[.,]", "", text)
    else:
        last = max(text.rfind(","), text.rfind("."))
        if last >= 0:
            text = re.sub(r"[.,]", "", text[:last]) + "." + text[last + 1:]
    try:
        return float(text)
    except ValueError:
        return None


def _text(value, limit=200) -> str | None:
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] or None


def normalize(data: dict | None, today: dt.date | None = None) -> dict:
    """Réponse brute du modèle → champs propres + vérifications pour l'app."""
    data = data or {}
    today = today or dt.date.today()
    amount = to_number(data.get("amount"))
    if amount is not None and not (0 < amount < 1e10):
        amount = None
    currency = data.get("currency")
    currency = currency.strip().upper() if isinstance(currency, str) and re.fullmatch(r"\s*[A-Za-z]{3}\s*", currency) else None
    date = None
    if isinstance(data.get("date"), str):
        try:
            d = dt.date.fromisoformat(data["date"][:10])
            if dt.date(2000, 1, 1) <= d <= today + dt.timedelta(days=1):
                date = d.isoformat()
        except ValueError:
            pass
    items = []
    for it in data.get("items") or []:
        if isinstance(it, dict) and _text(it.get("label")) and to_number(it.get("price")) is not None:
            qty = it.get("qty")
            items.append({"label": _text(it.get("label"), 80), "qty": qty if isinstance(qty, (int, float)) and qty > 0 else None,
                          "price": round(to_number(it.get("price")), 2)})
    amount_text = _text(data.get("amount_text"), 40)
    items_sum = round(sum(i["price"] for i in items), 2) if items else None
    printed = to_number(amount_text)
    return {
        "merchant": _text(data.get("merchant"), 100),
        "address": _text(data.get("address"), 200),
        "date": date,
        "amount": round(amount, 2) if amount is not None else None,
        "amount_text": amount_text,
        "currency": currency,
        "items": items,
        "checks": {
            # Le montant converti correspond-il au texte imprimé ? (sinon : à vérifier)
            "amount_matches_text": printed is not None and amount is not None and abs(printed - amount) < 0.01,
            "items_sum": items_sum,
            "items_match_total": items_sum is not None and amount is not None and abs(items_sum - amount) < 0.01,
        },
    }


class ReceiptScanner:
    def __init__(self) -> None:
        self._model = None
        self._processor = None
        self._prompt: str | None = None
        self._lock = threading.Lock()  # une lecture à la fois sur le GPU
        self._loading = threading.Lock()
        self._generate = None
        self.version: str | None = None
        self.error: str | None = None
        self.device: str | None = None
        self.engine: str | None = None

    @property
    def ready(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        """Charge le modèle. En cas d'échec, l'erreur est gardée et l'API répond 503."""
        with self._loading:
            if self.ready:
                return
            engines = ["mlx", "torch"] if config.RECEIPT_ENGINE == "mlx" else ["torch"]
            for engine in engines:
                try:
                    start = time.perf_counter()
                    (self._load_mlx if engine == "mlx" else self._load_torch)()
                    self.engine = engine
                    self.version = config.RECEIPT_MODEL_VERSION + (" (MLX)" if engine == "mlx" else "")
                    self.error = None
                    log.info("Scanner de reçus prêt : %s sur %s (%.1fs)", self.version, self.device, time.perf_counter() - start)
                    return
                except Exception as e:
                    self.error = f"{type(e).__name__}: {e}"
                    log.error("Scanner de reçus (%s) indisponible : %s", engine, self.error)

    @staticmethod
    def _prompt_for(processor, path: Path) -> str:
        prompt = (path / "equipay_prompt.txt").read_text(encoding="utf-8").strip()
        messages = [{"role": "user", "content": [{"type": "image"}, {"type": "text", "text": prompt}]}]
        return processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)

    def _load_mlx(self) -> None:
        from mlx_vlm import generate, load

        path = Path(config.RECEIPT_MLX_MODEL_DIR)
        if not (path / "config.json").exists():
            raise FileNotFoundError(f"modèle MLX introuvable dans {path}")
        model, processor = load(str(path))
        self._prompt = self._prompt_for(processor, path)
        self.device = "mlx"
        self._generate = generate
        self._model, self._processor = model, processor

    def _load_torch(self) -> None:
        import torch
        from transformers import AutoModelForImageTextToText, AutoProcessor

        path = Path(config.RECEIPT_MODEL_DIR)
        if not (path / "config.json").exists():
            raise FileNotFoundError(f"modèle introuvable dans {path}")
        self.device = "mps" if torch.backends.mps.is_available() else ("cuda" if torch.cuda.is_available() else "cpu")
        processor = AutoProcessor.from_pretrained(path)
        model = AutoModelForImageTextToText.from_pretrained(path, dtype=torch.bfloat16, attn_implementation="sdpa")
        model.to(self.device).eval()
        self._prompt = self._prompt_for(processor, path)
        self._model, self._processor = model, processor

    def load_in_background(self) -> None:
        threading.Thread(target=self.load, name="receipt-model", daemon=True).start()

    def _read(self, image) -> str:
        if self.engine == "mlx":
            out = self._generate(self._model, self._processor, self._prompt, image=[image], max_tokens=1024,
                                 temperature=0.0, verbose=False)
            return out.text
        import torch

        with torch.no_grad():
            inputs = self._processor(text=[self._prompt], images=[[image]], return_tensors="pt").to(self._model.device)
            out = self._model.generate(**inputs, max_new_tokens=1024, do_sample=False, use_cache=True)
            return self._processor.batch_decode(out[:, inputs["input_ids"].shape[1]:], skip_special_tokens=True)[0]

    def scan(self, image_bytes: bytes) -> dict:
        from PIL import Image, ImageOps

        if not self.ready:
            self.load()
        if not self.ready:
            raise RuntimeError(self.error or "Scanner indisponible")
        image = ImageOps.exif_transpose(Image.open(io.BytesIO(image_bytes))).convert("RGB")
        scale = MAX_SIDE / max(image.size)
        if scale < 1:
            image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
        with self._lock:
            text = self._read(image)
        data = parse_json(text)
        if data is None:
            log.warning("Réponse illisible du scanner : %s", text[:300])
        return {"ok": data is not None, **normalize(data)}
