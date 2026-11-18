"""Évaluation du scanner de reçus v2 sur le jeu de test (615 tickets, 4 sources, 7 devises).

  python evaluate_cuda.py --run-id <RUN_ID>     → complète un run existant (adaptateur dans outputs/<run>/adapter)
Appelé normalement par train_cuda.py à la fin de l'entraînement. Compare 3 modèles :
  - « affine » (v2), « base » (Qwen3-VL-4B sans entraînement), « v1 » (champion précédent, avec son prompt v1)
"""
import argparse
import json
import os
import tempfile
import time
from pathlib import Path

os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")

import mlflow  # noqa: E402
import torch  # noqa: E402

import receipt_data as D  # noqa: E402
import receipt_metrics as M  # noqa: E402

BASE_MODEL = "Qwen/Qwen3-VL-4B-Instruct"
REGISTRY = "equipay-receipt"


def device():
    if torch.cuda.is_available():
        return "cuda"
    return "mps" if torch.backends.mps.is_available() else "cpu"


def load_model(adapter=None, model_name=BASE_MODEL, merge=False):
    from transformers import AutoModelForImageTextToText, AutoProcessor

    processor = AutoProcessor.from_pretrained(model_name)
    model = AutoModelForImageTextToText.from_pretrained(model_name, dtype=torch.bfloat16, attn_implementation="sdpa")
    model.to(device())
    if adapter:
        from peft import PeftModel

        model = PeftModel.from_pretrained(model, str(adapter))
        if merge:
            model = model.merge_and_unload()
    model.eval()
    return model, processor


@torch.no_grad()
def predict(model, processor, images, prompt=D.PROMPT, max_new_tokens=int(os.environ.get("EQUIPAY_MAX_NEW_TOKENS", 1024))):
    processor.tokenizer.padding_side = "left"
    text = D.prompt_text(processor, prompt)
    inputs = processor(text=[text] * len(images), images=[[im] for im in images], return_tensors="pt", padding=True)
    inputs = inputs.to(model.device)
    out = model.generate(**inputs, max_new_tokens=max_new_tokens, do_sample=False, use_cache=True)
    new = out[:, inputs["input_ids"].shape[1]:]
    texts = processor.batch_decode(new, skip_special_tokens=True)
    lengths = [int((row != processor.tokenizer.pad_token_id).sum()) for row in new]
    return texts, lengths


def evaluate(model, processor, rows, max_side, batch_size=8, prompt=D.PROMPT, progress=True):
    """Renvoie (métriques, scores par ticket, prédictions)."""
    scores, preds, latencies, tokens, total_time = [], [], [], 0, 0.0
    for start in range(0, len(rows), batch_size):
        chunk = rows[start: start + batch_size]
        images = [D.load_image(r, max_side) for r in chunk]
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        tic = time.perf_counter()
        texts, lengths = predict(model, processor, images, prompt)
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        elapsed = time.perf_counter() - tic
        total_time += elapsed
        tokens += sum(lengths)
        for row, text in zip(chunk, texts):
            pred = M.parse_json(text)
            score = M.score_ticket(pred, row["target"], row["fields"], row.get("other_amounts"), row["source"])
            scores.append(score)
            latencies.append(elapsed / len(chunk))
            preds.append({"image": row["image"], "source": row["source"], "fields": row["fields"], "gold": row["target"],
                          "raw": text, "pred": pred, "total_error": score["total_error"],
                          "ok": {f: score[f + "_ok"] for f in M.FIELDS if score[f + "_ok"] is not None}})
        if progress and (start // batch_size) % 5 == 0:
            done = min(start + batch_size, len(rows))
            print(f"    {done}/{len(rows)} tickets — total juste : {sum(bool(s['amount_ok']) for s in scores)}/{done}", flush=True)
    metrics = M.aggregate(scores, latencies)
    metrics["tokens_per_s"] = tokens / max(total_time, 1e-9)
    if torch.cuda.is_available():
        metrics["peak_gpu_mem_gb"] = torch.cuda.max_memory_allocated() / 1e9
    return metrics, scores, preds


def log_evaluation(prefix, folder, metrics, scores, preds, title):
    mlflow.log_metrics({f"{prefix}{k}": float(v) for k, v in metrics.items()})
    by_source, by_currency = M.breakdown(scores, "source"), M.breakdown(scores, "currency_gold")
    for group, name in [(by_source, "src"), (by_currency, "cur")]:
        for g, values in group.items():
            safe = "inconnue" if g == "?" else g
            mlflow.log_metrics({f"{prefix}{name}_{safe}_{k}": float(v) for k, v in values.items()})
    real, cols, matrix = M.currency_confusion(scores)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "metrics.json").write_text(json.dumps(metrics, indent=2, ensure_ascii=False))
        (tmp / "par_source.json").write_text(json.dumps(by_source, indent=2, ensure_ascii=False))
        (tmp / "par_devise.json").write_text(json.dumps(by_currency, indent=2, ensure_ascii=False))
        with open(tmp / "predictions.jsonl", "w", encoding="utf-8") as f:
            for p in preds:
                f.write(json.dumps(p, ensure_ascii=False) + "\n")
        (tmp / "confusion.json").write_text(json.dumps({
            "articles": {"rows": ["réel : présent", "réel : absent"], "cols": ["prédit : présent", "prédit : absent"],
                         "matrix": M.confusion_items(scores)},
            "champs": {"rows": [M.FIELD_NAMES[f] for f in M.FIELDS], "cols": M.OUTCOMES, "matrix": M.field_outcomes(scores)},
            "devises": {"rows": real, "cols": cols, "matrix": matrix},
            "total": M.total_error_counts(scores),
        }, indent=2, ensure_ascii=False))
        for name, fig in M.figures(scores, title).items():
            fig.savefig(tmp / name, dpi=130)
        mlflow.log_artifacts(str(tmp), folder)


