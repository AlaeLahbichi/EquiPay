# Mission : entraîner l'assistant EquiPay sur ce PC (RTX 5080) et l'envoyer au Mac via MLflow

## Contexte
EquiPay est une application mobile de partage de dépenses (projet étudiant EMSI). Son assistant
est un petit modèle de langage affiné (LoRA) pour répondre aux questions des utilisateurs, en
français. Jusqu'ici, l'entraînement se faisait sur un Mac M3 Pro avec MLX, ce qui est lent.
Ce PC (RTX 5080, 16 Go) sert désormais **uniquement à l'entraînement**. L'évaluation, la
conversion en MLX et le service du modèle restent sur le Mac, qui s'en charge à partir de ce
que tu envoies.

Le suivi MLOps se fait dans **MLflow**, sur un serveur hébergé par le Mac :
- URL : `http://192.168.1.23:5000` (le Mac doit être allumé, avec `ml/mlflow_server.sh` lancé)
- Expérimentation : **`Equipay`** (elle existe déjà ; ne la renomme pas et n'en crée pas d'autre)
- Les fichiers que tu enregistres (`log_artifact`) sont envoyés au Mac par le serveur

## Ce que tu as reçu (dossier `equipay_pc/`)
- `data/processed/train.jsonl`, `valid.jsonl`, `test.jsonl` : format chat
  `{"messages": [{"role":"system",...}, {"role":"user",...}, {"role":"assistant",...}]}`
- `data/processed/manifest.json` : empreinte du jeu (`source_sha256`) et tailles
- `data/source/qa.yaml`, `scripts/build_dataset.py`, `scripts/common.py` : la source et le
  script qui génère `data/processed` (à titre de référence ; **utilise `data/processed` tel quel**)
- `knowledge/equipay.md` : la base de connaissances de l'app (contexte)

## Étapes

### 1. Environnement
- Vérifie le GPU (`nvidia-smi`). La RTX 5080 (architecture Blackwell) demande **PyTorch compilé
  pour CUDA 12.8 ou plus** : `pip install torch --index-url https://download.pytorch.org/whl/cu128`
  (adapte si une version plus récente est nécessaire), puis vérifie
  `torch.cuda.is_available()` et un petit calcul sur le GPU.
- Crée un environnement Python 3.12 dédié et installe : `torch` (CUDA), `transformers`, `peft`,
  `accelerate`, `mlflow`, `pandas`, `pyyaml`. N'utilise pas bitsandbytes : on entraîne en bf16.
- Teste la connexion au serveur MLflow : `mlflow.set_tracking_uri("http://192.168.1.23:5000")`
  puis `mlflow.get_experiment_by_name("Equipay")` doit renvoyer l'expérimentation. Si ça échoue,
  arrête-toi et demande à l'utilisateur de vérifier que le Mac est allumé, sur le même réseau,
  et que `ml/mlflow_server.sh` tourne.

