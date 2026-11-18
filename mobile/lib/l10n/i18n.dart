import 'package:flutter/widgets.dart';

import 'translations_ar.dart';
import 'translations_de.dart';
import 'translations_en.dart';
import 'translations_es.dart';

/// Langues de l'app. Le français est la langue de référence : les textes du code sont en français
/// et chaque autre langue a son fichier translations_xx.dart (texte français → traduction).
///
/// Ajouter une langue : créer translations_xx.dart (copie de translations_en.dart, valeurs traduites)
/// et l'ajouter ci-dessous. Un texte absent du fichier s'affiche en français.
enum AppLanguage {
  fr('Français', {}),
  en('English', translationsEn),
  de('Deutsch', translationsDe),
  es('Español', translationsEs),
  ar('العربية', translationsAr);

  const AppLanguage(this.nativeName, this.translations);

  /// Nom de la langue dans cette langue.
  final String nativeName;
  final Map<String, String> translations;

  Locale get locale => Locale(name);

  /// Arabe : écran de droite à gauche.
  bool get rtl => this == AppLanguage.ar;

  static AppLanguage current = AppLanguage.fr;
}

/// Traduit un texte français, avec des valeurs {0}, {1}… : tr('Payé par {0}', [nom]).
String tr(String fr, [List<Object?> args = const []]) {
  var text = AppLanguage.current.translations[fr] ?? fr;
  for (var i = 0; i < args.length; i++) {
    text = text.replaceAll('{$i}', '${args[i]}');
  }
  return text;
}

extension Translate on String {
  /// Texte traduit dans la langue choisie (sans valeur à insérer).
  String get tr => AppLanguage.current.translations[this] ?? this;
}
