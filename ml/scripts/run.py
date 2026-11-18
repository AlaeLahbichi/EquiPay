"""Pipeline MLOps de l'assistant EquiPay (expérimentation MLflow « Equipay »).

  baseline  évalue un modèle importé tel quel             → run + version du modèle
  train     entraîne un adaptateur LoRA puis l'évalue     → run + version du modèle
  reeval    réévalue une version existante sur le jeu de test actuel → nouvelle version
  champion  donne l'alias « champion » à la meilleure version (score le plus haut),
            parmi les versions évaluées sur le jeu de données actuel uniquement

Exemples :
  python scripts/run.py baseline --model mlx-community/Qwen2.5-1.5B-Instruct-4bit
  python scripts/run.py train --model mlx-community/Qwen2.5-1.5B-Instruct-4bit --iters 300
  python scripts/run.py reeval --version 15
  python scripts/run.py champion
"""

import argparse
import math
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

import pandas as pd
import yaml

from common import (
    CLASS_LABELS, CLASSES, DATA, MODELS, REGISTERED_MODEL, ROOT, SCORE_WEIGHTS, Generator,
    confusion_matrix, dataset_info, evaluate, mlflow, per_category, per_topic, setup_mlflow,
    system_prompt,
)

MODEL_CODE = str(Path(__file__).with_name("assistant_model.py"))


def short_name(model: str) -> str:
    return model.split("/")[-1].replace("-Instruct", "").replace("-4bit", "")


def log_dataset() -> None:
    info = dataset_info()
    train = pd.read_json(DATA / "train.jsonl", lines=True)
    mlflow.log_input(
        mlflow.data.from_pandas(train, name="equipay-qa", digest=info["source_sha256"]),
        context="training",
    )
    mlflow.log_params({
        "dataset_sha": info["source_sha256"],
        "dataset_train": info["sizes"]["train"],
        "dataset_valid": info["sizes"]["valid"],
        "dataset_test": info["sizes"]["test"],
    })
    mlflow.log_artifact(str(DATA / "manifest.json"), "dataset")


