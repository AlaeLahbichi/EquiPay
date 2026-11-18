# EquiPay — modèle « Décrire la dépense » : entraînement sur le PC (RTX 5080) et envoi vers MLflow

> **À lire par Claude Code sur le PC d'entraînement.** Ce dossier contient tout ce qu'il faut pour
> entraîner **un seul modèle**, l'évaluer complètement et l'envoyer au serveur MLflow du Mac.
> Explique à l'utilisateur, en français et simplement, ce que tu fais à chaque étape.

## 1. Contexte

EquiPay est une application mobile de partage de dépenses entre amis (projet étudiant à l'EMSI).
Pour ajouter une dépense, l'utilisateur a trois méthodes : la saisie manuelle, le scan du reçu
(déjà fait) et **« Décrire la dépense »**, que ce modèle rend possible.

L'utilisateur écrit **une phrase**, et le modèle renvoie un JSON qui **pré-remplit le formulaire**.
L'utilisateur vérifie, corrige, puis valide : le modèle ne crée jamais la dépense lui-même. Il y a
**une seule dépense par phrase**.

**Entrée** (message utilisateur, après un prompt système court) :
```
Aujourd'hui : 2026-10-11 (dimanche)
Devise de l'activité : MAD
Membres : Alae (moi), Sara, Yassine, Karim
Phrase : resto hier soir avec Sara et Yassine, 450 dh, j'ai payé
```
**Sortie attendue :**
```json
{"is_expense": true, "title": "Restaurant", "merchant": null, "amount": 450, "currency": "MAD",
 "date": "2026-10-10", "paid_by": "moi", "participants": ["moi", "Sara", "Yassine"], "split": null, "items": []}
```

**Règles apprises :**
- Les noms viennent uniquement de la liste des membres, et l'utilisateur s'appelle « moi ».
- « avec X » inclut moi. « tout le monde sauf X » donne la liste des membres sans X.
- Les dates relatives (hier, samedi dernier, le 3…) sont calculées à partir d'aujourd'hui.
- `split` vaut :
  - `null` quand rien n'est précisé ;
  - `equal` pour des parts égales dites explicitement ;
  - `percent`, `amounts` ou `shares` avec des `values`.
- `items` détaille les articles, avec le prix de chaque ligne.
- **Si le total n'est pas dit**, `amount` est la somme des articles ; s'il n'y a ni total ni
  articles, `amount` vaut 0.
- Toute autre information absente vaut `null` : le modèle ne doit **jamais deviner**.
- Une phrase qui n'est pas une dépense (« c'est quoi mon solde ? ») donne `is_expense: false`.

## 2. Contenu du dossier

| Élément | Rôle |
|---|---|
| `train_cuda.py` | Entraînement LoRA (boucle PyTorch) et évaluation complète, **dans un seul run MLflow** |
| `evaluate_cuda.py` | Évaluation (appelée par `train_cuda.py`, ou seule avec `--run-id`) |
| `metrics.py` | Métriques, **identiques à celles du Mac** : ne pas modifier |
| `schema.py` | Prompt système et format de l'entrée : ne pas modifier |
| `data/train.jsonl`, `data/valid.jsonl` | 12 000 et 500 dialogues au format chat (système, utilisateur, assistant) |
| `data/valid_meta.jsonl`, `data/test_meta.jsonl`, `data/manual_meta.jsonl` | Phrases, réponses attendues et contexte pour l'évaluation : 500 / 800 / 50 |
| `data/manifest.json` | Empreinte `dataset_sha` et statistiques |
| `source/` | Le générateur des données (`generate.py`, `build.py`), pour information |

## 3. Les données (générées sur le Mac)

- **13 350 phrases** synthétiques avec leur réponse exacte : 12 000 pour l'entraînement, 500 pour
  la validation et 800 pour le test.
- **4 styles** :
  - français (≈ 41 %) ;
  - SMS (≈ 20 %) : « resto 60e ac sara jai payé » ;
  - darija en lettres latines (≈ 20 %) : « khlest l3cha 600 dh m3a Sara » ;
  - anglais (≈ 18 %).
- **Variété** :
  - 15 catégories (resto, taxi, courses, hôtel…) et 12 devises écrites de toutes les façons
    (« 1 250,00 dh », « 45,50€ », « $20 ») ;
  - dates relatives, participants (avec, pour, tout le monde, sauf X, entre moi et X) ;
  - 4 types de répartition, articles détaillés, prénoms mal écrits ou en minuscules ;
  - environ 8 % de phrases qui ne sont pas des dépenses.
