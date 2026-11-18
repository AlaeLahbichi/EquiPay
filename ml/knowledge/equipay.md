# EquiPay — base de connaissances de l'assistant (v2)

Référence des faits utilisés pour écrire le jeu de données `data/source/`. Elle décrit
l'application telle qu'elle existe (version 1.0.0). Les règles des dépenses sont celles
imposées par la base de données, même si l'écran d'ajout de dépense arrive dans une
prochaine version.

EquiPay est une application mobile (iPhone et Android) pour gérer et partager les dépenses
d'un groupe : voyage, sortie, dépenses du quotidien ou crédit. Elle calcule qui doit combien
à qui. Créée par Alae Lahbichi dans le cadre d'un projet à l'EMSI (école d'ingénieurs au Maroc).

## Navigation (barre du bas)
- **EquiPay** : accueil, liste de mes activités (logo, nom, flèche), de la plus récente à la
  plus ancienne. Bouton rond orange « + » : « Créer une activité » ou « Rejoindre une activité ».
  Déconnecté : « Connecte-toi pour commencer » + bouton « Se connecter ».
- **Requests** : demandes pour rejoindre des activités. Deux parties : « Reçues » (Accepter /
  Refuser) et « Envoyées » (statut En attente / Acceptée / Refusée / Annulée, bouton Annuler
  tant que c'est en attente). Compteur rouge sur l'onglet. Déconnecté : « Connecte-toi pour
  voir tes demandes ».
- **Free Card** : pas encore disponible.
- **Profile** : compte, préférences, À propos, bulle « Support » (assistant).

## Compte (onglet Profile)
- Déconnecté : « Continuer avec Google » ou « Continuer avec un email » (onglets Connexion /
  Inscription). Inscription : prénom, nom, email, mot de passe (6 caractères minimum),
  « Créer mon compte ». Le compte est créé et connecté immédiatement.
- Pas de connexion Apple (ni Facebook, ni Microsoft).
- Erreurs : « Email ou mot de passe incorrect », « Un compte existe déjà avec cet email »,
  « Mot de passe trop faible (6 caractères minimum) ».
- Pas de « mot de passe oublié » ni de changement de mot de passe dans l'app → support.
- Connecté : photo (appuyer pour changer : galerie ou appareil photo ; silhouette grise par
  défaut), nom, email ; section Nom / Pseudo / Email ; « Modifier mes informations » (nom,
  pseudo, email → « Enregistrer » ; nouvel email à confirmer par lien si demandé).
- Pseudo : créé automatiquement depuis le début de l'email (chiffres ajoutés si pris) ;
  unique ; 3 à 30 caractères : minuscules, chiffres, « _ ».
- « Se déconnecter » (confirmation). « Supprimer mon compte » (confirmation) : supprime
  définitivement le profil, les activités créées (pour tous leurs membres) et les dépenses.
- Préférences : Langue (العربية, Français, English — mémorisée, app encore en français,
  traductions à venir) ; interrupteur « Mode sombre » (par défaut : suit le téléphone).
- Extra : « À propos » (logo, version 1.0.0, description, fonctionnalités, © 2026 Alae Lahbichi).
- Données en ligne : même compte sur plusieurs téléphones.

## Activités
- Types : Voyage, Sortie, Quotidien, Crédit (choisi à la création, non modifiable).
- Création : nom (obligatoire), devise (obligatoire, pas de valeur par défaut), type, logo
  optionnel (galerie / appareil photo ; sinon icône du type). « Activité créée, mais le logo
  n'a pas pu être envoyé » : l'ajouter ensuite via Modifier l'activité.
- 12 devises : EUR, MAD, USD, GBP, CHF, CAD, TRY, AED, SAR, TND, DZD, JPY.
- Détail : logo, nom, type ; carte « Total des dépenses » (montant + nombre, ou « Aucune
  dépense pour le moment ») ; « Membres (N) » : photo, nom (« (toi) »), rôle (Créateur /
  Membre / Spectateur), montant payé, solde vert (+) ou rouge (−) (rien si 0).
  Mise à jour en temps réel ; tirer vers le bas pour recharger.
- Owner : code discret sous le nom, masqué « ••••-•••• », œil pour l'afficher, icône pour le
  copier (« Code copié »).
- Owner : crayon « Modifier l'activité » (ou appui sur le logo) : titre, photo (« Utiliser le
  logo par défaut »), devise → « Enregistrer ». Devise verrouillée (cadenas) dès qu'il y a des
  dépenses.
- Owner : toucher un participant → rôle « Membre (participant) » / « Spectateur », ou
  « Retirer de l'activité » (confirmation). Impossible si le membre a des dépenses (le passer
  en spectateur). Une personne retirée peut redemander avec le code. Rôle d'owner unique et
  non transférable.
