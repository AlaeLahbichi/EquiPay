# EquiPay

Application de partage des dépenses entre amis. Elle comprend l'app mobile Flutter, une API Python
(FastAPI) qui sert trois modèles d'IA affinés, et une base Supabase.

## Arborescence
```
mobile/      Application Flutter (iOS + Android)
backend/     API FastAPI (port 8000) : assistant, scanner de reçus, « Décrire la dépense »
supabase/    Migrations SQL de la base (push.sh pour les appliquer)
ml/          Entraînement et suivi des modèles (MLflow)
  ├─ mlflow_server.sh   serveur MLflow (port 5000), base mlflow.db + mlartifacts/
  ├─ scripts/ pc/ data/ knowledge/ pipeline.sh   assistant (jeu de données, entraînement, évaluation)
  ├─ models/            modèle de l'assistant servi (champion v16, MLX)
  ├─ describe/          « Décrire la dépense » (jeu de données, entraînement PC, import sur le Mac)
  ├─ receipts/          scanner de reçus (jeu de données, paquet PC, conversion MLX : mac_mlx.py)
  └─ logs/
model/       Modèles livrés, autonomes (aucun modèle de base nécessaire)
  ├─ equipay-describe/          v1, MLX 4 bits
  └─ equipay-receipt-scanner/   v2, MLX 4 bits (servi) + PyTorch bf16 (en stock)
```

## Lancer en local
```bash
ml/mlflow_server.sh        # 1. MLflow (le backend y lit le champion de l'assistant)
backend/run.sh             # 2. API sur http://Alaes-MacBook-Pro.local:8000 (doc : /docs)
```
L'app appelle l'API à l'adresse `API_URL` de `mobile/env.json`. Ce fichier n'est pas versionné ;
son modèle est `env.example.json`.

```bash
cd mobile
flutter run --release --dart-define-from-file=env.json   # ou ./dev.sh (hot reload auto)
```
Il faut toujours passer `--dart-define-from-file=env.json`. Sans lui, l'app affiche « Configuration manquante ».

## Mobile sur iPhone (première fois)
1. Installer **Xcode**, puis `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch`
2. `brew install cocoapods`
3. iPhone : Réglages → Confidentialité et sécurité → **Mode développeur**
4. `open mobile/ios/Runner.xcworkspace` → *Runner* → *Signing & Capabilities* → choisir sa **Team**
5. Au 1er lancement : Réglages → Général → VPN et gestion de l'appareil → faire confiance au certificat

`mobile/build` est un lien vers `~/Developer/equipay_build`, car iCloud fait échouer la signature
s'il est sur le Bureau. Après un `flutter clean`, recréer le lien :
`ln -s ~/Developer/equipay_build mobile/build`.

## Tests
```bash
cd mobile && flutter test            # app
cd backend && .venv/bin/pytest -q    # API
```
