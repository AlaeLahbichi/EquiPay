import '../l10n/i18n.dart';
/// « à l'instant », « il y a 5 min », « il y a 3 h », « hier », « il y a 4 j », puis la date.
String timeAgo(DateTime date, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(date);
  if (diff.inMinutes < 1) return tr('à l\'instant');
  if (diff.inHours < 1) return tr('il y a {0} min', [diff.inMinutes]);
  if (diff.inDays < 1) return tr('il y a {0} h', [diff.inHours]);
  if (diff.inDays == 1) return 'hier';
  if (diff.inDays < 7) return tr('il y a {0} j', [diff.inDays]);
  String two(int n) => n.toString().padLeft(2, '0');
  return tr('le {0}/{1}/{2}', [two(date.day), two(date.month), date.year]);
}
