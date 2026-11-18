"""Discuter avec l'assistant EquiPay dans le terminal, chargé depuis le registre MLflow.

  python scripts/chat.py              → la version « champion »
  python scripts/chat.py --version 5  → une version précise (pour comparer)
"""

import argparse

from common import REGISTERED_MODEL, mlflow, setup_mlflow, system_prompt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", help="numéro de version (par défaut : champion)")
    args = parser.parse_args()

    setup_mlflow()
    client = mlflow.MlflowClient()
    if args.version:
        uri, version = f"models:/{REGISTERED_MODEL}/{args.version}", client.get_model_version(
            REGISTERED_MODEL, args.version
        )
    else:
        uri = f"models:/{REGISTERED_MODEL}@champion"
        version = client.get_model_version_by_alias(REGISTERED_MODEL, "champion")

    print(f"Chargement de {REGISTERED_MODEL} v{version.version} "
          f"({version.tags.get('stage')}, {version.tags.get('base_model')}, "
          f"score {version.tags.get('score')})…")
    # Prompt système de l'entraînement (les premières versions ont un marqueur non remplacé)
    model = mlflow.pyfunc.load_model(uri, model_config={"system": system_prompt()})
    print("Pose ta question (vide ou Ctrl+C pour quitter).\n")
    while True:
        try:
            question = input("Toi       › ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not question:
            break
        print(f"Assistant › {model.predict([question])[0]}\n")


if __name__ == "__main__":
    main()
