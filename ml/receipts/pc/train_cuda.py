"""Fine-tuning LoRA du scanner de reçus EquiPay v2 sur GPU NVIDIA, suivi dans MLflow (un seul run).

  python train_cuda.py                                   → entraînement complet + évaluation + registre
  python train_cuda.py --max-steps 10 --eval-limit 16 --epoch-eval-limit 0 --no-baseline --no-v1 --experiment Equipay-receipts-essai-v2
                                                         → essai éclair pour valider la chaîne

Déroulé du run :
  1. entraînement (perte uniquement sur les champs ANNOTÉS du JSON), validation régulière
  2. sauvegarde du MEILLEUR adaptateur (perte de validation la plus basse) + arrêt anticipé
  3. à chaque fin d'epoch : extraction réelle sur des tickets de validation des 4 sources
  4. à la fin : évaluation complète sur 615 tickets de test du modèle v2, du modèle de base et de la v1
  5. inscription dans le registre MLflow « equipay-receipt » (alias champion s'il bat la v1)
"""
import argparse
import json
import math
import os
import platform
import random
import shutil
import tempfile
import time
from pathlib import Path

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")
os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")  # moins de fragmentation mémoire

import mlflow  # noqa: E402
import torch  # noqa: E402

import evaluate_cuda  # noqa: E402
import receipt_data as D  # noqa: E402
import receipt_metrics as M  # noqa: E402

HERE = Path(__file__).resolve().parent
CUDA = torch.cuda.is_available()
DEVICE = "cuda" if CUDA else "cpu"
OUTPUTS = HERE / "outputs"
REGISTRY = "equipay-receipt"
# LoRA sur le modèle de langage uniquement (la partie vision reste gelée)
TARGET_MODULES = r".*language_model.*\.(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)$"


def gpu_mem():
    return torch.cuda.max_memory_allocated() / 1e9 if CUDA else 0.0


def batches(rows, size, rng):
    rows = rows[:]
    if rng:
        rng.shuffle(rows)
    for i in range(0, len(rows), size):
        yield rows[i: i + size]


@torch.no_grad()
def validate(model, rows, collator, batch_size):
    model.eval()
    total, tokens, correct = 0.0, 0, 0
    for chunk in batches(rows, batch_size, None):
        batch = collator(chunk).to(model.device)
        with torch.autocast("cuda", dtype=torch.bfloat16, enabled=torch.cuda.is_available()):
            out = model(**batch)
        labels = batch["labels"][:, 1:]
        keep = labels != -100
        n = int(keep.sum())
        total += float(out.loss) * n
        tokens += n
        correct += int((out.logits[:, :-1].argmax(-1)[keep] == labels[keep]).sum())
        del out
    model.train()
    loss = total / max(tokens, 1)
    return {"val_loss": loss, "val_perplexity": math.exp(min(loss, 20)), "val_token_accuracy": correct / max(tokens, 1)}


def curves_figure(history):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, (a, b) = plt.subplots(1, 2, figsize=(11, 4))
    if history["train"]:
        a.plot(*zip(*history["train"]), label="entraînement", alpha=0.7)
    if history["val"]:
        a.plot(*zip(*history["val"]), "o-", label="validation")
    if history["best"] is not None:
        a.axvline(history["best"], color="green", ls="--", label="meilleur point")
    a.set_xlabel("étape")
    a.set_ylabel("perte")
    a.legend()
    a.set_title("Pertes")
    if history["lr"]:
        b.plot(*zip(*history["lr"]))
    b.set_xlabel("étape")
    b.set_title("Learning rate")
    fig.tight_layout()
    return fig


def epoch_figure(epochs):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(7, 4))
    xs = [e["epoch"] for e in epochs]
    for key, label in [("score", "score global"), ("amount_accuracy", "total juste"), ("items_f1", "articles F1")]:
        ax.plot(xs, [e[key] for e in epochs], "o-", label=label)
    ax.set_xlabel("epoch")
    ax.set_ylim(0, 1)
    ax.legend()
    ax.set_title("Extraction sur la validation, par epoch")
    fig.tight_layout()
    return fig


