"""Assistant EquiPay : modèle « champion » du registre MLflow, exécuté localement avec MLX."""

import logging
import re
import threading
import time

from . import config

log = logging.getLogger("equipay.assistant")


class Assistant:
    def __init__(self) -> None:
        self._model = None
        self._lock = threading.Lock()  # MLX traite une question à la fois
        self.version: str | None = None
        self.error: str | None = None

    @property
    def ready(self) -> bool:
        return self._model is not None

    def load(self) -> None:
        """Charge la version champion. En cas d'échec, l'erreur est gardée et l'API répond 503."""
        import mlflow

        try:
            mlflow.set_tracking_uri(config.MLFLOW_TRACKING_URI)
            client = mlflow.MlflowClient()
            name, alias = config.ASSISTANT_MODEL_URI.removeprefix("models:/").split("@")
            version = client.get_model_version_by_alias(name, alias)

            # Prompt système enregistré avec le modèle, adresse du support remplacée
            flavor = mlflow.models.get_model_info(config.ASSISTANT_MODEL_URI).flavors["python_function"]
            # Clé « config » dans MLflow 3, « model_config » dans les versions plus anciennes
            system = (flavor.get("config") or flavor["model_config"])["system"]
            system = " ".join(system.replace("{support_contact}", config.SUPPORT_CONTACT).split())

            start = time.perf_counter()
            self._model = mlflow.pyfunc.load_model(
                config.ASSISTANT_MODEL_URI, model_config={"system": system}
            )
            self.version = f"{name} v{version.version}"
            self.error = None
            log.info("Assistant prêt : %s (%.1fs)", self.version, time.perf_counter() - start)
        except Exception as e:  # MLflow arrêté, modèle introuvable…
            self.error = f"{type(e).__name__}: {e}"
            log.error("Assistant indisponible : %s", self.error)

    def answer(self, question: str) -> str:
        if not self.ready:
            self.load()
        if not self.ready:
            raise RuntimeError(self.error or "Assistant indisponible")
        with self._lock:
            text = self._model.predict([question])[0]
        return re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
