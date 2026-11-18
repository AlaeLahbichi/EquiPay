"""Configuration lue depuis backend/.env."""

import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env")

SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_PUBLISHABLE_KEY = os.environ["SUPABASE_PUBLISHABLE_KEY"]
SUPABASE_JWKS_URL = os.environ["SUPABASE_JWKS_URL"]

# Modèle de l'assistant : la version « champion » du registre MLflow
MLFLOW_TRACKING_URI = os.environ.get("MLFLOW_TRACKING_URI", "http://127.0.0.1:5000")
ASSISTANT_MODEL_URI = os.environ.get("ASSISTANT_MODEL_URI", "models:/equipay-assistant@champion")
SUPPORT_CONTACT = os.environ.get("SUPPORT_CONTACT", "support@equipay.app")

# Scanner de reçus : modèle v2 fusionné, enregistré dans model/equipay-receipt-scanner/model
RECEIPT_MODEL_DIR = os.environ.get(
    "RECEIPT_MODEL_DIR", str(Path(__file__).resolve().parents[2] / "model" / "equipay-receipt-scanner" / "model")
)
RECEIPT_MODEL_VERSION = os.environ.get("RECEIPT_MODEL_VERSION", "equipay-receipt v2")
# Moteur du scanner : « mlx » (modèle quantifié, moins de mémoire) ou « torch » (bf16, la référence gardée en stock).
# Si le modèle MLX ne se charge pas, le scanner revient sur PyTorch.
RECEIPT_ENGINE = os.environ.get("RECEIPT_ENGINE", "mlx")
RECEIPT_MLX_MODEL_DIR = os.environ.get(
    "RECEIPT_MLX_MODEL_DIR",
    str(Path(__file__).resolve().parents[2] / "model" / "equipay-receipt-scanner" / "mlx_model_4bit"),
)

# Décrire la dépense : modèle equipay-describe converti en MLX 4 bits, dans model/equipay-describe/mlx_model
DESCRIBE_MODEL_DIR = os.environ.get(
    "DESCRIBE_MODEL_DIR", str(Path(__file__).resolve().parents[2] / "model" / "equipay-describe" / "mlx_model")
)
DESCRIBE_MODEL_VERSION = os.environ.get("DESCRIBE_MODEL_VERSION", "equipay-describe v1")

# Organisation du trajet : temps de trajet OSRM (gratuit) et texte par Qwen3-4B (MLX 4 bits, cache Hugging Face)
OSRM_URL = os.environ.get("OSRM_URL", "https://routing.openstreetmap.de")
TRIP_MODEL = os.environ.get("TRIP_MODEL", "mlx-community/Qwen3-4B-Instruct-2507-4bit")
TRIP_EXPERIMENT = os.environ.get("TRIP_EXPERIMENT", "Equipay-trips")
