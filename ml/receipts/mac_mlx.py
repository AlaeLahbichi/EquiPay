"""Scanner de reçus sur le Mac : conversion MLX 4 bits et comparaison avec la version PyTorch (bf16).

  python mac_mlx.py convert --bits 4        → model/equipay-receipt-scanner/mlx_model_4bit
  python mac_mlx.py eval --bits 4           → réévalue ce modèle MLX sur le jeu de test (615 tickets)
  python mac_mlx.py eval --backend torch --limit 40   → mesure de référence PyTorch/MPS (vitesse, mémoire)

Les métriques sont celles de l'entraînement (receipt_metrics.py) et sont ajoutées au run MLflow de la v2,
préfixées « mac_mlx<bits>_eval_ » ou « mac_torch_eval_ ». Une copie locale est rangée dans evaluation/.
"""
import argparse
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")

ROOT = Path(__file__).resolve().parents[2]
SCANNER = ROOT / "model" / "equipay-receipt-scanner"
HF_MODEL = SCANNER / "model"


def mlx_dir(bits: int) -> Path:
    return SCANNER / f"mlx_model_{bits}bit"
sys.path.insert(0, str(Path(__file__).resolve().parent / "pc"))  # prompt, données de test et métriques

import receipt_data as D  # noqa: E402
import receipt_metrics as M  # noqa: E402

V2_RUN_ID = "265578dc18644ec78ccea1bc6e3360aa"
MAX_SIDE = 1024


def convert(bits: int) -> None:
    """mlx-vlm lit encore l'ancien format de config (transformers 4) : on lui donne une copie adaptée,
    les poids sont simplement liés, le modèle PyTorch n'est pas modifié."""
    from mlx_vlm import convert as mlx_convert

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for f in HF_MODEL.iterdir():
            if f.name != "config.json":
                (tmp / f.name).symlink_to(f)
        config = json.loads((HF_MODEL / "config.json").read_text())
        text = config["text_config"]
        rope = text.get("rope_parameters", {})
        text.setdefault("rope_theta", rope.get("rope_theta"))
        text.setdefault("rope_scaling", {"rope_type": rope.get("rope_type", "default"),
                                         "mrope_section": rope.get("mrope_section"),
                                         "mrope_interleaved": rope.get("mrope_interleaved", True)})
        text["model_type"] = config["vision_config"]["model_type"] = config["model_type"]
        (tmp / "config.json").write_text(json.dumps(config, indent=2))
        out = mlx_dir(bits)
        if out.exists():
            shutil.rmtree(out)
        mlx_convert(hf_path=str(tmp), mlx_path=str(out), quantize=True, q_bits=bits, q_group_size=64)
    shutil.copy(HF_MODEL / "equipay_prompt.txt", out / "equipay_prompt.txt")
    print(f"Modèle MLX {bits} bits : {out}")


class MlxRunner:
    def __init__(self, path: Path):
        import mlx.core as mx
        from mlx_vlm import generate, load

        self.mx, self._generate = mx, generate
        self.model, self.processor = load(str(path))
        self.prompt = D.prompt_text(self.processor, (path / "equipay_prompt.txt").read_text().strip())

    def __call__(self, image):
        out = self._generate(self.model, self.processor, self.prompt, image=[image], max_tokens=1024,
                             temperature=0.0, verbose=False)
        return out.text, out.generation_tokens

    def peak_gb(self):
        return self.mx.get_peak_memory() / 1e9


class TorchRunner:
    def __init__(self):
        import torch
        from transformers import AutoModelForImageTextToText, AutoProcessor

        self.torch = torch
        self.processor = AutoProcessor.from_pretrained(HF_MODEL)
        self.model = AutoModelForImageTextToText.from_pretrained(HF_MODEL, dtype=torch.bfloat16, attn_implementation="sdpa")
        self.model.to("mps").eval()
        self.prompt = D.prompt_text(self.processor, (HF_MODEL / "equipay_prompt.txt").read_text().strip())

    def __call__(self, image):
        with self.torch.no_grad():
            inputs = self.processor(text=[self.prompt], images=[[image]], return_tensors="pt").to("mps")
            out = self.model.generate(**inputs, max_new_tokens=1024, do_sample=False, use_cache=True)
            new = out[0, inputs["input_ids"].shape[1]:]
            return self.processor.decode(new, skip_special_tokens=True), len(new)

    def peak_gb(self):
        return self.torch.mps.driver_allocated_memory() / 1e9


