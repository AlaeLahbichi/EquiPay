# EquiPay — scanner de reçus **v2** : entraînement sur le PC (RTX 5080) et envoi vers MLflow

> **À lire par Claude Code sur le PC d'entraînement.** Ce dossier remplace celui de la v1
> (`equipay_receipt_pc`). Il entraîne la version 2 du scanner de reçus, l'évalue en la comparant
> au modèle de base et à la v1, puis envoie tout au serveur MLflow du Mac. Explique à
> l'utilisateur, en français et simplement, ce que tu fais à chaque étape.

## 1. Pourquoi une v2

La v1 (`equipay-receipt` v1, run `cuda-lora-qwen3vl4b-4ep-r16-1024px`) a obtenu 97,9 % de totaux
justes sur son test. Mais elle n'a appris que sur CORD, c'est-à-dire des tickets indonésiens en
roupies, sans aucun centime : là-bas, le point et la virgule séparent toujours les milliers.

Elle a donc appris à **supprimer tous les points et virgules** et à répondre **toujours « IDR »** :
- « TOTAL 11,50 € » donne `amount: 1150, currency: "IDR"` ;
- « 125.50 DH » donne `12550, "IDR"`.

La v2 corrige ce défaut avec des tickets de plusieurs pays et un format de réponse enrichi.

## 2. Le jeu de données v2 (`data/prepared/`, empreinte `dataset_sha = de7bbf0d18b2`)

| Source | Entraînement | Validation | Test | Pays / devise | Champs annotés |
|---|---:|---:|---:|---|---|
| CORD v2 | 779 | 98 | 95 | Indonésie, IDR (milliers « 75.000 ») | total, devise, articles |
| SROIE (ICDAR 2019) | 565 | 60 | 120 | Malaisie, MYR (« 9.00 ») | enseigne, adresse, date, total, devise |
| WildReceipt | 894 | 100 | 150 | International (USD, GBP, EUR, « 12,00 ») | enseigne, adresse, date*, total, devise*, articles |
| Synthétiques | 2 400 | 120 | 250 | France (EUR), Maroc (MAD), USA, Royaume-Uni, Suisse | tous |
| **Total** | **4 638** | **378** | **615** | 7 devises | |

\* seulement quand c'est certain : une date ambiguë comme 05/06/18 et une devise sans symbole
ne sont pas annotées.

- **Les tickets synthétiques** ont été générés sur le Mac : vraies polices de caisse, centimes
  avec virgule (France) ou point (Maroc, USA), milliers « 1 250,00 », « 1.250,50 », « 1,250.00 »,
  symboles €, DH, $, £, CHF, et pièges (sous-total, TVA, espèces, monnaie rendue). Les images
  sont abîmées pour ressembler à des photos : rotation, ombre, flou, bruit.
- **Format de chaque ligne JSONL** : `image`, `source`, `target` (la réponse complète attendue),
  `fields` (les champs **réellement annotés** dans cette source), `other_amounts` et `currency`.
- **Nouvelle réponse attendue :**
  ```json
  {"merchant": "CAFE DE LA GARE", "address": "12 rue de Lyon, 75012 Paris", "date": "2026-10-10",
   "amount_text": "11,50 €", "amount": 11.5, "currency": "EUR",
   "items": [{"label": "Cafe creme", "qty": 2, "price": 7.0}]}
  ```
  `amount_text` est le total **recopié tel qu'il est imprimé**. Le modèle apprend ainsi à lire les
  séparateurs avant de convertir le montant.
- **Champs non annotés** : s'ils sont absents de la source (par exemple la date dans CORD), ils
  sont écrits `null` mais **exclus de la perte** (masquage au niveau des jetons, dans
  `receipt_data.py`). Le modèle n'apprend donc pas à les laisser vides. Les métriques ne les
  notent pas non plus.

## 3. Contenu du dossier

| Élément | Rôle |
|---|---|
| `train_cuda.py` | Entraînement LoRA, validation, évaluation complète et registre MLflow, **en un seul run** |
| `evaluate_cuda.py` | Évaluation comparée v2 / base / v1 (appelée par `train_cuda.py`, ou seule avec `--run-id`) |
| `receipt_metrics.py` | Métriques v2 : **ne pas modifier** |
| `receipt_data.py` | Prompt v2 (et v1), sérialisation de la réponse, masquage de la perte |
| `api.py` | Page web pour tester le modèle à la main |
| `data/prepared/` | `train.jsonl`, `validation.jsonl`, `test.jsonl`, `images/`, `manifest.json` : **à utiliser tels quels** |