- Pas encore dans l'app : description, dates, lieu, recherche / filtre d'activités, quitter
  une activité, supprimer une activité, régénérer le code, invitation par email → support.

## Rôles
- Owner (créateur) : code, demandes, rôles, retrait, titre / photo / devise.
- Membre : voit tout, ajoute des dépenses, modifie / supprime les siennes.
- Spectateur : lecture seule ; ni payeur ni participant.

## Rejoindre
- « + » → « Rejoindre une activité » → code de 8 caractères (ex. FN3V-HM7S ; majuscules ou
  minuscules, tiret facultatif ; pas de 0, O, 1, I, L) → « Envoyer la demande ».
- Le créateur accepte ou refuse dans Requests ; on rejoint comme membre ; l'activité apparaît
  automatiquement sur l'accueil ; notification en bas de l'écran avec « Voir ».
- Messages : « Code invalide », « Tu fais déjà partie de… », « Ta demande … est déjà en
  attente ». Sans réponse, la demande reste en attente.
- Pour inviter : copier le code et l'envoyer ; l'ami installe l'app, crée un compte, saisit
  le code. Spectateur : il rejoint puis l'owner change son rôle.

## Dépenses (règles de la base de données)
- Owner et membres. Nom, description optionnelle, montant (> 0, 2 décimales), devise, date
  (aujourd'hui par défaut), payeur (membre), participants avec pourcentages (somme = 100 %),
  lieu optionnel (pays, ville, adresse).
- Seul le créateur modifie / supprime sa dépense.
- Autre devise : taux de change vers la devise de l'activité (ex. 100 MAD × 0,092 = 9,20 €).
- 0 à 2 photos (reçu, devis) par dépense, par son créateur ; visibles par les membres seuls.

## Soldes
- Solde = payé − part. Vert + : on te doit ; rouge − : tu dois ; 0 : équilibre.
- Pas de paiement dans l'app ; remboursement en dehors. Noter un remboursement : dépense payée
  par celui qui rembourse, 100 % pour celui qui est remboursé.

## Fiabilité et sécurité
- Bandeau rouge « Pas de connexion internet », vert « Connexion rétablie » (rechargement
  automatique), « Réessayer » en cas d'erreur.
- Règles d'accès dans la base (Row Level Security) : seuls les membres voient une activité.
- Notifications seulement quand l'app est ouverte (pas de push quand elle est fermée).
- Autorisations : photos / appareil photo uniquement au moment de choisir une image.

## Environnement
- Flutter (Dart) ; Supabase (PostgreSQL, authentification, stockage, temps réel) ;
  serveur Python FastAPI pour l'assistant.
- Assistant : Qwen3-4B affiné avec LoRA, suivi avec MLflow, n'a pas accès aux données de
  l'utilisateur, ne fait pas encore d'actions (prévu : ajouter une dépense par une phrase).
  Bulle « Support » de l'onglet Profile ; « Impossible de joindre l'assistant » → connexion
  + « Réessayer ».
- Couleurs : turquoise (lagon) et orange.

## Assistant : comportements
- Répond en français (comprend aussi l'anglais et la darija).
- Question sur EquiPay sans réponse connue → support (support@equipay.app, adresse
  provisoire à confirmer).
- Question sans rapport avec EquiPay ni le partage de dépenses → refus poli.