def log_figure(fig, name, folder):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / name
        fig.savefig(path, dpi=130)
        mlflow.log_artifact(str(path), folder)


def main():
    from peft import LoraConfig, get_peft_model
    from transformers import AutoModelForImageTextToText, AutoProcessor, get_cosine_schedule_with_warmup

    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", default=evaluate_cuda.BASE_MODEL)
    p.add_argument("--epochs", type=float, default=2)
    p.add_argument("--lr", type=float, default=1e-4)
    p.add_argument("--warmup-ratio", type=float, default=0.05)
    p.add_argument("--batch-size", type=int, default=2)
    p.add_argument("--grad-accum", type=int, default=4, help="batch effectif = batch-size × grad-accum")
    p.add_argument("--max-side", type=int, default=1024, help="plus grand côté de l'image (pixels)")
    p.add_argument("--max-len", type=int, default=2048)
    p.add_argument("--rank", type=int, default=16)
    p.add_argument("--alpha", type=float, default=32)
    p.add_argument("--dropout", type=float, default=0.05)
    p.add_argument("--evals-per-epoch", type=int, default=2, help="validations par epoch")
    p.add_argument("--patience", type=int, default=3, help="arrêt après N validations sans progrès")
    p.add_argument("--epoch-eval-limit", type=int, default=80, help="tickets de validation extraits par epoch (0 = non)")
    p.add_argument("--eval-limit", type=int, help="tickets de test de l'éval finale (défaut : tous)")
    p.add_argument("--eval-batch-size", type=int, default=8)
    p.add_argument("--val-batch-size", type=int, default=2)
    p.add_argument("--no-baseline", action="store_true", help="ne pas évaluer le modèle de base")
    p.add_argument("--no-v1", action="store_true", help="ne pas comparer avec la v1 du registre")
    p.add_argument("--no-grad-checkpointing", action="store_true", help="plus rapide, mais plus de mémoire")
    p.add_argument("--no-register", action="store_true", help="ne pas inscrire dans le registre")
    p.add_argument("--max-steps", type=int, help="limite d'étapes (essai éclair)")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--experiment", default="Equipay-receipts")
    p.add_argument("--registry", default=REGISTRY)
    p.add_argument("--tracking-uri", default=os.environ.get("EQUIPAY_MLFLOW_URI", "http://192.168.1.23:5000"))
    args = p.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    if not torch.cuda.is_available() and not os.environ.get("EQUIPAY_ALLOW_CPU"):
        raise SystemExit("Pas de GPU CUDA : ce script est fait pour la RTX 5080.")
    torch.backends.cuda.matmul.allow_tf32 = True
    gpu_name = torch.cuda.get_device_name(0) if CUDA else "cpu (test)"

    mlflow.set_tracking_uri(args.tracking_uri)
    mlflow.set_experiment(args.experiment)  # créée si elle n'existe pas

    processor = AutoProcessor.from_pretrained(args.model)
    processor.tokenizer.padding_side = "right"
    model = AutoModelForImageTextToText.from_pretrained(args.model, dtype=torch.bfloat16, attn_implementation="sdpa")
    model.to(DEVICE)
    model.config.use_cache = False
    if not args.no_grad_checkpointing:
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model.enable_input_require_grads()
    model = get_peft_model(model, LoraConfig(r=args.rank, lora_alpha=args.alpha, lora_dropout=args.dropout,
                                             target_modules=TARGET_MODULES))
    trainable = sum(x.numel() for x in model.parameters() if x.requires_grad)
    total_params = sum(x.numel() for x in model.parameters())

    manifest = json.loads((D.DATA / "manifest.json").read_text())
    train_rows, val_rows = D.read_split("train"), D.read_split("validation")
    collator = D.TrainCollator(processor, args.max_side, args.max_len)
    steps_per_epoch = math.ceil(len(train_rows) / (args.batch_size * args.grad_accum))
    total_steps = math.ceil(steps_per_epoch * args.epochs)
    if args.max_steps:
        total_steps = min(total_steps, args.max_steps)
    eval_every = max(1, steps_per_epoch // args.evals_per_epoch)
    run_name = f"cuda-lora-qwen3vl4b-v2-{args.epochs:g}ep-r{args.rank}-{args.max_side}px"
    print(f"{len(train_rows)} tickets d'entraînement, {len(val_rows)} de validation, {total_steps} étapes "
          f"({steps_per_epoch} par epoch). Paramètres entraînables : {trainable / 1e6:.1f} M", flush=True)

    optimizer = torch.optim.AdamW([x for x in model.parameters() if x.requires_grad], lr=args.lr, weight_decay=0.0)
    scheduler = get_cosine_schedule_with_warmup(optimizer, int(args.warmup_ratio * total_steps), total_steps)

    out_dir = OUTPUTS / run_name
    best_dir = out_dir / "adapter"
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)

    try:
        ctx = mlflow.start_run(run_name=run_name, log_system_metrics=True)
    except Exception:
        ctx = mlflow.start_run(run_name=run_name)
    with ctx as run:
        try:
            mlflow.set_tags({"stage": "fine-tuned-cuda", "base_model": args.model, "task": "receipt-extraction",
                             "hardware": gpu_name, "status": "training",
                             "dataset_version": "2"})
            mlflow.log_params({
                "base_model": args.model, "epochs": args.epochs, "lr": args.lr, "warmup_ratio": args.warmup_ratio,
                "batch_size": args.batch_size, "grad_accum": args.grad_accum,
                "effective_batch": args.batch_size * args.grad_accum, "max_side": args.max_side,
                "max_len": args.max_len, "lora_rank": args.rank, "lora_alpha": args.alpha,
                "lora_dropout": args.dropout, "lora_targets": "language_model q,k,v,o,gate,up,down",
                "grad_checkpointing": not args.no_grad_checkpointing, "patience": args.patience,
                "total_steps": total_steps, "steps_per_epoch": steps_per_epoch, "seed": args.seed,
                "dataset_sha": manifest["dataset_sha"], "dataset_version": 2,
                "dataset_sources": ", ".join(manifest["sources"]),
                "train_examples": len(train_rows), "val_examples": len(val_rows),
                "test_examples": manifest["splits"]["test"]["total"], "trainable_params": trainable,
                "total_params": total_params, "torch": torch.__version__, "cuda": torch.version.cuda,
                "gpu": gpu_name, "python": platform.python_version(),
                "score_weights": json.dumps(M.SCORE_WEIGHTS),
            })
            mlflow.set_tag("dataset_sha", manifest["dataset_sha"])
            mlflow.log_artifact(str(D.DATA / "manifest.json"), "dataset")
            for script in ("train_cuda.py", "evaluate_cuda.py", "receipt_data.py", "receipt_metrics.py", "api.py"):
                if (HERE / script).exists():
                    mlflow.log_artifact(str(HERE / script), "code")
            train_and_evaluate(run, args, model, processor, collator, train_rows, val_rows, manifest,
                               steps_per_epoch, total_steps, eval_every, optimizer, scheduler, best_dir, out_dir)
        except BaseException:
            mlflow.set_tag("status", "failed")
            raise


