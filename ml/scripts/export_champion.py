"""Exporte la version « champion » du registre MLflow dans un dossier autonome.

  python scripts/export_champion.py            → <projet>/model/equipay-assistant-v<N>/

Le dossier contient le modèle MLX 4 bits prêt à l'emploi, le prompt système, les scores
et un petit script `ask.py` pour l'interroger, sans MLflow.
"""

import json
import shutil
from pathlib import Path

from common import REGISTERED_MODEL, ROOT, mlflow, setup_mlflow, system_prompt

EXPORT_ROOT = ROOT.parent / "model"

ASK_PY = '''"""Pose une question à l'assistant EquiPay.

  python ask.py "Comment rejoindre une activité ?"
  python ask.py            → mode conversation
Prérequis : Mac Apple Silicon, pip install mlx-lm
"""

import sys
from pathlib import Path

from mlx_lm import generate, load

HERE = Path(__file__).parent
SYSTEM = (HERE / "system_prompt.txt").read_text(encoding="utf-8").strip()
model, tokenizer = load(str(HERE / "mlx_model"))


def ask(question: str) -> str:
    messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": question}]
    prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
    return generate(model, tokenizer, prompt=prompt, max_tokens=160, verbose=False).strip()


if len(sys.argv) > 1:
    print(ask(" ".join(sys.argv[1:])))
else:
    while (q := input("Toi       › ").strip()):
        print("Assistant ›", ask(q), "\\n")
'''


def main() -> None:
    setup_mlflow()
    client = mlflow.MlflowClient()
    v = client.get_model_version_by_alias(REGISTERED_MODEL, "champion")
    run = client.get_run(v.run_id)
    mlx_path = run.data.tags.get("mlx_model_path")
    if not mlx_path:
        raise SystemExit("Ce champion n'a pas de modèle MLX fusionné (version entraînée sur le Mac) : "
                         "export non pris en charge.")

    out = EXPORT_ROOT / f"{REGISTERED_MODEL}-v{v.version}"
    if out.exists():
        raise SystemExit(f"{out} existe déjà")
    print(f"Export de {REGISTERED_MODEL} v{v.version} → {out}")
    shutil.copytree(mlx_path, out / "mlx_model")
    mlflow.artifacts.download_artifacts(run_id=v.run_id, artifact_path="adapter", dst_path=str(out))

    metrics = {k.removeprefix("eval_"): round(val, 4) for k, val in run.data.metrics.items()
               if k.startswith("eval_")}
    params = run.data.params
    (out / "system_prompt.txt").write_text(system_prompt() + "\n", encoding="utf-8")
    (out / "metrics.json").write_text(json.dumps(metrics, indent=2, ensure_ascii=False), encoding="utf-8")
    (out / "ask.py").write_text(ASK_PY, encoding="utf-8")

    pick = lambda k: metrics.get(k, float("nan"))  # noqa: E731
    readme = f"""# Assistant EquiPay — version {v.version} (champion)

Assistant de l'application EquiPay : répond en français aux questions sur l'utilisation de l'app,
redirige vers le support quand il ne sait pas, et refuse poliment les questions hors sujet.

## Fiche du modèle
| | |
|---|---|
| Version du registre MLflow | `{REGISTERED_MODEL}` v{v.version} (alias `@champion`) |
| Run MLflow | `{run.info.run_name}` (`{v.run_id}`) |
| Modèle de base | `{v.tags.get('base_model')}` |
| Entraînement | LoRA rang {params.get('lora_rank')}, alpha {params.get('lora_alpha')}, {params.get('epochs')} epochs, lr {params.get('learning_rate')}, sur {params.get('gpu_name', '?')} |
| Données | jeu `{params.get('dataset_sha')}` — {params.get('dataset_train')} exemples d'entraînement |
| Format | MLX, quantifié 4 bits (Mac Apple Silicon) |

## Scores (237 questions de test jamais vues)
| Métrique | Valeur |
|---|---|
| **Score global** | **{pick('score'):.3f}** |
| Informations clés citées | {pick('keyword_recall'):.1%} |
| Similarité de sens | {pick('semantic_similarity'):.3f} |
| Routage F1 (réponse / support / refus) | {pick('routing_macro_f1'):.3f} |
| Refus du hors sujet | {pick('off_topic_refusal_rate'):.0%} |
| Redirection vers le support | {pick('support_redirect_rate'):.0%} |
| Latence moyenne (Mac M3 Pro) | {pick('latency_s'):.2f} s |

Limite connue : sur une question à propos d'EquiPay dont il ne connaît pas la réponse, il
redirige vers le support environ une fois sur deux ; sinon il peut inventer une réponse.

## Contenu du dossier
- `mlx_model/` : le modèle complet (fusionné), prêt à charger avec `mlx_lm.load`
- `adapter/` : l'adaptateur LoRA d'origine (format PEFT / Hugging Face)
- `system_prompt.txt` : le prompt système utilisé à l'entraînement (à réutiliser tel quel)
- `metrics.json` : toutes les métriques d'évaluation
- `ask.py` : script pour poser des questions

## Utilisation
```bash
pip install mlx-lm
python ask.py "Comment rejoindre une activité ?"
```
"""
    (out / "README.md").write_text(readme, encoding="utf-8")
    size = sum(f.stat().st_size for f in out.rglob("*") if f.is_file()) / 1e9
    print(f"✓ Exporté ({size:.1f} Go) : {out}")


if __name__ == "__main__":
    main()
