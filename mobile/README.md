# EquiPay — app mobile (Flutter)

Voir le [README principal](../README.md) pour lancer l'app.

```
lib/
  main.dart     point d'entrée (Supabase, services, thème)
  config/       env.dart : configuration lue depuis env.json
  models/       activité, dépense, profil, demandes…
  services/     accès Supabase et appels à l'API (assistant, scanner, décrire)
  screens/      pages, rangées par partie de l'app (home, activity, expenses, profile, requests, support)
  widgets/      composants réutilisés (avatar, bandeau hors ligne, visionneuse de photos…)
  utils/        argent, dates, remboursements, photos, rechargement groupé
  theme/        palette « Lagon »
test/           tests de widgets et unitaires
```
