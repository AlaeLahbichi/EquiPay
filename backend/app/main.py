import datetime as dt
import logging
import threading
import time
from contextlib import asynccontextmanager
from typing import Literal
from uuid import UUID

from fastapi import Depends, FastAPI, File, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import chat_store, config, quota
from .assistant import Assistant
from .auth import User, current_user, optional_user
from .describe import ExpenseDescriber
from .receipts import ReceiptScanner
from .trips import Stop, TripWriter, optimize

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Le modèle est chargé une fois, au démarrage du serveur
    app.state.assistant.load()
    # Le scanner de reçus (≈ 9 Go) se charge en arrière-plan : l'assistant répond déjà pendant ce temps
    app.state.receipts.load_in_background()
    # Décrire la dépense (≈ 2,3 Go) : chargé à la première phrase
    yield


app = FastAPI(title="EquiPay API", lifespan=lifespan)
app.state.assistant = Assistant()
app.state.receipts = ReceiptScanner()
app.state.describer = ExpenseDescriber()
app.state.trip_writer = TripWriter()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_assistant(request: Request) -> Assistant:
    return request.app.state.assistant


def get_receipts(request: Request) -> ReceiptScanner:
    return request.app.state.receipts


def get_describer(request: Request) -> ExpenseDescriber:
    return request.app.state.describer


def get_trip_writer(request: Request) -> TripWriter:
    return request.app.state.trip_writer


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=1000)
    activity_id: UUID | None = None


class ChatResponse(BaseModel):
    answer: str
    model_version: str | None
    latency_ms: int


@app.get("/")
def hello():
    return {"message": "Hello World"}


@app.get("/health")
def health(
    assistant: Assistant = Depends(get_assistant),
    receipts: ReceiptScanner = Depends(get_receipts),
    describer: ExpenseDescriber = Depends(get_describer),
):
    return {
        "status": "ok",
        "assistant": {"ready": assistant.ready, "version": assistant.version, "error": assistant.error},
        "receipts": {"ready": receipts.ready, "version": receipts.version, "error": receipts.error},
        "describe": {"ready": describer.ready, "version": describer.version, "error": describer.error},
    }


# Fonctions « def » (et non async) : FastAPI les exécute dans un thread,
# le calcul du modèle ne bloque donc pas le serveur.
# Connexion facultative : l'historique n'est enregistré que pour un utilisateur connecté.
@app.post("/chat", response_model=ChatResponse)
def chat(
    body: ChatRequest,
    user: User | None = Depends(optional_user),
    assistant: Assistant = Depends(get_assistant),
):
    question = body.message.strip()
    start = time.perf_counter()
    try:
        answer = assistant.answer(question)
    except RuntimeError as e:
        raise HTTPException(503, "L'assistant est momentanément indisponible. Réessaie plus tard.") from e
    latency_ms = int((time.perf_counter() - start) * 1000)
    if user:
        chat_store.save_exchange(user, question, answer, str(body.activity_id) if body.activity_id else None)
    return ChatResponse(answer=answer, model_version=assistant.version, latency_ms=latency_ms)


@app.get("/chat/history")
def chat_history(user: User = Depends(current_user)):
    return chat_store.history(user)


MAX_RECEIPT_BYTES = 12 * 1024 * 1024


@app.post("/receipts/scan")
def scan_receipt(
    file: UploadFile = File(...),
    user: User = Depends(current_user),
    receipts: ReceiptScanner = Depends(get_receipts),
):
    """Lit la photo d'un ticket et renvoie les champs détectés. Ne crée rien : l'app pré-remplit le formulaire."""
    data = file.file.read(MAX_RECEIPT_BYTES + 1)
    if len(data) > MAX_RECEIPT_BYTES:
        raise HTTPException(413, "Photo trop lourde (12 Mo maximum).")
    quota.check(user, "scan")
    start = time.perf_counter()
    try:
        result = receipts.scan(data)
    except RuntimeError as e:
        raise HTTPException(503, "Le scanner de reçus est momentanément indisponible. Réessaie plus tard.") from e
    except OSError as e:  # PIL : fichier qui n'est pas une image
        raise HTTPException(400, "Ce fichier n'est pas une image lisible.") from e
    quota.record(user, "scan")
    result["model_version"] = receipts.version
    result["latency_ms"] = int((time.perf_counter() - start) * 1000)
    logging.getLogger("equipay.receipts").info(
        "Ticket lu pour %s en %d ms (total=%s %s)", user.id, result["latency_ms"], result["amount"], result["currency"]
    )
    return result


