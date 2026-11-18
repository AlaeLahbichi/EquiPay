"""Importe les entraînements faits sur le PC (CUDA) et les évalue sur le Mac.

Pour chaque run du PC (tag status=awaiting_mac_eval) :
  1. télécharge l'adaptateur LoRA depuis MLflow
  2. le fusionne avec le modèle de base Hugging Face (bf16, sur le CPU)
  3. convertit le modèle fusionné en MLX 4 bits (même format que les modèles mlx-community)
  4. l'évalue sur les 237 questions de test (mêmes métriques que v1 à v7)
  5. enregistre les résultats dans le MÊME run et inscrit une nouvelle version du registre

  python scripts/import_from_pc.py               → tous les runs en attente
  python scripts/import_from_pc.py --run-id ID   → un run précis
"""

import argparse
import gc
import tempfile
from pathlib import Path

from common import MODELS, mlflow, setup_mlflow
from run import evaluate_and_register, short_name


def pending_runs(run_ids: list[str] | None):
    if run_ids:
        return [mlflow.get_run(r) for r in run_ids]
    return mlflow.search_runs(
        experiment_names=["Equipay"],
        filter_string="tags.stage = 'fine-tuned-cuda' and tags.status = 'awaiting_mac_eval'",
        order_by=["start_time ASC"],
        output_format="list",
    )


def merge_and_convert(run_id: str, base_model: str, out: Path) -> None:
    """Adaptateur PEFT + modèle de base → modèle fusionné → MLX 4 bits dans `out`."""
    import torch
    from mlx_lm import convert
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer

    with tempfile.TemporaryDirectory(dir=MODELS) as tmp:
        adapter = mlflow.artifacts.download_artifacts(run_id=run_id, artifact_path="adapter", dst_path=tmp)
        print(f"  fusion de l'adaptateur avec {base_model}…", flush=True)
        model = AutoModelForCausalLM.from_pretrained(base_model, dtype=torch.bfloat16, low_cpu_mem_usage=True)
        merged = PeftModel.from_pretrained(model, adapter).merge_and_unload()
        merged_dir = Path(tmp) / "merged"
        merged.save_pretrained(merged_dir, safe_serialization=True)
        AutoTokenizer.from_pretrained(base_model).save_pretrained(merged_dir)
        del model, merged
        gc.collect()

        print("  conversion en MLX 4 bits…", flush=True)
        convert(hf_path=str(merged_dir), mlx_path=str(out), quantize=True, q_bits=4, q_group_size=64)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run-id", action="append", help="run à importer (répétable)")
    parser.add_argument("--limit", type=int, help="nombre de questions de test (debug)")
    args = parser.parse_args()

    setup_mlflow()
    runs = pending_runs(args.run_id)
    print(f"{len(runs)} run(s) à importer")
    for i, run in enumerate(runs, 1):
        run_id, name = run.info.run_id, run.info.run_name
        base_model = run.data.tags["base_model"]
        out = MODELS / f"{name}-{run_id[:8]}"
        print(f"\n=== [{i}/{len(runs)}] {name} ({run_id})", flush=True)

        if not (out / "config.json").exists():
            merge_and_convert(run_id, base_model, out)
        else:
            print("  modèle MLX déjà converti, réutilisé")

        with mlflow.start_run(run_id=run_id):
            mlflow.set_tags({"status": "evaluating", "mlx_model_path": str(out)})
            evaluate_and_register(str(out), None, "fine-tuned-cuda", args.limit, label=base_model)
            mlflow.set_tag("status", "evaluated")
        print(f"  ✓ {short_name(base_model)} importé", flush=True)


if __name__ == "__main__":
    main()
