"""Importe le modèle « Décrire la dépense » entraîné sur le PC (CUDA) et le prépare pour le Mac.

  1. télécharge l'adaptateur LoRA du run MLflow (tag status=awaiting_mac_import)
  2. le fusionne avec Qwen3-4B-Instruct-2507 (bf16, sur le CPU)
  3. convertit le modèle fusionné en MLX 4 bits → model/equipay-describe/mlx_model
  4. le réévalue sur le Mac (MLX 4 bits) : phrases manuelles + test, métriques préfixées « mac_ »
  5. inscrit la version dans le registre « equipay-describe » (alias champion si meilleure)

  python import_pc.py                → dernier run en attente
  python import_pc.py --run-id ID    → un run précis
  python import_pc.py --limit 20     → réévaluation rapide (debug)
"""
import argparse
import gc
import json
import shutil
import tempfile
from pathlib import Path

import mlflow

import run as R
from schema import SYSTEM

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "model" / "equipay-describe"
BASE_HF = "Qwen/Qwen3-4B-Instruct-2507"


def pending_run(run_id: str | None):
    if run_id:
        return mlflow.get_run(run_id)
    runs = mlflow.search_runs(
        experiment_names=[R.EXPERIMENT],
        filter_string="tags.stage = 'fine-tuned-cuda' and tags.status = 'awaiting_mac_import'",
        order_by=["start_time DESC"],
        max_results=1,
        output_format="list",
    )
    if not runs:
        raise SystemExit("Aucun run en attente d'import (tag status=awaiting_mac_import)")
    return runs[0]


def merge_and_convert(run_id: str, base_model: str, out: Path) -> None:
    import torch
    from mlx_lm import convert
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer

    with tempfile.TemporaryDirectory(dir=R.MODELS) as tmp:
        adapter = mlflow.artifacts.download_artifacts(run_id=run_id, artifact_path="adapter", dst_path=tmp)
        shutil.copytree(adapter, OUT / "adapter", dirs_exist_ok=True)
        print(f"Fusion de l'adaptateur avec {base_model}…", flush=True)
        model = AutoModelForCausalLM.from_pretrained(base_model, dtype=torch.bfloat16, low_cpu_mem_usage=True)
        merged = PeftModel.from_pretrained(model, adapter).merge_and_unload()
        merged_dir = Path(tmp) / "merged"
        merged.save_pretrained(merged_dir, safe_serialization=True)
        AutoTokenizer.from_pretrained(base_model).save_pretrained(merged_dir)
        del model, merged
        gc.collect()
        print("Conversion en MLX 4 bits…", flush=True)
        convert(hf_path=str(merged_dir), mlx_path=str(out), quantize=True, q_bits=4, q_group_size=64)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run-id")
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()

    R.setup()
    run = pending_run(args.run_id)
    run_id = run.info.run_id
    base_model = run.data.tags.get("base_model", BASE_HF)
    mlx_dir = OUT / "mlx_model"
    print(f"Run {run.info.run_name} ({run_id})", flush=True)
    OUT.mkdir(parents=True, exist_ok=True)

    if not (mlx_dir / "config.json").exists():
        merge_and_convert(run_id, base_model, mlx_dir)
    else:
        print("Modèle MLX déjà converti, réutilisé", flush=True)

    results = {}
    with mlflow.start_run(run_id=run_id):
        mlflow.set_tags({"status": "importing", "mlx_model_path": str(mlx_dir)})
        for split, prefix in [("manual", "mac_manual_eval_"), ("test", "mac_eval_")]:
            rows = R.load_rows(split, args.limit)
            print(f"Réévaluation MLX 4 bits — {split} ({len(rows)} phrases)…", flush=True)
            m, scores, preds = R.evaluate(str(mlx_dir), None, rows)
            R.log_eval(prefix, prefix.rstrip("_"), m, scores, preds, f"MLX 4 bits ({split})")
            results[split] = m
            print(f"  {split}: score {m['score']:.3f} | exact {m['exact_match']:.1%} | montant {m['amount_accuracy']:.1%} "
                  f"| participants {m['participants_accuracy']:.1%} | latence {m.get('latency_mean_s', 0):.2f}s", flush=True)
        if args.limit:
            print("Mode --limit : pas d'inscription au registre")
            return
        client = mlflow.MlflowClient()
        try:
            client.create_registered_model(R.REGISTRY, description="Décrire la dépense : phrase → dépense (LoRA Qwen3-4B)")
        except Exception:
            pass
        v = client.create_model_version(R.REGISTRY, source=f"{run.info.artifact_uri}/adapter", run_id=run_id)
        pc = run.data.metrics
        tags = {
            "dataset_sha": run.data.tags.get("dataset_sha", ""),
            "base_model": base_model,
            "format": "peft-lora (+ MLX 4 bits sur le Mac)",
            "eval_score": f"{pc.get('eval_score', 0):.4f}",
            "manual_eval_score": f"{pc.get('manual_eval_score', 0):.4f}",
            "mac_eval_score": f"{results['test']['score']:.4f}",
            "mac_manual_eval_score": f"{results['manual']['score']:.4f}",
            "mlx_model_path": str(mlx_dir),
        }
        for k, val in tags.items():
            client.set_model_version_tag(R.REGISTRY, v.version, k, val)
        try:
            champ = client.get_model_version_by_alias(R.REGISTRY, "champion")
            better = results["test"]["score"] > float(champ.tags.get("mac_eval_score", 0))
        except Exception:
            better = True
        if better:
            client.set_registered_model_alias(R.REGISTRY, "champion", v.version)
        mlflow.set_tag("status", "imported")
        print(f"Registre : {R.REGISTRY} v{v.version}" + (" (champion)" if better else ""), flush=True)

    (OUT / "system_prompt.txt").write_text(SYSTEM + "\n")
    summary = {
        "registry": f"{R.REGISTRY} v{v.version}",
        "run_id": run_id,
        "run_name": run.info.run_name,
        "base_model": base_model,
        "pc_metrics": {k: pc[k] for k in sorted(pc) if k.split("_eval_")[0] in ("eval", "manual", "base", "base_manual")
                       and "_style_" not in k and "_participants_" not in k and "_repartition_" not in k},
        "mac_mlx_4bit": results,
    }
    (OUT / "metrics.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"✓ Modèle prêt : {mlx_dir}")


if __name__ == "__main__":
    main()