- **Le test utilise des formulations jamais vues** à l'entraînement : les dernières variantes de
  chaque modèle de phrase lui sont réservées.
- **Test manuel** : 50 phrases écrites à la main, hors du générateur. C'est le test le plus
  proche de la réalité.
- Longueur d'un exemple : environ 260 jetons (prompt système de 105 jetons, réponse d'environ
  80 jetons). Rien n'est tronqué à 640.

## 4. Étapes

### 4.1 Environnement
Réutilise l'environnement Python de l'assistant (`ml/pc`) s'il existe. Sinon :
```powershell
py -3.12 -m venv .venv
.venv\Scripts\activate
pip install torch --index-url https://download.pytorch.org/whl/cu128
pip install -r requirements.txt
```
Le modèle `Qwen/Qwen3-4B-Instruct-2507` est sans doute déjà dans le cache Hugging Face : c'est
celui de l'assistant.

### 4.2 Serveur MLflow du Mac
- **Adresse : `http://192.168.1.58:5000`.** Elle a changé : ce n'est plus `.23`.
- Test :
  `python -c "import mlflow; mlflow.set_tracking_uri('http://192.168.1.58:5000'); print(mlflow.get_experiment_by_name('Equipay-describe'))"`.
- Si ça échoue, **arrête-toi** et demande à l'utilisateur de vérifier le Mac : allumé, même Wi-Fi,
  `ml/mlflow_server.sh` lancé, IP inchangée. Si l'IP a encore changé, passe
  `--tracking-uri http://<IP>:5000` à toutes les commandes.

### 4.3 Essai éclair (obligatoire, environ 5 minutes)
```powershell
python train_cuda.py --max-steps 20 --eval-every 10 --eval-limit 24 --epoch-eval-limit 0 --experiment Equipay-describe-essai
```
- Vérifie que l'essai va au bout, puis que le run contient `adapter/`, `eval/`, `manual_eval/`,
  `base_eval/` et les métriques `eval_*` et `base_eval_*`.
- Ensuite, **mets l'expérimentation `Equipay-describe-essai` à la corbeille** et supprime
  `outputs/`.