class Member(BaseModel):
    id: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=80)


class DescribeRequest(BaseModel):
    sentence: str = Field(min_length=1, max_length=500)
    members: list[Member] = Field(min_length=1, max_length=50)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    # Date du téléphone (fuseau de l'utilisateur), pour « hier », « samedi dernier »…
    today: dt.date | None = None


@app.post("/expenses/describe")
def describe_expense(
    body: DescribeRequest,
    user: User = Depends(current_user),
    describer: ExpenseDescriber = Depends(get_describer),
):
    """Phrase libre → champs de la dépense (membres par identifiant, répartition en %). Ne crée rien."""
    members = [m.model_dump() for m in body.members]
    if user.id not in {m["id"] for m in members}:
        raise HTTPException(403, "Tu ne fais pas partie de cette activité.")
    quota.check(user, "describe")
    start = time.perf_counter()
    try:
        result = describer.describe(
            body.sentence.strip(), members, user.id, body.today or dt.date.today(), body.currency
        )
    except RuntimeError as e:
        raise HTTPException(503, "La saisie par phrase est momentanément indisponible. Réessaie plus tard.") from e
    quota.record(user, "describe")
    result["model_version"] = describer.version
    result["latency_ms"] = int((time.perf_counter() - start) * 1000)
    logging.getLogger("equipay.describe").info(
        "Phrase décrite pour %s en %d ms (montant=%s)", user.id, result["latency_ms"], result.get("amount")
    )
    return result


class TripStop(BaseModel):
    id: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=120)
    place: str | None = Field(default=None, max_length=120)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    date: dt.date | None = None
    time: dt.time | None = None
    up: int = Field(default=0, ge=0)
    down: int = Field(default=0, ge=0)


class TripRequest(BaseModel):
    mode: Literal["walking", "cycling", "driving"] = "walking"
    max_per_day: int | None = Field(default=None, ge=1, le=12)
    notes: str | None = Field(default=None, max_length=300)
    stops: list[TripStop] = Field(min_length=1, max_length=40)


def _log_trip_run(body: TripRequest, result: dict, latency_ms: int) -> None:
    """Essai enregistré dans MLflow (expérience « Equipay-trips »), en arrière-plan : comparer les modèles plus tard."""
    try:
        import mlflow

        mlflow.set_tracking_uri(config.MLFLOW_TRACKING_URI)
        mlflow.set_experiment(config.TRIP_EXPERIMENT)
        with mlflow.start_run(run_name=f"trajet-{body.mode}-{len(body.stops)}lieux"):
            mlflow.log_params({"model": result.get("model_version") or config.TRIP_MODEL, "mode": body.mode,
                               "stops": len(body.stops), "days": len(result["days"]),
                               "max_per_day": body.max_per_day, "has_notes": bool(body.notes)})
            mlflow.log_metrics({"latency_ms": latency_ms, "saved_seconds": result["saved_seconds"],
                                "total_seconds": result["total_seconds"], "estimated": int(result["estimated"]),
                                "summary_chars": len(result["summary"] or "")})
            if result["summary"]:
                mlflow.log_text(result["summary"], "programme.txt")
    except Exception as e:  # MLflow arrêté : l'organisation du trajet marche quand même
        logging.getLogger("equipay.trips").warning("Essai non enregistré dans MLflow : %s", e)


@app.post("/trips/optimize")
def optimize_trip(
    body: TripRequest,
    user: User = Depends(current_user),
    writer: TripWriter = Depends(get_trip_writer),
):
    """Lieux du programme → meilleur ordre jour par jour, temps de trajet et texte de l'IA. Ne modifie rien."""
    quota.check(user, "trip")
    start = time.perf_counter()
    stops = [Stop(**s.model_dump()) for s in body.stops]
    try:
        result = optimize(stops, body.mode, body.max_per_day, (body.notes or "").strip() or None, writer)
    except ValueError as e:
        raise HTTPException(422, str(e)) from e
    quota.record(user, "trip")
    latency_ms = int((time.perf_counter() - start) * 1000)
    result["latency_ms"] = latency_ms
    logging.getLogger("equipay.trips").info(
        "Trajet organisé pour %s : %d lieux, %d s gagnées, %d ms", user.id, len(stops), result["saved_seconds"], latency_ms
    )
    threading.Thread(target=_log_trip_run, args=(body, result, latency_ms), daemon=True).start()
    return result