def train_and_evaluate(run, args, model, processor, collator, train_rows, val_rows, manifest, steps_per_epoch,
                       total_steps, eval_every, optimizer, scheduler, best_dir, out_dir):
    from peft import set_peft_model_state_dict
    from safetensors.torch import load_file

    history = {"train": [], "val": [], "lr": [], "best": None}
    quick_rows = D.read_split("validation", args.epoch_eval_limit, stratify=True) if args.epoch_eval_limit else []
    epoch_results = []
    best = {"val_loss": float("inf"), "step": 0, "epoch": 0.0}
    bad_evals, step, stop = 0, 0, False
    rng = random.Random(args.seed)
    if CUDA:
        torch.cuda.reset_peak_memory_stats()
    start = time.perf_counter()
    window = {"loss": 0.0, "n": 0, "tokens": 0, "time": time.perf_counter()}
    model.train()

    def run_validation():
        nonlocal bad_evals, stop
        v = validate(model, val_rows, collator, args.val_batch_size)
        mlflow.log_metrics(v, step=step)
        history["val"].append((step, v["val_loss"]))
        print(f"  [{step}/{total_steps}] val_loss={v['val_loss']:.4f} précision jetons={v['val_token_accuracy']:.3f}",
              flush=True)
        if v["val_loss"] < best["val_loss"]:
            best.update(val_loss=v["val_loss"], step=step, epoch=step / steps_per_epoch)
            history["best"] = step
            model.save_pretrained(best_dir)
            bad_evals = 0
        else:
            bad_evals += 1
            if bad_evals >= args.patience:
                print(f"  arrêt anticipé : {args.patience} validations sans progrès", flush=True)
                stop = True

    epoch = 0
    while step < total_steps and not stop:
        epoch += 1
        micro = 0
        optimizer.zero_grad(set_to_none=True)
        for chunk in batches(train_rows, args.batch_size, rng):
            batch = collator(chunk).to(DEVICE)
            with torch.autocast("cuda", dtype=torch.bfloat16, enabled=CUDA):
                loss = model(**batch).loss
            (loss / args.grad_accum).backward()
            window["loss"] += float(loss.detach())
            window["n"] += 1
            window["tokens"] += int(batch["attention_mask"].sum())
            micro += 1
            if micro % args.grad_accum:
                continue
            grad_norm = float(torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0))
            optimizer.step()
            scheduler.step()
            optimizer.zero_grad(set_to_none=True)
            step += 1
            if step % 5 == 0 or step == total_steps:
                elapsed = time.perf_counter() - window["time"]
                lr = scheduler.get_last_lr()[0]
                train_loss = window["loss"] / max(window["n"], 1)
                mlflow.log_metrics({"train_loss": train_loss, "learning_rate": lr, "grad_norm": grad_norm,
                                    "train_tokens_per_s": window["tokens"] / max(elapsed, 1e-9),
                                    "step_time_s": elapsed / 5, "epoch": step / steps_per_epoch,
                                    "gpu_mem_gb": gpu_mem()}, step=step)
                history["train"].append((step, train_loss))
                history["lr"].append((step, lr))
                remaining = (total_steps - step) * elapsed / 5
                print(f"  [{step}/{total_steps}] loss={train_loss:.4f} lr={lr:.2e} "
                      f"mém={gpu_mem():.1f} Go reste≈{remaining / 60:.0f} min", flush=True)
                window = {"loss": 0.0, "n": 0, "tokens": 0, "time": time.perf_counter()}
            if step % eval_every == 0:
                run_validation()
            if step >= total_steps or stop:
                break
        if not history["val"] or history["val"][-1][0] != step:
            run_validation()
        if args.epoch_eval_limit and not args.max_steps:
            model.eval()
            quick, _, _ = evaluate_cuda.evaluate(model, processor, quick_rows, args.max_side, args.eval_batch_size,
                                                 progress=False)
            processor.tokenizer.padding_side = "right"
            quick["epoch"] = epoch
            epoch_results.append(quick)
            mlflow.log_metrics({f"epoch_eval_{k}": quick[k] for k in
                                ("score", "amount_accuracy", "amount_accuracy_decimals", "currency_accuracy",
                                 "date_accuracy", "merchant_accuracy", "items_f1", "json_valid_rate",
                                 "ticket_exact_match")}, step=epoch)
            print(f"  epoch {epoch} : score {quick['score']:.3f}, total juste {quick['amount_accuracy']:.0%}, "
                  f"articles F1 {quick['items_f1']:.3f}", flush=True)
            model.train()

    train_time = time.perf_counter() - start
    mlflow.log_metrics({"best_val_loss": best["val_loss"], "best_step": best["step"], "best_epoch": best["epoch"],
                        "steps_done": step, "train_time_s": train_time, "stopped_early": float(stop),
                        "peak_gpu_mem_gb": gpu_mem()})
    log_figure(curves_figure(history), "courbes.png", "training")
    if epoch_results:
        log_figure(epoch_figure(epoch_results), "score_par_epoch.png", "training")
    processor.save_pretrained(best_dir)  # l'adaptateur se suffit avec son processeur
    (best_dir / "equipay_prompt.txt").write_text(D.PROMPT, encoding="utf-8")
    mlflow.log_artifacts(str(best_dir), "adapter")
    print(f"Meilleur point : étape {best['step']} (epoch {best['epoch']:.2f}), val_loss={best['val_loss']:.4f}",
          flush=True)

    # Évaluation complète du meilleur adaptateur, puis du modèle de base
    set_peft_model_state_dict(model, load_file(str(best_dir / "adapter_model.safetensors")))
    model.eval()
    model.config.use_cache = True
    mlflow.log_metrics({"train_masked_tokens": collator.stats["masked_tokens"],
                        "train_answer_tokens": collator.stats["answer_tokens"],
                        "train_misaligned_examples": collator.stats["misaligned"]})
    tuned, results = evaluate_cuda.full_evaluation(model, processor, args, baseline=not args.no_baseline,
                                                   compare_v1=not args.no_v1)
    (out_dir / "metrics.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))

    if not args.no_register and not args.max_steps:
        register(run, tuned, manifest, args.registry, results.get("v1"))
    mlflow.set_tag("status", "done")
    print(f"\n✓ Run {run.info.run_id} — score {tuned['score']:.3f}, total juste {tuned['amount_accuracy']:.1%}, "
          f"articles F1 {tuned['items_f1']:.3f}, durée {train_time / 60:.0f} min\n"
          f"  Adaptateur local : {best_dir}", flush=True)


def register(run, tuned, manifest, registry=REGISTRY, v1=None):
    """Inscrit l'adaptateur dans le registre ; alias « champion » s'il bat la v1 sur le même test v2."""
    client = mlflow.MlflowClient()
    try:
        client.create_registered_model(registry, description="Scanner de reçus EquiPay (adaptateur LoRA Qwen3-VL)")
    except Exception:
        pass  # existe déjà
    version = client.create_model_version(registry, source=f"{run.info.artifact_uri}/adapter", run_id=run.info.run_id)
    for key, value in {"dataset_sha": manifest["dataset_sha"], "eval_score": f"{tuned['score']:.4f}",
                       "eval_amount_accuracy": f"{tuned['amount_accuracy']:.4f}",
                       "eval_items_f1": f"{tuned['items_f1']:.4f}", "format": "peft-lora", "dataset_version": "2",
                       "eval_amount_accuracy_decimals": f"{tuned['amount_accuracy_decimals']:.4f}",
                       "base_model": evaluate_cuda.BASE_MODEL}.items():
        client.set_model_version_tag(registry, version.version, key, value)
    if v1 is not None:
        better = tuned["score"] > v1["score"]
    else:
        try:
            champ = client.get_model_version_by_alias(registry, "champion")
            same_data = champ.tags.get("dataset_sha") == manifest["dataset_sha"]
            better = not same_data or tuned["score"] > float(champ.tags.get("eval_score", 0))
        except Exception:
            better = True
    if better:
        client.set_registered_model_alias(registry, "champion", version.version)
    mlflow.set_tag("registered_version", version.version)
    print(f"Registre : {registry} v{version.version}" + (" (champion)" if better else ""), flush=True)


if __name__ == "__main__":
    main()