## 4. Étapes

### 4.1 Environnement
Réutilise l'environnement de la v1 s'il existe encore : mêmes dépendances. Sinon :
```powershell
py -3.12 -m venv .venv
.venv\Scripts\activate
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
pip install -r requirements.txt
```
Le modèle `Qwen/Qwen3-VL-4B-Instruct` est déjà dans le cache Hugging Face si la v1 a tourné sur
ce PC.

### 4.2 Serveur MLflow du Mac
`http://192.168.1.23:5000`. Teste avec
`python -c "import mlflow; mlflow.set_tracking_uri('http://192.168.1.23:5000'); print(mlflow.MlflowClient().get_model_version('equipay-receipt','1').source)"`.
Si ça échoue, **arrête-toi** et demande à l'utilisateur de vérifier le Mac : allumé, même Wi-Fi,
serveur lancé, IP inchangée. Si l'IP a changé, ajoute `--tracking-uri http://<IP>:5000`.

### 4.3 Essai éclair (obligatoire, environ 5 minutes)
```powershell
python train_cuda.py --max-steps 10 --eval-limit 16 --epoch-eval-limit 0 --no-baseline --experiment Equipay-receipts-essai-v2
```
- Vérifie que l'essai va jusqu'au bout, que la mémoire (`mém=… Go`) reste sous 15 Go, et que le
  run contient `adapter/`, `eval/` et les métriques `eval_*`, `eval_src_*` et `eval_cur_*`.
- La ligne « Évaluation de la v1 » doit apparaître : la v1 est téléchargée depuis le registre
  du Mac.
- Ensuite, mets l'expérimentation `Equipay-receipts-essai-v2` à la corbeille et supprime
  `outputs/`.

### 4.4 Le vrai entraînement (un seul run)
```powershell
python train_cuda.py
```
- Le run s'appelle `cuda-lora-qwen3vl4b-v2-2ep-r16-1024px`, dans l'expérimentation
  `Equipay-receipts`.
- **Durée estimée** : environ 1 h 30 d'entraînement (2 epochs, ≈ 1 160 étapes), puis environ
  45 min d'évaluation (615 tickets × 3 modèles). Annonce l'estimation réelle (`reste≈… min`)
  à l'utilisateur.
- **Mémoire insuffisante** : relance d'abord avec `--batch-size 1 --grad-accum 8`, puis
  `--max-side 896` si nécessaire.
- La fin du run :
  1. évalue sur les 615 tickets de test le modèle **v2**, le modèle **de base** et la **v1**
     (avec son propre prompt) ;
  2. inscrit la v2 dans le registre `equipay-receipt` ;
  3. lui donne l'alias `champion` **seulement si elle bat la v1** sur ce test.

### 4.5 Si le réseau tombe
L'adaptateur du meilleur point reste dans `outputs/<nom du run>/adapter/`. Si seule l'évaluation
a échoué, relance `python evaluate_cuda.py --run-id <RUN_ID>` quand le Mac est joignable.
Sinon, explique la situation à l'utilisateur.

### 4.6 Test manuel (page web)
Lance `python api.py`, puis ouvre `http://localhost:8100`. Teste au moins :
- un ticket synthétique en euros (`data/prepared/images/synth-test-*.jpg`, à vérifier dans
  `test.jsonl`) ;
- un ticket SROIE ;
- un ticket CORD.

Le total en euros doit garder ses centimes. `python api.py --base` lance le modèle non entraîné.

### 4.7 Résumé à donner à l'utilisateur
- `run_id`, durée, `best_val_loss` et `best_epoch`, arrêt anticipé ou non.
- **Le tableau v1 / base / v2** (dans `eval/comparaison.json`) pour : `score`, `amount_accuracy`,
  **`amount_accuracy_decimals`** (totaux avec centimes : le bug de la v1), `currency_accuracy`,
  `date_accuracy`, `merchant_accuracy`, `items_f1`, `ticket_exact_match` et
  **`total_virgule_ignoree_rate`**.