def v1_adapter(dst):
    """Télécharge l'adaptateur de la version 1 du registre (le champion précédent)."""
    client = mlflow.MlflowClient()
    version = client.get_model_version(REGISTRY, "1")
    return mlflow.artifacts.download_artifacts(artifact_uri=version.source, dst_path=str(dst))


def full_evaluation(model, processor, args, baseline=True, compare_v1=True):
    rows = D.read_split("test", args.eval_limit, stratify=bool(args.eval_limit))
    results = {}
    print(f"Évaluation du modèle affiné (v2) sur {len(rows)} tickets de test…", flush=True)
    tuned, scores, preds = evaluate(model, processor, rows, args.max_side, args.eval_batch_size)
    log_evaluation("eval_", "eval", tuned, scores, preds, "v2 affiné")
    results["v2 (affiné)"] = tuned
    if baseline:
        print("Évaluation du modèle de base (zéro-shot)…", flush=True)
        with model.disable_adapter():
            base, b_scores, b_preds = evaluate(model, processor, rows, args.max_side, args.eval_batch_size)
        log_evaluation("base_eval_", "base_eval", base, b_scores, b_preds, "modèle de base")
        mlflow.log_metrics({"eval_score_gain_vs_base": tuned["score"] - base["score"]})
        results["base"] = base
    if compare_v1:
        try:
            path = v1_adapter(Path(tempfile.mkdtemp()))
            print("Évaluation de la v1 (champion précédent, prompt v1)…", flush=True)
            model.load_adapter(path, adapter_name="v1")
            model.set_adapter("v1")
            v1, v_scores, v_preds = evaluate(model, processor, rows, args.max_side, args.eval_batch_size, D.PROMPT_V1)
            model.set_adapter("default")
            model.delete_adapter("v1")
            log_evaluation("v1_eval_", "v1_eval", v1, v_scores, v_preds, "v1")
            mlflow.log_metrics({"eval_score_gain_vs_v1": tuned["score"] - v1["score"],
                                "eval_amount_accuracy_gain_vs_v1": tuned["amount_accuracy"] - v1["amount_accuracy"]})
            results["v1"] = v1
        except Exception as e:  # registre injoignable : la comparaison v1 est seulement sautée
            print(f"  comparaison v1 impossible : {e}", flush=True)
            try:
                model.set_adapter("default")
            except Exception:
                pass
    with tempfile.TemporaryDirectory() as tmp:
        M.comparison_figure(results).savefig(Path(tmp) / "comparaison.png", dpi=130)
        keys = ["score", "amount_accuracy", "amount_accuracy_decimals", "amount_text_accuracy", "currency_accuracy",
                "date_accuracy", "merchant_accuracy", "address_accuracy", "items_f1", "ticket_exact_match",
                "total_virgule_ignoree_rate", "json_valid_rate"]
        (Path(tmp) / "comparaison.json").write_text(json.dumps(
            {name: {k: m[k] for k in keys} for name, m in results.items()}, indent=2, ensure_ascii=False))
        mlflow.log_artifacts(tmp, "eval")
    for name, m in results.items():
        print(f"  {name:12} score {m['score']:.3f} | total juste {m['amount_accuracy']:.1%} "
              f"(avec centimes {m['amount_accuracy_decimals']:.1%}) | devise {m['currency_accuracy']:.1%} | "
              f"date {m['date_accuracy']:.1%} | articles F1 {m['items_f1']:.3f}", flush=True)
    return tuned, results


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--adapter")
    parser.add_argument("--max-side", type=int, default=1024)
    parser.add_argument("--eval-limit", type=int)
    parser.add_argument("--eval-batch-size", type=int, default=8)
    parser.add_argument("--no-baseline", action="store_true")
    parser.add_argument("--no-v1", action="store_true")
    parser.add_argument("--tracking-uri", default=os.environ.get("EQUIPAY_MLFLOW_URI", "http://192.168.1.23:5000"))
    args = parser.parse_args()
    mlflow.set_tracking_uri(args.tracking_uri)
    run = mlflow.get_run(args.run_id)
    adapter = args.adapter or Path(__file__).parent / "outputs" / run.info.run_name / "adapter"
    model, processor = load_model(adapter)
    with mlflow.start_run(run_id=args.run_id):
        full_evaluation(model, processor, args, baseline=not args.no_baseline, compare_v1=not args.no_v1)


if __name__ == "__main__":
    main()