### 2. Script d'entraînement `train_cuda.py`
Écris un script clair (une boucle d'entraînement PyTorch explicite, pas une boîte noire) qui
reproduit les réglages utilisés sur le Mac, pour que les résultats restent comparables :

| Réglage | Valeur |
|---|---|
| Modèles (arg `--model`) | `Qwen/Qwen3-4B-Instruct-2507` puis `Qwen/Qwen2.5-1.5B-Instruct` |
| Précision | bf16 (poids du modèle de base gelés) |
| LoRA | rang 8, `lora_alpha` 160 (= échelle 20 de MLX), dropout 0.05 |
| Couches ciblées | les **16 dernières couches** du modèle (`layers_to_transform`), modules `q_proj, k_proj, v_proj, o_proj, gate_proj, up_proj, down_proj` |
| Perte | **uniquement sur la réponse de l'assistant** (tokens du prompt système + question masqués à -100) |
| Optimiseur | AdamW, learning rate 1e-4 constant |
| Batch | 4 (padding dynamique), longueur max 512 tokens |
| Durée | **1 epoch** (arg `--epochs`, défaut 1) : itérations = ceil(taille du train / 4 × epochs) |
| Graine | 42 (mélange des données et initialisation) |
| Validation | sur tout `valid.jsonl` toutes les 100 itérations et à la fin |

Points importants :
- Construis l'entrée avec `tokenizer.apply_chat_template(messages, tokenize=False)` ; le prompt
  à masquer = `apply_chat_template(messages[:-1], add_generation_prompt=True, tokenize=False)`.
  Vérifie que le texte complet commence bien par le prompt ; sinon, signale-le.
- **Garde le meilleur point** : sauvegarde l'adaptateur à l'itération où la perte de validation
  est la plus basse (pas forcément la dernière). C'est celui-ci qu'on envoie.
- Active le gradient checkpointing seulement si la mémoire ne suffit pas.

### 3. Ce qu'il faut enregistrer dans MLflow (contrat avec le Mac — respecte les noms exactement)
Un run par modèle, dans l'expérimentation `Equipay` :
- **Nom du run** : `cuda-lora-<nom court du modèle>-<epochs>ep` (ex. `cuda-lora-Qwen3-4B-Instruct-2507-1ep`)
- **Tags** : `stage=fine-tuned-cuda`, `base_model=<id Hugging Face>`, `hardware=RTX 5080`,
  `status=awaiting_mac_eval`
- **Paramètres** : `base_model`, `fine_tuned=True`, `epochs`, `iters`, `learning_rate`,
  `batch_size`, `num_layers=16`, `lora_rank`, `lora_alpha`, `lora_scale=20`, `lora_dropout`,
  `target_modules`, `max_seq_length`, `mask_prompt=True`, `seed`, `dataset_sha` (= `source_sha256`
  du manifest), `dataset_train`, `dataset_valid`, `dataset_test`, `torch_version`, `cuda_version`,
  `gpu_name`
- **Métriques** : `train_loss` (moyenne toutes les 10 itérations, `step`=itération), `val_loss`
  (toutes les 100 itérations, `step`=itération), puis à la fin `best_val_loss`, `best_step`,
  `train_time_s`, `train_tokens_per_s`, `peak_gpu_mem_gb`
- **Fichiers (artifacts)** :
  - `adapter/` : l'adaptateur PEFT **du meilleur point** (`adapter_config.json` +
    `adapter_model.safetensors`), via `model.save_pretrained(...)` puis
    `mlflow.log_artifacts(dossier, "adapter")`
  - `dataset/manifest.json`
  - `train_cuda.py` (le script lui-même, pour la traçabilité)
- **N'enregistre pas de modèle dans le registre et ne fais pas d'évaluation** : le Mac s'en charge
  (fusion, conversion MLX 4 bits, test sur 237 questions, inscription dans `equipay-assistant`).

### 4. Ordre de travail
1. Fais d'abord un **essai éclair** (`--max-iters 20`) avec `Qwen/Qwen2.5-1.5B-Instruct` en
   loggant dans une expérimentation de test (`Equipay-test-pc`), pour valider toute la chaîne
   (entraînement, masque, envoi de l'adaptateur). Mets ensuite cette expérimentation à la corbeille.
2. Lance le vrai entraînement de `Qwen/Qwen3-4B-Instruct-2507` (1 epoch) dans `Equipay`.
3. Puis `Qwen/Qwen2.5-1.5B-Instruct` (1 epoch) dans `Equipay`.
4. Termine par un résumé : pour chaque run, son `run_id`, la durée, `best_val_loss` et
   `best_step`. L'utilisateur transmettra ces `run_id` au Mac.

## Si le réseau ne fonctionne pas
Ne bloque pas : enregistre dans un MLflow local (`mlflow.set_tracking_uri("file:./mlruns")`)
avec exactement les mêmes noms, et sauvegarde aussi l'adaptateur dans
`outputs/<nom du run>/adapter/`. Dis à l'utilisateur de copier ce dossier sur le Mac.

## Règles
- Ne modifie pas les données de `data/processed` (sinon les scores ne seraient plus comparables).
- Ne supprime rien dans l'expérimentation `Equipay`.
- Explique à l'utilisateur, en français et simplement, ce que tu fais à chaque étape.
