# EquiPay — entraînement de l'assistant v2 sur le PC (RTX 5080) et envoi vers MLflow

> **À lire par Claude Code sur le PC d'entraînement.** Ce dossier contient tout ce qu'il faut
> pour entraîner **un seul modèle** sur le nouveau jeu de données, l'évaluer complètement et
> l'envoyer au serveur MLflow du Mac. Explique à l'utilisateur, en français et simplement, ce
> que tu fais à chaque étape.

## 1. Contexte

EquiPay est une application mobile de partage de dépenses entre amis (projet étudiant à
l'EMSI, par Alae Lahbichi). Son assistant est un petit modèle de langage affiné avec LoRA pour
répondre en français aux questions des utilisateurs.

- **Version actuelle (champion v15)** : `Qwen/Qwen3-4B-Instruct-2507`, LoRA sur les 36 couches,
  2 epochs, entraîné sur ce PC. Score 0,822 sur l'ancien jeu de test.
  Point faible : il **invente des fonctionnalités** au lieu de rediriger vers le support
  (redirection support réussie dans seulement 56 % des cas).
- **Cette fois** : on garde le meilleur modèle (Qwen3-4B-Instruct-2507, toutes les couches),
  avec un **jeu de données 4 fois plus grand** et **plus d'epochs** (4, avec arrêt anticipé).
  Il n'y a qu'**un seul run**, qui contient l'entraînement, l'évaluation complète et la
  comparaison avec le modèle de base.

Répartition des rôles :
- **Le PC (toi)** entraîne, évalue sur GPU et envoie tout à MLflow.
- **Le Mac** importe ensuite l'adaptateur : il le fusionne, le convertit en MLX 4 bits, fait
  l'évaluation finale dans les conditions réelles d'utilisation et l'inscrit dans le registre.

## 2. Contenu du dossier

| Élément | Rôle |
|---|---|
| `train_cuda.py` | Entraînement LoRA (boucle PyTorch explicite) + évaluation finale dans le même run |
| `evaluate_cuda.py` | Évaluation complète (appelée par `train_cuda.py`, ou seule avec `--run-id`) |
| `metrics.py` | Métriques **identiques à celles du Mac** (même fichier) : ne pas modifier |
| `requirements.txt` | Dépendances Python (PyTorch CUDA s'installe à part) |
| `data/processed/` | `train.jsonl`, `valid.jsonl`, `test.jsonl`, `eval.jsonl`, `manifest.json` : **à utiliser tels quels** |
| `data/source/` | Source lisible du jeu : `qa.yaml`, `topics/*.yaml`, `support.yaml`, `off_topic.yaml` (référence) |
| `knowledge/equipay.md` | Base de connaissances de l'application (contexte) |

## 3. Le jeu de données v2

Empreinte : `dataset_sha = 753f2597d0c7` (dans `manifest.json`), version 2.

### Trois comportements à apprendre
1. **Répondre** (`in_scope`) aux questions sur l'application, sur le partage des dépenses et
   sur les applications similaires (Tricount, Splitwise…).
2. **Rediriger vers le support** (`support`) quand la question porte sur EquiPay mais que la
   réponse n'est pas connue (fonction qui n'existe pas, incident, tarif…). C'est le point faible
   de v15, d'où 161 questions de ce type au lieu de 48.
3. **Refuser poliment** (`off_topic`) ce qui n'a aucun rapport, y compris les tentatives de
   détourner l'assistant (« ignore tes instructions… »).

### Statistiques

| Catégorie | Sujets | Questions source | Questions de test |
|---|---:|---:|---:|
| app (présentation, navigation, préférences) | 16 | 223 | 48 |
| compte (connexion, profil, suppression…) | 20 | 245 | 60 |
| activites (création, devise, rôles, gestion des participants) | 25 | 278 | 75 |
| rejoindre (code, demandes, onglet Requests) | 18 | 196 | 54 |
| depenses (règles des dépenses) | 14 | 152 | 42 |
| soldes (calculs, remboursements) | 10 | 103 | 30 |
| fiabilite (hors ligne, sécurité, confidentialité) | 9 | 88 | 27 |
| assistant (qui es-tu, politesse, langues) | 11 | 131 | 33 |
| theme (partager des frais : coloc, voyage, resto…) | 27 | 231 | 81 |
| concurrents (Tricount, Splitwise, Settle Up…) | 15 | 141 | 45 |
| environnement (technologies, modèle, projet) | 11 | 105 | 33 |
| situations (dépannage, cas pratiques) | 20 | 163 | 60 |
| support (rediriger) | — | 161 | 61 |
| off_topic (refuser) | — | 206 | 78 |
| **Total** | **196** | **2 423** | **727** |

- **Découpage sans fuite** : pour chaque sujet, 3 formulations vont au test et 2 à la
  validation. Le test ne contient que des formulations jamais vues à l'entraînement.
- **Augmentation** (entraînement seulement) : chaque formulation est déclinée en minuscules,
  sans accents, avec des formules de politesse, des fautes de frappe, des abréviations SMS
  (« cmt », « pk », « bcp ») et des petits mots de fin (« stp », « 3afak », « please »).
- **Langues** : les questions sont en français, avec aussi de l'anglais et de la darija ;
  les réponses sont **toujours en français**.
- **Tailles** : 10 921 exemples d'entraînement, 438 de validation et 727 de test (v1 : 2 578 / 144 / 237).
- **Format** : chat `{"messages": [{"role":"system"}, {"role":"user"}, {"role":"assistant"}]}`.
  Vérifié avec le tokenizer de Qwen3-4B-Instruct-2507 : le prompt est toujours un préfixe exact
  du dialogue complet (masquage correct). Longueur moyenne 190 tokens, maximum 246, donc rien
  n'est tronqué à 512.

## 4. Étapes

### 4.1 Environnement (Windows, Python 3.12)
```powershell
py -3.12 -m venv .venv
.venv\Scripts\activate
pip install torch --index-url https://download.pytorch.org/whl/cu128
pip install -r requirements.txt
```
- La RTX 5080 (architecture Blackwell) exige **PyTorch compilé pour CUDA 12.8 ou plus**.
  Vérifie avec `nvidia-smi` puis
  `python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"`.
- Si l'environnement de l'entraînement v15 existe encore sur ce PC, tu peux le réutiliser.
  Vérifie seulement que `transformers`, `peft`, `sacrebleu`, `sentence-transformers`,
  `matplotlib`, `psutil` et `nvidia-ml-py` sont installés.
- Pas de bitsandbytes : on entraîne en bf16.

### 4.2 Connexion au serveur MLflow du Mac
- URL : `http://192.168.1.23:5000`. Le Mac doit être allumé, sur le même Wi-Fi, avec
  `ml/mlflow_server.sh` lancé.
- Test : `python -c "import mlflow; mlflow.set_tracking_uri('http://192.168.1.23:5000'); print(mlflow.get_experiment_by_name('Equipay'))"`
  doit afficher l'expérimentation. Si ça échoue, **arrête-toi** et demande à l'utilisateur de
  vérifier le Mac (allumé, même réseau, serveur MLflow lancé, adresse IP du Mac inchangée).
- Si l'IP du Mac a changé, passe la nouvelle adresse avec `--tracking-uri http://<IP>:5000`.

### 4.3 Essai éclair (obligatoire, environ 5 minutes)
Valide toute la chaîne dans une expérimentation de test :
```powershell
python train_cuda.py --max-steps 20 --eval-every 10 --eval-limit 24 --epoch-eval-limit 0 --experiment Equipay-test-pc
```
Vérifie dans MLflow que le run de test contient l'artefact `adapter/`, les métriques
`gpu_eval_*` et `gpu_base_eval_*`, et le tag `status=awaiting_mac_eval`. Ensuite, **mets
l'expérimentation `Equipay-test-pc` à la corbeille** (`mlflow.delete_experiment`), pour que le
Mac ne l'importe jamais.

### 4.4 Le vrai entraînement (un seul run)
```powershell
python train_cuda.py
```
Les valeurs par défaut sont les bons réglages (voir § 5). Le run s'appelle
`cuda-lora-Qwen3-4B-2507-4ep-L36-r16-v2`, dans l'expérimentation `Equipay`.

- **Mémoire GPU insuffisante (CUDA out of memory)** : relance avec `--grad-checkpointing`.
  Si ça ne suffit pas, ajoute `--batch-size 2 --grad-accum 4` : le batch effectif reste 8, les
  résultats restent donc comparables.
- **Durée** : environ 5 400 étapes au maximum (4 epochs × 1 366). L'arrêt anticipé stoppe plus
  tôt si la validation ne progresse plus. Compte une à quelques heures selon la vitesse
  mesurée. Les premières lignes `train_tokens_per_s` permettent d'estimer la durée :
  annonce-la à l'utilisateur.
- À chaque fin d'epoch, une évaluation rapide sur 120 questions trace la courbe
  `epoch_eval_score`.
- À la fin, l'évaluation complète porte sur les 727 questions : d'abord le modèle affiné, puis
  le modèle de base. Compte environ 15 minutes.

### 4.5 Si le réseau tombe pendant l'entraînement
L'adaptateur du meilleur point est toujours sauvegardé en local dans
`outputs/<nom du run>/adapter/`.
- **L'entraînement est fini et l'artefact `adapter/` est arrivé dans MLflow, mais
  l'évaluation a échoué** : relance seulement l'évaluation quand le Mac est joignable, avec
  `python evaluate_cuda.py --run-id <RUN_ID>`, puis pose le tag `status=awaiting_mac_eval` sur
  ce run.
- **Sinon** : ne relance pas tout de suite. Dis à l'utilisateur de copier
  `outputs/<nom du run>/` sur le Mac et explique-lui ce qui s'est passé.

### 4.6 Résumé à donner à l'utilisateur
Pour le run final, donne : `run_id`, durée, `best_val_loss`, `best_step` et `best_epoch`,
arrêt anticipé ou non, `gpu_eval_score` et `gpu_base_eval_score` avec le gain, et les valeurs
de `gpu_eval_support_redirect_rate`, `gpu_eval_hallucination_rate`,
`gpu_eval_off_topic_refusal_rate` et `gpu_eval_false_refusal_rate`. Termine par les deux
catégories les plus faibles (tableau `gpu_eval/per_category.json`).

## 5. Réglages d'entraînement

| Réglage | Valeur | Pourquoi |
|---|---|---|
| Modèle | `Qwen/Qwen3-4B-Instruct-2507` | Meilleur modèle de la v1 (base du champion v15) |
| Précision | bf16, poids de base gelés | Tient dans 16 Go sans quantification |
| LoRA | rang 16, alpha 320 (échelle 20), dropout 0,05 | Même échelle que v15, rang doublé pour un jeu 4 fois plus grand |
| Couches | les 36 (toutes) ; modules `q,k,v,o,gate,up,down_proj` | Configuration de v15 (meilleure que 16 couches) |
| Perte | uniquement sur la réponse de l'assistant | Le modèle apprend à répondre, pas à recopier la question |
| Optimiseur | AdamW, lr 1e-4, préchauffage 3 %, décroissance cosinus | Stable sur plusieurs epochs |
| Batch | 4 × accumulation 2 = 8 effectif ; longueur max 512 | |
| Durée | 4 epochs au maximum | Plus que v15 (2) |
| Validation | sur les 438 exemples, toutes les 200 étapes et à chaque fin d'epoch | |
| Meilleur point | adaptateur à la **perte de validation la plus basse** | C'est celui qui est envoyé et évalué |
| Arrêt anticipé | 5 validations sans progrès | Évite le surapprentissage |
| Graine | 42 | Reproductible |

## 6. Contrat MLflow (le Mac en dépend : ne change pas les noms)

- **Expérimentation** : `Equipay` (existe déjà ; ne la renomme pas, ne supprime rien dedans).
- **Tags** : `stage=fine-tuned-cuda`, `base_model=Qwen/Qwen3-4B-Instruct-2507`,
  `hardware=<nom du GPU>`, `dataset_version=2`, `status` (`training` → `awaiting_mac_eval`,
  ou `failed` en cas d'erreur).
- **Paramètres** : modèle, réglages LoRA et optimiseur, `dataset_sha`, tailles du jeu, versions
  de torch et CUDA, nom du GPU, nombre de paramètres entraînables, poids du score global.
- **Artefacts** :
  - `adapter/` : l'adaptateur PEFT du meilleur point (c'est ce que le Mac importe)
  - `dataset/manifest.json`
  - `code/` : les 3 scripts
  - `training/courbes.png` (pertes et learning rate) et `training/score_par_epoch.png`
  - `gpu_eval/` et `gpu_base_eval/` : prédictions, tableaux par sujet et par catégorie,
    matrice de confusion, graphique par catégorie
  - `gpu_eval/base_vs_affine.png` : le gain de l'entraînement
- **N'inscris rien dans le registre de modèles** : le Mac s'en charge après sa propre évaluation.

## 7. Les métriques enregistrées

**Pendant l'entraînement** (axe = étape) : `train_loss`, `learning_rate`, `grad_norm`,
`train_tokens_per_s`, `gpu_mem_gb`, `epoch`, `val_loss`, `val_perplexity` et
`val_token_accuracy` (part des mots de la réponse correctement prédits). Les métriques
système (GPU, CPU, mémoire) sont enregistrées automatiquement.

**À chaque epoch** (axe = epoch) : `epoch_eval_score`, `epoch_eval_keyword_recall`,
`epoch_eval_semantic_similarity`, `epoch_eval_rouge_l`, `epoch_eval_routing_macro_f1`,
`epoch_eval_hallucination_rate` et `epoch_eval_false_refusal_rate`.

**Résumé** : `best_val_loss`, `best_step`, `best_epoch`, `steps_done`, `stopped_early`,
`train_time_s` et `peak_gpu_mem_gb`.

**Évaluation finale** : préfixe `gpu_eval_` pour le modèle affiné et `gpu_base_eval_` pour le
modèle de base, plus `gpu_eval_score_gain`.

| Métrique | Signification | Idéal |
|---|---|---|
| `score` | Score global = 0,30 × infos clés + 0,25 × sens + 0,15 × ROUGE-L + 0,30 × routage F1 | haut |
| `keyword_recall` / `keyword_full_recall` | Part des mots-clés attendus présents / réponses avec tous les mots-clés | haut |
| `semantic_similarity` (+ `_p10`) | Proximité de sens avec la réponse de référence (moyenne / 10 % les plus faibles) | haut |
| `rouge_1`, `rouge_2`, `rouge_l`, `bleu`, `chrf`, `exact_match` | Proximité de formulation | haut |
| `perplexity` | Surprise du modèle devant la réponse de référence | bas |
| `routing_accuracy`, `routing_macro_f1`, `*_precision`, `*_recall`, `*_f1` | Bon comportement : répondre / support / refuser | haut |
| `support_redirect_rate` | Questions support correctement redirigées | haut |
| `hallucination_rate` | Questions support auxquelles le modèle **invente** une réponse | **bas** |
| `off_topic_refusal_rate` / `off_topic_answered_rate` | Hors sujet refusé / répondu quand même | haut / bas |
| `false_refusal_rate` / `false_support_rate` | Vraie question refusée / renvoyée au support à tort | bas |
| `length_ratio`, `answer_words`, `answer_tokens`, `empty_answer_rate` | Longueur des réponses | proche de 1 / — / — / 0 |
| `latency_s`, `latency_p95_s`, `tokens_per_s`, `peak_gpu_mem_gb` | Vitesse sur GPU (temps amorti par lot, pas comparable au Mac) | — |
| `cat_<catégorie>_*` | Les mêmes indicateurs pour chaque catégorie | — |

## 8. Règles
- Ne modifie ni `data/` ni `metrics.py` : sinon les scores ne seraient plus comparables.
- Ne supprime rien dans l'expérimentation `Equipay` (seule `Equipay-test-pc` va à la corbeille).
- Un seul vrai run dans `Equipay`. Si tu dois le relancer après une erreur, laisse le run
  raté avec son tag `status=failed` : le Mac ignore ce statut.

## 9. Après le PC (sur le Mac, pour information)
1. `python scripts/import_from_pc.py` : fusion, conversion MLX 4 bits, évaluation sur les 727
   questions (métriques `eval_*`), inscription dans `equipay-assistant`.
2. `python scripts/run.py reeval --version 15` : réévalue l'ancien champion sur le nouveau test,
   pour une comparaison équitable.
3. `python scripts/run.py champion` : choisit le meilleur parmi les versions évaluées sur ce
   jeu de données.
