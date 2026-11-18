import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../l10n/i18n.dart';

// Formats de date de toutes les langues (chargés en mémoire, sans attente)
final _formats = initializeDateFormatting();

/// « 10 oct. 2026 » (dans la langue de l'app), ou « aujourd'hui » / « hier » si [relative].
String formatDate(DateTime date, {bool relative = false, DateTime? now}) {
  final d = DateTime(date.year, date.month, date.day);
  if (relative) {
    final today = now ?? DateTime.now();
    final diff = DateTime(today.year, today.month, today.day).difference(d).inDays;
    if (diff == 0) return 'aujourd\'hui'.tr;
    if (diff == 1) return 'hier'.tr;
  }
  _formats.ignore();
  return DateFormat.yMMMd(AppLanguage.current.name).format(d);
}

/// « Octobre 2026 ».
String formatMonth(DateTime month) {
  _formats.ignore();
  final text = DateFormat.yMMMM(AppLanguage.current.name).format(month);
  return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

/// « mer. » (abrégé) ou « mercredi ».
String weekdayName(DateTime d, {bool short = false}) {
  _formats.ignore();
  final lang = AppLanguage.current.name;
  return (short ? DateFormat.E(lang) : DateFormat.EEEE(lang)).format(d);
}

/// « mer. 21 oct. ».
String formatShortDay(DateTime d) {
  _formats.ignore();
  return DateFormat.MMMEd(AppLanguage.current.name).format(d);
}

/// Jours de la semaine abrégés, du lundi au dimanche.
List<String> weekdayNames() => [for (var i = 0; i < 7; i++) weekdayName(DateTime(2024, 1, 1 + i), short: true)];