def evaluate(backend: str, bits: int, limit: int | None, log: bool) -> dict:
    rows = D.read_split("test", limit, stratify=bool(limit))
    start = time.perf_counter()
    runner = MlxRunner(mlx_dir(bits)) if backend == "mlx" else TorchRunner()
    load_s = time.perf_counter() - start
    print(f"Modèle {backend} chargé en {load_s:.1f}s — {len(rows)} tickets", flush=True)

    scores, preds, latencies, tokens = [], [], [], 0
    for i, row in enumerate(rows, 1):
        image = D.load_image(row, MAX_SIDE)
        tic = time.perf_counter()
        text, n = runner(image)
        latencies.append(time.perf_counter() - tic)
        tokens += n
        pred = M.parse_json(text)
        score = M.score_ticket(pred, row["target"], row["fields"], row.get("other_amounts"), row["source"])
        scores.append(score)
        preds.append({"image": row["image"], "source": row["source"], "fields": row["fields"], "gold": row["target"],
                      "raw": text, "pred": pred, "total_error": score["total_error"],
                      "ok": {f: score[f + "_ok"] for f in M.FIELDS if score[f + "_ok"] is not None}})
        if i % 25 == 0 or i == len(rows):
            ok = sum(bool(s["amount_ok"]) for s in scores)
            print(f"  {i}/{len(rows)} — total juste {ok}/{i} — {sum(latencies) / i:.1f}s/ticket", flush=True)

    metrics = M.aggregate(scores, latencies)
    metrics["tokens_per_s"] = tokens / sum(latencies)
    metrics["peak_mem_gb"] = runner.peak_gb()
    metrics["load_s"] = load_s

    name = f"mac_mlx{bits}_eval" if backend == "mlx" else "mac_torch_eval"
    # Essai partiel : rangé à part, pour ne jamais écraser l'évaluation complète (ni dans MLflow)
    if limit:
        name, log = f"{name}_essai", False
    folder = SCANNER / "evaluation" / name
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "metrics.json").write_text(json.dumps(metrics, indent=2, ensure_ascii=False))
    (folder / "par_source.json").write_text(json.dumps(M.breakdown(scores, "source"), indent=2, ensure_ascii=False))
    (folder / "par_devise.json").write_text(json.dumps(M.breakdown(scores, "currency_gold"), indent=2, ensure_ascii=False))
    with open(folder / "predictions.jsonl", "w", encoding="utf-8") as f:
        for p in preds:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
    for file, fig in M.figures(scores, f"Mac {backend}").items():
        fig.savefig(folder / file, dpi=130)

    if log:
        import mlflow

        mlflow.set_tracking_uri(os.environ.get("EQUIPAY_MLFLOW_URI", "http://127.0.0.1:5000"))
        with mlflow.start_run(run_id=V2_RUN_ID):
            mlflow.log_metrics({f"{name}_{k}": float(v) for k, v in metrics.items()})
            mlflow.log_artifacts(str(folder), name)
            if backend == "mlx":
                mlflow.set_tag(f"mac_mlx{bits}_model", f"model/equipay-receipt-scanner/{mlx_dir(bits).name}")
    print(json.dumps({k: round(v, 4) for k, v in metrics.items() if isinstance(v, float)}, indent=1))
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert")
    c.add_argument("--bits", type=int, default=4)
    e = sub.add_parser("eval")
    e.add_argument("--backend", choices=["mlx", "torch"], default="mlx")
    e.add_argument("--bits", type=int, default=4)
    e.add_argument("--limit", type=int)
    e.add_argument("--no-log", action="store_true")
    args = parser.parse_args()
    if args.cmd == "convert":
        convert(args.bits)
    else:
        evaluate(args.backend, args.bits, args.limit, not args.no_log)


if __name__ == "__main__":
    main()
