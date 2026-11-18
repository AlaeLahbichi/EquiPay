"""Entraînement LoRA du modèle « Décrire la dépense » (EquiPay) sur GPU NVIDIA, suivi dans MLflow (un seul run).

  python train_cuda.py                                   → entraînement complet + évaluation complète
  python train_cuda.py --max-steps 20 --eval-every 10 --eval-limit 24 --epoch-eval-limit 0 --experiment Equipay-describe-essai
                                                         → essai éclair pour valider la chaîne

Déroulé du run :
  1. entraînement (perte uniquement sur le JSON de la réponse), validation régulière
  2. sauvegarde du MEILLEUR adaptateur (perte de validation la plus basse) + arrêt anticipé
  3. à la fin de chaque epoch : extraction réelle sur 120 phrases de validation (courbe du score)
  4. à la fin : évaluation complète du meilleur adaptateur ET du modèle de base (800 + 50 phrases)
  5. tag status=awaiting_mac_import : le Mac importe ensuite l'adaptateur (fusion, MLX 4 bits, registre)
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

import mlflow  # noqa: E402
import torch  # noqa: E402

import evaluate_cuda  # noqa: E402

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
OUTPUTS = HERE / "outputs"
TARGET_MODULES = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]


def short_name(model: str) -> str:
    return model.split("/")[-1].replace("-Instruct", "")


def read_jsonl(path: Path) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f]


# ------------------------------------------------------------------ données

def encode(tokenizer, messages: list[dict], max_len: int) -> tuple[list[int], list[int], bool]:
    """Tokens du dialogue et étiquettes : -100 sur le prompt (système + question), perte sur la réponse."""
    prompt = tokenizer.apply_chat_template(messages[:-1], add_generation_prompt=True, tokenize=False)
    full = tokenizer.apply_chat_template(messages, tokenize=False)
    if not full.startswith(prompt):
        raise SystemExit(
            "Le modèle de chat ne produit pas le prompt comme préfixe du dialogue complet : "
            "le masquage serait faux. Signale-le avant de continuer."
        )
    prompt_ids = tokenizer(prompt, add_special_tokens=False)["input_ids"]
    ids = tokenizer(full, add_special_tokens=False)["input_ids"]
    # Le dernier saut de ligne après la fin de tour n'apporte rien à apprendre
    labels = [-100] * len(prompt_ids) + ids[len(prompt_ids):]
    truncated = len(ids) > max_len
    return ids[:max_len], labels[:max_len], truncated


def build(tokenizer, rows: list[dict], max_len: int) -> tuple[list[tuple[list[int], list[int]]], int]:
    out, truncated = [], 0
    for r in rows:
        ids, labels, cut = encode(tokenizer, r["messages"], max_len)
        truncated += cut
        if any(l != -100 for l in labels):
            out.append((ids, labels))
    return out, truncated


def batches(data: list, batch_size: int, rng: random.Random | None):
    order = list(range(len(data)))
    if rng:
        rng.shuffle(order)
    for i in range(0, len(order), batch_size):
        yield [data[j] for j in order[i:i + batch_size]]


def collate(batch: list, pad_id: int, device) -> dict:
    width = max(len(ids) for ids, _ in batch)
    input_ids = [ids + [pad_id] * (width - len(ids)) for ids, _ in batch]
    labels = [lab + [-100] * (width - len(lab)) for _, lab in batch]
    mask = [[1] * len(ids) + [0] * (width - len(ids)) for ids, _ in batch]
    as_tensor = lambda x: torch.tensor(x, device=device)  # noqa: E731
    return {"input_ids": as_tensor(input_ids), "labels": as_tensor(labels), "attention_mask": as_tensor(mask)}


def answer_loss(model, batch: dict) -> tuple[torch.Tensor, int, int]:
    """Perte moyenne sur les tokens de réponse. Les logits ne sont calculés que sur ces positions
    (le vocabulaire de Qwen fait ~150 000 mots : tout calculer prendrait plusieurs Go)."""
    base = model.get_base_model()
    hidden = base.model(input_ids=batch["input_ids"], attention_mask=batch["attention_mask"]).last_hidden_state
    targets = batch["labels"][:, 1:]
    keep = targets != -100
    logits = base.lm_head(hidden[:, :-1][keep]).float()
    loss = torch.nn.functional.cross_entropy(logits, targets[keep])
    correct = int((logits.argmax(-1) == targets[keep]).sum())
    return loss, int(keep.sum()), correct


@torch.no_grad()
def validate(model, data: list, batch_size: int, pad_id: int, device) -> dict:
    model.eval()
    total, tokens, correct = 0.0, 0, 0
    for batch in batches(data, batch_size, None):
        with torch.autocast("cuda", dtype=torch.bfloat16, enabled=device.type == "cuda"):
            loss, n, ok = answer_loss(model, collate(batch, pad_id, device))
        total += float(loss) * n
        tokens += n
        correct += ok
    model.train()
    loss = total / max(tokens, 1)
    return {"val_loss": loss, "val_perplexity": math.exp(min(loss, 20)), "val_token_accuracy": correct / max(tokens, 1)}


# ------------------------------------------------------------------ graphiques

def curves_figure(history: dict):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    if history["train"]:
        axes[0].plot(*zip(*history["train"]), label="train_loss", alpha=0.7)
    if history["val"]:
        axes[0].plot(*zip(*history["val"]), "o-", label="val_loss", color="#F97316")
    if history["best"]:
        axes[0].axvline(history["best"], color="#0D9488", linestyle="--", label="meilleur point")
    axes[0].set_xlabel("étape d'optimisation")
    axes[0].set_title("Pertes (réponse uniquement)")
    axes[0].legend()
    if history["lr"]:
        axes[1].plot(*zip(*history["lr"]), color="#64748B")
    axes[1].set_xlabel("étape d'optimisation")
    axes[1].set_title("Learning rate")
    fig.tight_layout()
    return fig


def epoch_figure(epochs: list[dict]):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(8, 5))
    for key, label in [("score", "Score global"), ("exact_match", "Dépense entièrement juste"),
                       ("amount_accuracy", "Montant"), ("participants_accuracy", "Participants"),
                       ("paid_by_accuracy", "Payeur"), ("date_accuracy", "Date"), ("invented_any_rate", "Champs inventés")]:
        ax.plot([e["epoch"] for e in epochs], [e[key] for e in epochs], "o-", label=label)
    ax.set_xlabel("epoch")
    ax.set_ylim(0, 1)
    ax.set_title("Évaluation rapide en génération à chaque epoch")
    ax.legend(fontsize=8)
    fig.tight_layout()
    return fig


def log_figure(fig, name: str, folder: str) -> None:
    import matplotlib.pyplot as plt

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / name
        fig.savefig(path, dpi=120, bbox_inches="tight")
        mlflow.log_artifact(str(path), folder)
    plt.close(fig)


# ------------------------------------------------------------------ entraînement

def main() -> None:
    from peft import LoraConfig, get_peft_model
    from transformers import AutoModelForCausalLM, AutoTokenizer, get_cosine_schedule_with_warmup

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="Qwen/Qwen3-4B-Instruct-2507")
    parser.add_argument("--epochs", type=float, default=2)
    parser.add_argument("--lr", type=float, default=2e-4)
    parser.add_argument("--warmup-ratio", type=float, default=0.03)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--grad-accum", type=int, default=2, help="batch effectif = batch-size × grad-accum")
    parser.add_argument("--max-len", type=int, default=640)
    parser.add_argument("--rank", type=int, default=16)
    parser.add_argument("--alpha", type=float, default=32, help="échelle LoRA = alpha / rang")
    parser.add_argument("--dropout", type=float, default=0.05)
    parser.add_argument("--layers", type=int, default=0, help="nombre de dernières couches (0 = toutes)")
    parser.add_argument("--eval-every", type=int, default=150, help="validation toutes les N étapes")
    parser.add_argument("--patience", type=int, default=4, help="arrêt après N validations sans progrès")
    parser.add_argument("--epoch-eval-limit", type=int, default=120, help="phrases de l'éval par epoch (0 = non)")
    parser.add_argument("--eval-limit", type=int, help="phrases de l'éval finale (défaut : toutes)")
    parser.add_argument("--eval-batch-size", type=int, default=32)
    parser.add_argument("--no-baseline", action="store_true", help="ne pas évaluer le modèle de base")
    parser.add_argument("--grad-checkpointing", action="store_true", help="si la mémoire GPU ne suffit pas")
    parser.add_argument("--max-steps", type=int, help="limite d'étapes (essai éclair)")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--experiment", default="Equipay-describe")
    parser.add_argument("--tracking-uri", default=os.environ.get("EQUIPAY_MLFLOW_URI", "http://192.168.1.58:5000"))
    args = parser.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        device = torch.device("cuda")
    else:  # essais hors PC uniquement (Mac : MPS, sinon CPU)
        device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        print(f"⚠ Pas de GPU CUDA : exécution sur {device.type} (uniquement pour un essai).", flush=True)

    # --- MLflow
    mlflow.set_tracking_uri(args.tracking_uri)
    if mlflow.get_experiment_by_name(args.experiment) is None:
        if args.experiment == "Equipay-describe":
            raise SystemExit("L'expérimentation Equipay-describe est introuvable : vérifie le serveur MLflow du Mac.")
        mlflow.create_experiment(args.experiment)
    mlflow.set_experiment(args.experiment)

    # --- modèle et données
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16, attn_implementation="sdpa").to(device)
    n_layers = model.config.num_hidden_layers
    layers = n_layers if args.layers in (0, n_layers) else args.layers
    if args.grad_checkpointing:
        model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
        model.enable_input_require_grads()
    lora = LoraConfig(
        r=args.rank, lora_alpha=args.alpha, lora_dropout=args.dropout, target_modules=TARGET_MODULES,
        layers_to_transform=None if layers == n_layers else list(range(n_layers - layers, n_layers)),
        task_type="CAUSAL_LM",
    )
    model = get_peft_model(model, lora)
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total_params = sum(p.numel() for p in model.parameters())

    manifest = json.loads((DATA / "manifest.json").read_text())
    train, cut_train = build(tokenizer, read_jsonl(DATA / "train.jsonl"), args.max_len)
    valid, cut_valid = build(tokenizer, read_jsonl(DATA / "valid.jsonl"), args.max_len)
    steps_per_epoch = math.ceil(len(train) / (args.batch_size * args.grad_accum))
    total_steps = math.ceil(steps_per_epoch * args.epochs)
    if args.max_steps:
        total_steps = min(total_steps, args.max_steps)
    epochs_label = f"{args.epochs:g}ep"
    run_name = f"cuda-lora-{short_name(args.model)}-{epochs_label}-L{layers}-r{args.rank}"
    print(f"{len(train)} exemples d'entraînement, {len(valid)} de validation, {total_steps} étapes "
          f"({steps_per_epoch} par epoch). Paramètres entraînables : {trainable / 1e6:.1f} M", flush=True)

    optimizer = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=args.lr, weight_decay=0.0)
    scheduler = get_cosine_schedule_with_warmup(optimizer, int(args.warmup_ratio * total_steps), total_steps)

    out_dir = OUTPUTS / run_name
    best_dir = out_dir / "adapter"
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)

    try:
        run_ctx = mlflow.start_run(run_name=run_name, log_system_metrics=True)
    except Exception:  # psutil / pynvml absents : pas de métriques système
        run_ctx = mlflow.start_run(run_name=run_name)
    with run_ctx as run:
        try:
            train_and_evaluate(run, args, model, tokenizer, train, valid, manifest, device, layers,
                               steps_per_epoch, total_steps, run_name, trainable, total_params,
                               cut_train, cut_valid, optimizer, scheduler, best_dir)
        except BaseException:
            mlflow.set_tag("status", "failed")
            raise


def train_and_evaluate(run, args, model, tokenizer, train, valid, manifest, device, layers, steps_per_epoch,
                       total_steps, run_name, trainable, total_params, cut_train, cut_valid, optimizer,
                       scheduler, best_dir) -> None:
    from peft import set_peft_model_state_dict
    from safetensors.torch import load_file

    mlflow.set_tags({
        "stage": "fine-tuned-cuda", "base_model": args.model, "status": "training",
        "hardware": torch.cuda.get_device_name(0) if device.type == "cuda" else platform.processor(),
        "dataset_sha": manifest["dataset_sha"],
    })
    mlflow.log_params({
        "base_model": args.model, "fine_tuned": True, "epochs": args.epochs, "iters": total_steps,
        "steps_per_epoch": steps_per_epoch, "learning_rate": args.lr, "lr_schedule": "cosine",
        "warmup_ratio": args.warmup_ratio, "batch_size": args.batch_size, "grad_accum": args.grad_accum,
        "effective_batch_size": args.batch_size * args.grad_accum, "num_layers": layers,
        "lora_rank": args.rank, "lora_alpha": args.alpha, "lora_scale": args.alpha / args.rank,
        "lora_dropout": args.dropout, "target_modules": ",".join(TARGET_MODULES),
        "max_seq_length": args.max_len, "mask_prompt": True, "seed": args.seed,
        "eval_every": args.eval_every, "patience": args.patience,
        "grad_checkpointing": args.grad_checkpointing, "trainable_params": trainable,
        "trainable_share": trainable / total_params,
        "dataset_sha": manifest["dataset_sha"], "dataset_train": len(train), "dataset_valid": len(valid),
        "dataset_test": manifest["sizes"]["test"], "dataset_manual": manifest["sizes"]["manual"],
        "truncated_train": cut_train, "truncated_valid": cut_valid,
        "torch_version": torch.__version__, "cuda_version": torch.version.cuda or "none",
        "gpu_name": torch.cuda.get_device_name(0) if device.type == "cuda" else "none",
        **{f"weight_{k}": w for k, w in evaluate_cuda.M.SCORE_WEIGHTS.items()},
    })
    try:
        import pandas as pd

        frame = pd.read_json(DATA / "train.jsonl", lines=True)
        mlflow.log_input(mlflow.data.from_pandas(frame, name="equipay-describe", digest=manifest["dataset_sha"]),
                         context="training")
    except Exception as e:  # le suivi du jeu est un plus, pas une condition
        print(f"(log_input ignoré : {e})")
    mlflow.log_artifact(str(DATA / "manifest.json"), "dataset")
    for script in ("train_cuda.py", "evaluate_cuda.py", "metrics.py", "schema.py"):
        mlflow.log_artifact(str(HERE / script), "code")

    history = {"train": [], "val": [], "lr": [], "best": None}
    epoch_results = []
    best = {"val_loss": float("inf"), "step": 0, "epoch": 0.0}
    bad_evals, step, stop = 0, 0, False
    rng = random.Random(args.seed)
    if device.type == "cuda":
        torch.cuda.reset_peak_memory_stats()
    start = time.perf_counter()
    window = {"loss": 0.0, "tokens": 0, "seen": 0, "time": time.perf_counter()}
    model.train()

    def run_validation() -> None:
        nonlocal bad_evals, stop
        v = validate(model, valid, args.eval_batch_size, tokenizer.pad_token_id, device)
        mlflow.log_metrics(v, step=step)
        history["val"].append((step, v["val_loss"]))
        print(f"  [{step}/{total_steps}] val_loss={v['val_loss']:.4f} acc={v['val_token_accuracy']:.3f}", flush=True)
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
        for batch in batches(train, args.batch_size, rng):
            with torch.autocast("cuda", dtype=torch.bfloat16, enabled=device.type == "cuda"):
                loss, n_tokens, _ = answer_loss(model, collate(batch, tokenizer.pad_token_id, device))
            (loss / args.grad_accum).backward()
            window["loss"] += float(loss.detach()) * n_tokens
            window["tokens"] += n_tokens
            window["seen"] += sum(len(ids) for ids, _ in batch)
            micro += 1
            if micro % args.grad_accum:
                continue
            grad_norm = float(torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0))
            optimizer.step()
            scheduler.step()
            optimizer.zero_grad(set_to_none=True)
            step += 1
            if step % 10 == 0 or step == total_steps:
                elapsed = time.perf_counter() - window["time"]
                lr = scheduler.get_last_lr()[0]
                train_loss = window["loss"] / max(window["tokens"], 1)
                logged = {"train_loss": train_loss, "learning_rate": lr, "grad_norm": grad_norm,
                          "train_tokens_per_s": window["seen"] / max(elapsed, 1e-9),
                          "epoch": step / steps_per_epoch}
                if device.type == "cuda":
                    logged["gpu_mem_gb"] = torch.cuda.max_memory_allocated() / 1e9
                mlflow.log_metrics(logged, step=step)
                history["train"].append((step, train_loss))
                history["lr"].append((step, lr))
                print(f"  [{step}/{total_steps}] loss={train_loss:.4f} lr={lr:.2e}", flush=True)
                window = {"loss": 0.0, "tokens": 0, "seen": 0, "time": time.perf_counter()}
            if step % args.eval_every == 0:
                run_validation()
            if step >= total_steps or stop:
                break
        # Fin d'epoch : validation + évaluation rapide en génération de l'adaptateur courant
        if not history["val"] or history["val"][-1][0] != step:
            run_validation()
        if args.epoch_eval_limit and not args.max_steps:
            quick, _, _ = evaluate_cuda.evaluate(model, tokenizer, evaluate_cuda.load_rows("valid", args.epoch_eval_limit),
                                                 args.eval_batch_size)
            quick["epoch"] = epoch
            epoch_results.append(quick)
            mlflow.log_metrics({f"epoch_eval_{k}": quick[k] for k in
                                ("score", "exact_match", "amount_accuracy", "participants_accuracy", "paid_by_accuracy",
                                 "date_accuracy", "split_accuracy", "invented_any_rate")}, step=epoch)
            print(f"  epoch {epoch} : score rapide = {quick['score']:.3f}", flush=True)
            model.train()

    train_time = time.perf_counter() - start
    summary = {"best_val_loss": best["val_loss"], "best_step": best["step"], "best_epoch": best["epoch"],
               "steps_done": step, "train_time_s": train_time, "stopped_early": float(stop)}
    if device.type == "cuda":
        summary["peak_gpu_mem_gb"] = torch.cuda.max_memory_allocated() / 1e9
    mlflow.log_metrics(summary)
    log_figure(curves_figure(history), "courbes.png", "training")
    if epoch_results:
        log_figure(epoch_figure(epoch_results), "score_par_epoch.png", "training")

    # Adaptateur du meilleur point : envoyé au Mac (contrat : artefact « adapter/ »)
    mlflow.log_artifacts(str(best_dir), "adapter")
    print(f"Meilleur point : étape {best['step']} (epoch {best['epoch']:.2f}), val_loss={best['val_loss']:.4f}",
          flush=True)

    # Évaluation complète du meilleur adaptateur, puis du modèle de base
    set_peft_model_state_dict(model, load_file(str(best_dir / "adapter_model.safetensors")))
    tuned = evaluate_cuda.full_evaluation(model, tokenizer, run_name, args.eval_batch_size,
                                          args.eval_limit, not args.no_baseline)
    mlflow.set_tag("status", "awaiting_mac_import")
    print(f"\n✓ Run {run.info.run_id} ({run_name}) — score GPU {tuned['score']:.3f}, "
          f"durée {train_time / 60:.0f} min", flush=True)


if __name__ == "__main__":
    main()
