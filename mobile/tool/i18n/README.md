# Traductions d'EquiPay

Les textes du code sont en français et passent par `tr('…')` ou `'…'.tr` (voir `lib/l10n/i18n.dart`).
Chaque langue a un fichier `lib/l10n/translations_xx.dart` : texte français → traduction.
Un texte absent d'un fichier s'affiche en français.

## Ajouter une langue (ex. italien)
1. Copier `tr_en.txt` en `tr_it.txt` et traduire chaque ligne (`numéro<TAB>traduction`, garder les `{0}`, `{1}`…).
2. `python3 tool/i18n/build_tr.py tool/i18n it lib/l10n/translations_it.dart`
3. Dans `lib/l10n/i18n.dart` : `it('Italiano', translationsIt),` et l'import du fichier.

## Après avoir ajouté des textes dans l'app
1. Entourer les nouveaux textes avec `tr(...)` (ou lancer `python3 tool/i18n/i18n_wrap.py lib/…/fichier.dart`).
2. `python3 tool/i18n/extract_keys.py tool/i18n tool/i18n/keys.json` : liste à jour des textes (numérotés).
3. Compléter les fichiers `tr_xx.txt` pour les nouveaux numéros, puis relancer `build_tr.py` pour chaque langue.
