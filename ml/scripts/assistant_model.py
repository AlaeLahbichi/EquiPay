"""Modèle MLflow (pyfunc) de l'assistant EquiPay : modèle de base + adaptateur LoRA optionnel.

Enregistré dans le registre MLflow, il se charge ensuite avec :
    mlflow.pyfunc.load_model("models:/equipay-assistant@champion")
et répond à une liste de questions.
"""

import mlflow
from mlflow.models import set_model
from mlflow.pyfunc import PythonModel


class EquipayAssistant(PythonModel):
    def load_context(self, context):
        from mlx_lm import load

        config = context.model_config
        adapter = context.artifacts.get("adapter") if context.artifacts else None
        self.system = config["system"]
        self.max_tokens = int(config.get("max_tokens", 160))
        # Modèle importé du PC : dossier MLX local ; sinon identifiant Hugging Face
        path = config.get("mlx_model_path") or config["base_model"]
        self.model, self.tokenizer = load(path, adapter_path=adapter)

    def _prompt(self, question: str) -> str:
        messages = [{"role": "system", "content": self.system}, {"role": "user", "content": question}]
        try:
            return self.tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
        except Exception:
            merged = [{"role": "user", "content": f"{self.system}\n\n{question}"}]
            return self.tokenizer.apply_chat_template(merged, add_generation_prompt=True, tokenize=False)

    def predict(self, context, model_input, params=None):
        from mlx_lm import generate

        questions = (
            model_input["question"].tolist() if hasattr(model_input, "columns") else list(model_input)
        )
        return [
            generate(self.model, self.tokenizer, prompt=self._prompt(q),
                     max_tokens=self.max_tokens, verbose=False).strip()
            for q in questions
        ]


set_model(EquipayAssistant())