- Le total juste **par devise** (`eval/par_devise.json`), surtout pour EUR et MAD.
- La version du registre, et si elle est devenue champion ou non.
- Le chemin local de l'adaptateur.

## 5. Réglages

| Réglage | Valeur |
|---|---|
| Modèle | `Qwen/Qwen3-VL-4B-Instruct`, bf16, LoRA rang 16 / alpha 32 sur les 36 couches du modèle de langage (la vision reste gelée) |
| Perte | uniquement sur les **champs annotés** de la réponse |
| Images | 1 024 px au plus grand côté ; séquence la plus longue ≈ 1 400 jetons (longueur max 2 048) |
| Optimiseur | AdamW, lr 1e-4, préchauffage 5 %, décroissance cosinus |
| Batch | 2 × accumulation 4 = 8 effectif (la v1 tenait en 12 Go avec ces réglages) |
| Durée | **2 epochs** (4 638 tickets, 5 fois plus que la v1), arrêt anticipé après 3 validations sans progrès |
| Validation | sur les 378 tickets, 2 fois par epoch ; meilleur adaptateur = perte de validation la plus basse |
| Éval par epoch | extraction réelle sur 80 tickets de validation (20 par source) |
| Graine | 42 |

## 6. Métriques enregistrées

Les métriques par étape sont les mêmes qu'en v1 (`train_loss`, `val_loss`,
`val_token_accuracy`…). S'y ajoutent `train_masked_tokens` et `train_misaligned_examples` : ce
dernier doit valoir 0.

Préfixes de l'évaluation finale :
- `eval_` : v2 ;
- `base_eval_` : modèle de base ;
- `v1_eval_` : v1.

Les gains sont dans `eval_score_gain_vs_base`, `eval_score_gain_vs_v1` et
`eval_amount_accuracy_gain_vs_v1`.

| Métrique | Signification |
|---|---|
| `score` | Moyenne pondérée : total 0,35, articles F1 0,15, devise 0,10, date 0,10, enseigne 0,10, total texte 0,05, adresse 0,05, JSON valide 0,10 (poids renormalisés sur les champs annotés) |
| `amount_accuracy` | Total exact (accuracy) |
| **`amount_accuracy_decimals`** / `amount_accuracy_integers` | Total exact sur les tickets **avec centimes** / sans centimes |
| `amount_text_accuracy` | Total recopié exactement comme imprimé |
| `currency_accuracy`, `date_accuracy`, `merchant_accuracy` (≥ 80 % de similarité), `address_accuracy` (≥ 70 %) | Exactitude de chaque champ, sur les tickets où il est annoté (`*_tickets` donne le nombre) |
| `items_precision` / `items_recall` / `items_f1`, `items_f1_macro`, `item_price_*`, `item_label_*` | Articles (prix exact et libellé ≥ 80 % proche) |
| `hallucinated_item_rate` / `missed_item_rate` | Articles inventés / oubliés |
| `ticket_exact_match` | Tous les champs annotés sont justes |
| `total_<nature>_rate` | Nature des erreurs sur le total : **virgule ignorée** (× 10, × 100, × 1 000), décimales en trop, sous-total, espèces, monnaie rendue, carte, taxe, prix d'un article, autre, absent |
| `<préfixe>src_<source>_*` / `<préfixe>cur_<devise>_*` | Les principales métriques **par source** et **par devise** |
| `latency_s`, `tokens_per_s`, `peak_gpu_mem_gb` | Vitesse |

Les artefacts sont rangés dans `eval/`, `base_eval/` et `v1_eval/`. Chacun contient :
- `metrics.json`, `par_source.json`, `par_devise.json` et `predictions.jsonl` ;
- `confusion_articles.png`, `confusion_champs.png`, **`confusion_devises.png`** (matrice réel ×
  prédit) et `erreurs_total.png`.

`eval/` contient en plus `comparaison.png` et `comparaison.json`. Le run garde aussi `training/`,
`adapter/`, `dataset/` et `code/`.

## 7. Règles
- Ne modifie ni `data/` ni `receipt_metrics.py`.
- Ne touche pas aux expérimentations `Equipay` (assistant) et ne supprime pas la v1 du registre.
- Un seul vrai run dans `Equipay-receipts`. En cas d'échec, laisse le run raté
  (`status=failed`) et relance.
- N'intègre rien dans l'application mobile.