def log_confusion_matrix(rows: list[dict], title: str) -> None:
    """Matrice de confusion du comportement : répondre / support / refuser."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    matrix = confusion_matrix(rows)
    labels = [CLASS_LABELS[c] for c in CLASSES]
    table = pd.DataFrame(matrix, index=[f"attendu : {l}" for l in labels],
                         columns=[f"prédit : {l}" for l in labels])
    mlflow.log_table(table.reset_index(names="classe"), "eval/confusion_matrix.json")

    fig, ax = plt.subplots(figsize=(6, 5))
    totals = [max(sum(r), 1) for r in matrix]
    ax.imshow([[v / t for v in r] for r, t in zip(matrix, totals)], cmap="Greens", vmin=0, vmax=1)
    for i, row in enumerate(matrix):
        for j, value in enumerate(row):
            share = value / totals[i]
            ax.text(j, i, f"{value}\n{share:.0%}", ha="center", va="center",
                    color="white" if share > 0.6 else "black", fontsize=11)
    ax.set_xticks(range(len(labels)), labels)
    ax.set_yticks(range(len(labels)), labels)
    ax.set_xlabel("Comportement du modèle (prédit)")
    ax.set_ylabel("Comportement attendu")
    ax.set_title(f"Matrice de confusion — {title}")
    fig.tight_layout()
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "confusion_matrix.png"
        fig.savefig(path, dpi=120)
        mlflow.log_artifact(str(path), "eval")
    plt.close(fig)


def evaluate_and_register(model: str, adapter: Path | None, stage: str, limit: int | None,
                          label: str | None = None) -> None:
    """Évalue le modèle et l'inscrit comme nouvelle version du registre.

    model : identifiant Hugging Face ou dossier local MLX (modèle importé du PC).
    label : nom affiché dans le registre (par défaut, model).
    """
    label = label or model
    local = Path(model).is_dir()
    print(f"Évaluation de {label}{' + LoRA' if adapter else ''}…", flush=True)
    generator = Generator(model, str(adapter) if adapter else None)
    metrics, rows = evaluate(generator, limit)
    mlflow.log_metrics({f"eval_{k}": v for k, v in metrics.items()})
    mlflow.log_table(pd.DataFrame(rows), "eval/predictions.json")
    mlflow.log_table(pd.DataFrame(per_topic(rows)), "eval/per_topic.json")
    categories = per_category(rows)
    mlflow.log_table(pd.DataFrame(categories), "eval/per_category.json")
    for c in categories:
        mlflow.log_metric(f"eval_cat_{c['category']}_routing_ok", c["routing_ok"])
        if c["semantic_similarity"] is not None:
            mlflow.log_metric(f"eval_cat_{c['category']}_semantic_similarity", c["semantic_similarity"])
    log_confusion_matrix(rows, f"{short_name(label)} ({stage})")

    info = mlflow.pyfunc.log_model(
        name="assistant",
        python_model=MODEL_CODE,
        artifacts={"adapter": str(adapter)} if adapter else None,
        model_config={
            "base_model": label, "system": system_prompt(), "max_tokens": 160,
            # Modèle importé du PC : dossier MLX local (non copié dans MLflow, plusieurs Go)
            **({"mlx_model_path": str(Path(model).resolve())} if local else {}),
        },
        pip_requirements=["mlx-lm", "mlflow", "pandas"],
        registered_model_name=REGISTERED_MODEL,
    )
    version = info.registered_model_version
    client = mlflow.MlflowClient()
    for key, value in {
        "stage": stage, "base_model": label, "score": f"{metrics['score']:.4f}",
        "run_name": mlflow.active_run().info.run_name,
        "dataset_sha": dataset_info()["source_sha256"],
    }.items():
        client.set_model_version_tag(REGISTERED_MODEL, version, key, value)
    client.update_model_version(
        REGISTERED_MODEL, version,
        description=f"{stage} — {mlflow.active_run().info.run_name} — score {metrics['score']:.3f}",
    )
    print(f"\n✓ {REGISTERED_MODEL} v{version} — " + ", ".join(f"{k}={v:.3f}" for k, v in metrics.items()))


def cmd_baseline(args) -> None:
    setup_mlflow()
    with mlflow.start_run(run_name=f"baseline-{short_name(args.model)}"):
        mlflow.set_tags({"stage": "baseline", "base_model": args.model})
        mlflow.log_params({"base_model": args.model, "fine_tuned": False,
                           **{f"weight_{k}": w for k, w in SCORE_WEIGHTS.items()}})
        log_dataset()
        evaluate_and_register(args.model, None, "baseline", args.limit)


def cmd_train(args) -> None:
    setup_mlflow()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    if args.epochs:
        args.iters = math.ceil(dataset_info()["sizes"]["train"] / args.batch_size * args.epochs)
    run_name = f"lora-{short_name(args.model)}-r{args.rank}-{args.iters}it"
    adapter = MODELS / f"{short_name(args.model)}-{stamp}"
    params = {
        "base_model": args.model, "fine_tuned": True, "iters": args.iters, "epochs": args.epochs,
        "learning_rate": args.lr, "batch_size": args.batch_size, "num_layers": args.layers,
        "lora_rank": args.rank, "lora_scale": args.scale, "mask_prompt": True, "seed": 42,
        **{f"weight_{k}": w for k, w in SCORE_WEIGHTS.items()},
    }
    with mlflow.start_run(run_name=run_name):
        mlflow.set_tags({"stage": "fine-tuned", "base_model": args.model})
        mlflow.log_params(params)
        log_dataset()

        config = {"lora_parameters": {"rank": args.rank, "scale": args.scale, "dropout": 0.05}}
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
            yaml.safe_dump(config, f)
        cmd = [
            sys.executable, "-m", "mlx_lm", "lora", "--config", f.name,
            "--model", args.model, "--train", "--data", str(DATA),
            "--iters", str(args.iters), "--batch-size", str(args.batch_size),
            "--num-layers", str(args.layers), "--learning-rate", str(args.lr),
            "--mask-prompt", "--steps-per-report", "10", "--steps-per-eval", "100",
            "--val-batches", "-1", "--seed", "42", "--adapter-path", str(adapter),
        ]
        print("Entraînement LoRA…", flush=True)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            print(line, end="", flush=True)
            plain = re.sub(r"\x1b\[[0-9;]*m", "", line)  # retire les couleurs du terminal
            # Lignes du tableau : « 50   val 1.295   0.35s » et « 50   1.649 ▼   515   3.9k »
            if m := re.match(r"\s*(\d+)\s+val\s+(\d+\.\d+)", plain):
                mlflow.log_metric("val_loss", float(m[2]), step=int(m[1]))
            elif m := re.match(r"\s*(\d+)\s+(\d+\.\d+)\s", plain):
                mlflow.log_metric("train_loss", float(m[2]), step=int(m[1]))
            if m := re.search(r"(?i)peak mem\w*\s*[:=]?\s*([\d.]+)\s*GB", plain):
                mlflow.log_metric("peak_mem_gb", float(m[1]))
        if proc.wait() != 0:
            mlflow.set_tag("status", "failed")
            raise SystemExit("L'entraînement a échoué")

        mlflow.log_artifacts(str(adapter), "adapter")
        evaluate_and_register(args.model, adapter, "fine-tuned", args.limit)


# Métriques affichées dans le rapport de comparaison (nom MLflow → libellé)
REPORT_METRICS = {
    "eval_score": "Score global",
    "eval_keyword_recall": "Infos clés",
    "eval_semantic_similarity": "Similarité de sens",
    "eval_rouge_l": "ROUGE-L",
    "eval_bleu": "BLEU",
    "eval_chrf": "chrF",
    "eval_routing_macro_f1": "Routage F1",
    "eval_routing_accuracy": "Routage exactitude",
    "eval_off_topic_refusal_rate": "Refus hors sujet",
    "eval_support_redirect_rate": "Redirection support",
    "eval_false_refusal_rate": "Refus à tort",
    "eval_perplexity": "Perplexité",
    "eval_latency_s": "Latence (s)",
    "eval_tokens_per_s": "Tokens/s",
    "eval_peak_memory_gb": "Mémoire (Go)",
}


def comparison_report(client, versions) -> pd.DataFrame:
    rows = []
    for v in versions:
        metrics = client.get_run(v.run_id).data.metrics
        rows.append({
            "version": f"v{v.version}",
            "modèle": short_name(v.tags.get("base_model", "?")),
            "run": client.get_run(v.run_id).info.run_name,
            "stage": v.tags.get("stage", ""),
            **{label: metrics.get(key) for key, label in REPORT_METRICS.items()},
        })
    return pd.DataFrame(rows).sort_values("Score global", ascending=False)


def comparison_chart(df: pd.DataFrame, path: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    labels = [f"{r['version']} {r['run']}" for _, r in df.iterrows()]
    quality = ["Score global", "Infos clés", "Similarité de sens", "ROUGE-L", "Routage F1",
               "Refus hors sujet", "Redirection support"]
    fig, axes = plt.subplots(1, 2, figsize=(16, 6), gridspec_kw={"width_ratios": [3, 1]})
    df[quality].set_axis(labels).plot.bar(ax=axes[0], width=0.8)
    axes[0].set_title("Qualité (plus haut = mieux)")
    axes[0].set_ylim(0, 1)
    axes[0].legend(loc="upper right", fontsize=8)
    axes[0].tick_params(axis="x", labelrotation=30, labelsize=8)
    df[["Latence (s)"]].set_axis(labels).plot.bar(ax=axes[1], color="#F97316", legend=False)
    axes[1].set_title("Latence moyenne (s, plus bas = mieux)")
    axes[1].tick_params(axis="x", labelrotation=30, labelsize=8)
    fig.tight_layout()
    fig.savefig(path, dpi=120)
    plt.close(fig)


def cmd_reeval(args) -> None:
    """Réévalue une version du registre sur le jeu de test actuel (comparaison équitable)."""
    setup_mlflow()
    uri = f"models:/{REGISTERED_MODEL}/{args.version}"
    flavor = mlflow.models.get_model_info(uri).flavors["python_function"]
    config = flavor.get("config") or flavor.get("model_config") or {}
    with tempfile.TemporaryDirectory(dir=MODELS) as tmp:
        local = Path(mlflow.artifacts.download_artifacts(uri, dst_path=tmp))
        adapter = local / "artifacts" / "adapter"
        model = config.get("mlx_model_path") or config["base_model"]
        with mlflow.start_run(run_name=f"reeval-v{args.version}-dataset-v{dataset_info().get('dataset_version', 1)}"):
            mlflow.set_tags({"stage": "reeval", "base_model": config["base_model"],
                             "reevaluated_version": args.version})
            mlflow.log_params({"base_model": config["base_model"], "reevaluated_version": args.version,
                               **{f"weight_{k}": w for k, w in SCORE_WEIGHTS.items()}})
            log_dataset()
            evaluate_and_register(model, adapter if adapter.is_dir() else None, "reeval", args.limit,
                                  label=config["base_model"])


def current_dataset_versions(client, versions):
    """Versions évaluées sur le jeu de données actuel : seuls leurs scores sont comparables."""
    sha = dataset_info()["source_sha256"]
    kept = [v for v in versions if client.get_run(v.run_id).data.params.get("dataset_sha") == sha]
    if len(kept) < len(versions):
        print(f"{len(versions) - len(kept)} version(s) ignorée(s) : évaluées sur un autre jeu de données")
    return kept


def cmd_champion(args) -> None:
    setup_mlflow()
    client = mlflow.MlflowClient()
    versions = current_dataset_versions(client, client.search_model_versions(f"name='{REGISTERED_MODEL}'"))
    if not versions:
        raise SystemExit("Aucune version évaluée sur le jeu de données actuel")
    df = comparison_report(client, versions)
    with pd.option_context("display.width", 200, "display.max_columns", 20, "display.precision", 3):
        print(df.to_string(index=False))

    best = df.iloc[0]
    best_version = best["version"][1:]
    client.set_registered_model_alias(REGISTERED_MODEL, "champion", best_version)

    # Run de synthèse : tableau + graphique comparatif de toutes les versions
    with mlflow.start_run(run_name="comparaison-modeles"):
        mlflow.set_tags({"stage": "comparaison", "champion": f"v{best_version}"})
        mlflow.log_param("versions_comparees", len(df))
        mlflow.log_param("champion", f"v{best_version} {best['modèle']} ({best['stage']})")
        mlflow.log_metric("champion_score", float(best["Score global"]))
        mlflow.log_table(df, "comparaison/tableau.json")
        with tempfile.TemporaryDirectory() as tmp:
            chart = Path(tmp) / "comparaison.png"
            comparison_chart(df, chart)
            mlflow.log_artifact(str(chart), "comparaison")
    print(f"\n🏆 champion = v{best_version} {best['modèle']} ({best['stage']}) — score {best['Score global']:.3f}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    b = sub.add_parser("baseline")
    b.add_argument("--model", required=True)
    b.add_argument("--limit", type=int, help="nombre de questions de test (debug)")
    b.set_defaults(func=cmd_baseline)

    t = sub.add_parser("train")
    t.add_argument("--model", required=True)
    t.add_argument("--iters", type=int, default=300)
    t.add_argument("--epochs", type=float, help="remplace --iters : nombre de passages sur le train")
    t.add_argument("--lr", type=float, default=1e-4)
    t.add_argument("--batch-size", type=int, default=4)
    t.add_argument("--layers", type=int, default=16)
    t.add_argument("--rank", type=int, default=8)
    t.add_argument("--scale", type=float, default=20.0)
    t.add_argument("--limit", type=int, help="nombre de questions de test (debug)")
    t.set_defaults(func=cmd_train)

    r = sub.add_parser("reeval")
    r.add_argument("--version", required=True, help="numéro de version du registre (ex. 15)")
    r.add_argument("--limit", type=int, help="nombre de questions de test (debug)")
    r.set_defaults(func=cmd_reeval)

    c = sub.add_parser("champion")
    c.set_defaults(func=cmd_champion)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