### 4.4 Le vrai entraînement (un seul run)
```powershell
python train_cuda.py
```
- Le run s'appelle `cuda-lora-Qwen3-4B-2507-2ep-L36-r16`, dans l'expérimentation
  `Equipay-describe` (elle existe déjà ; elle contient un run arrêté sur le Mac, n'y touche pas).
- **Durée estimée** : environ 30 à 50 min d'entraînement (2 epochs, 1 500 étapes), puis environ
  15 à 20 min d'évaluation (850 phrases × 2 modèles). Les lignes `loss=…` permettent d'estimer la
  durée réelle : annonce-la à l'utilisateur.
- **Mémoire GPU insuffisante** : relance avec `--batch-size 4 --grad-accum 4` (même batch
  effectif de 16), puis ajoute `--grad-checkpointing` si nécessaire.
- La fin du run évalue le **meilleur adaptateur** et le **modèle de base** (adaptateur désactivé)
  sur les 800 phrases de test et les 50 phrases manuelles, puis pose le tag
  `status=awaiting_mac_import`.
- **N'inscris rien dans le registre** : le Mac s'en charge. Il fusionne l'adaptateur, le convertit
  en MLX 4 bits, l'évalue et l'inscrit dans `equipay-describe`.

### 4.5 Si le réseau tombe
- L'adaptateur du meilleur point reste dans `outputs/<nom du run>/adapter/`.
- Si seule l'évaluation a échoué, relance `python evaluate_cuda.py --run-id <RUN_ID>` quand le Mac
  est joignable.
- Sinon, explique la situation à l'utilisateur.

### 4.6 Résumé à donner à l'utilisateur
- `run_id`, durée, `best_val_loss`, `best_step`, `best_epoch`, arrêt anticipé ou non.
- Un tableau **base → affiné**, sur le test et sur le test manuel, avec : `score`, `exact_match`,
  `amount_accuracy`, `participants_f1`, `paid_by_accuracy`, `date_accuracy`, `split_accuracy`,
  `items_f1`, `non_expense_f1` et `invented_any_rate`.
- Le style le plus faible (`eval/par_style.json`).

## 5. Réglages

| Réglage | Valeur | Pourquoi |
|---|---|---|
| Modèle | `Qwen/Qwen3-4B-Instruct-2507`, bf16, poids gelés | Même base que l'assistant, tient dans 16 Go |
| LoRA | rang 16, alpha 32 (échelle 2), dropout 0,05, **les 36 couches**, modules `q,k,v,o,gate,up,down_proj` | Le maximum de finesse, choisi par l'utilisateur |
| Perte | uniquement sur la réponse JSON | Le modèle apprend à extraire, pas à recopier la phrase |
| Optimiseur | AdamW, lr 2e-4, préchauffage 3 %, décroissance cosinus | Classique pour un LoRA sur une tâche d'extraction |
| Batch | 8 × accumulation 2 = 16 effectif ; longueur max 640 | |
| Durée | **2 epochs** au maximum | Jeu grand et régulier : 2 passages suffisent |
| Validation | sur les 500 phrases, toutes les 150 étapes et à chaque fin d'epoch | |
| Meilleur point | perte de validation la plus basse ; **arrêt anticipé** après 4 validations sans progrès | |
| Éval par epoch | extraction réelle sur 120 phrases de validation | Courbe `epoch_eval_score` |
| Graine | 42 | Reproductible |

## 6. Métriques enregistrées

**Pendant l'entraînement** : `train_loss`, `learning_rate`, `grad_norm`, `train_tokens_per_s`,
`gpu_mem_gb`, `epoch`, `val_loss`, `val_perplexity` et `val_token_accuracy`. Le système (GPU, CPU,
mémoire) est enregistré automatiquement. Par epoch, `epoch_eval_*` ; en résumé, `best_val_loss`,
`best_step`, `best_epoch`, `stopped_early`, `train_time_s` et `peak_gpu_mem_gb`.

**Évaluation**, avec les préfixes `eval_` (test, affiné), `manual_eval_` (manuel, affiné),
`base_eval_` et `base_manual_eval_` (modèle de base), plus `eval_score_gain` et
`manual_eval_score_gain` :

| Métrique | Signification |
|---|---|
| `score` | Moyenne pondérée : dépense ou non 0,10, montant 0,20, participants 0,15, payeur 0,10, date 0,10, répartition 0,10, devise 0,05, titre 0,05, commerce 0,05, articles F1 0,05, JSON valide 0,05 |
| `exact_match` | Dépense entièrement juste (tous les champs) |
| `<champ>_accuracy` | Exactitude de title, merchant, amount, currency, date, paid_by, participants, split et items |
| `participants_precision` / `_recall` / `_f1` | Bonnes personnes incluses, sans oubli |
| `unknown_member_rate` | Noms inventés, hors de la liste (doit tendre vers 0) |
| `split_type_accuracy` | Bon type de répartition |
| `items_precision` / `_recall` / `_f1` | Articles (libellé proche et prix exact) |
| `is_expense_accuracy`, `non_expense_precision` / `_recall` / `_f1` | Reconnaître ce qui n'est pas une dépense |
| `invented_<champ>_rate`, `invented_any_rate` | Champ rempli alors qu'il n'est pas dans la phrase (doit tendre vers 0) |
| `json_valid_rate`, `latency_s`, `peak_gpu_mem_gb` | Qualité de format et vitesse |
| `<préfixe>style_<fr/sms/dj/en/manuel>_*`, `<préfixe>participants_<mode>_*`, `<préfixe>repartition_<type>_*` | Les mêmes indicateurs par style, par façon de citer les participants et par type de répartition |

**Artefacts** :
- `adapter/` (ce que le Mac importe) ;
- `training/` : `courbes.png` et `score_par_epoch.png` ;
- pour chaque évaluation, `metrics.json`, `par_style.json`, `par_kind.json`,
  `par_split_type.json`, `predictions.jsonl` (phrase par phrase) et les matrices de confusion
  `confusion_depense.png` (dépense ou non), `confusion_repartition.png` (type de répartition) et
  `confusion_champs.png` ;
- `eval/base_vs_affine.png`, `dataset/` et `code/`.

## 7. Règles
- Ne modifie ni `data/`, ni `metrics.py`, ni `schema.py`.
- Ne touche pas aux autres expérimentations (`Equipay`, `Equipay-receipts`…).
- **Un seul vrai run** dans `Equipay-describe`. En cas d'échec, laisse le run raté
  (`status=failed`) et relance.
- N'inscris rien dans le registre : c'est le rôle du Mac.
