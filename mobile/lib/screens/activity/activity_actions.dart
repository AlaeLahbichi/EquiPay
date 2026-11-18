import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../models/activity.dart';
import '../../services/activity_repository.dart';
import '../../l10n/i18n.dart';

/// Demande confirmation avant de supprimer (activités créées) ou quitter (les autres).
Future<bool> confirmDeleteOrLeave(BuildContext context, List<Activity> activities) async {
  final owned = activities.where((a) => a.role == MemberRole.owner).length;
  final joined = activities.length - owned;
  final single = activities.length == 1 ? activities.first : null;
  final String title;
  final String action;
  if (single != null) {
    title = owned == 1 ? tr('Supprimer « {0} » ?', [single.name]) : tr('Quitter « {0} » ?', [single.name]);
    action = owned == 1 ? tr('Supprimer') : tr('Quitter');
  } else {
    title = tr('Supprimer {0} activités ?', [activities.length]);
    action = tr('Supprimer');
  }
  final message = [
    if (owned > 0)
      owned == 1 && single != null
          ? tr('L\'activité, ses dépenses et ses photos seront supprimées pour tous les participants.')
          : tr('{0} activité{1} que tu as créée{2} '
                '{3} pour tous les participants, '
                'avec dépenses et photos.', [owned, owned > 1 ? 's' : '', owned > 1 ? 's' : '', owned > 1 ? tr('seront supprimées') : tr('sera supprimée')]),
    if (joined > 0)
      single != null
          ? tr('Tu ne la verras plus et les autres participants la garderont. Impossible si tu as des dépenses dedans.')
          : tr('Tu quitteras {0} dont tu n\'es pas le créateur '
                '(impossible si tu y as des dépenses).', [joined == 1 ? tr('l\'activité') : tr('les {0} activités', [joined])]),
    if (owned > 0) tr('Cette action est irréversible.'),
  ].join('\n\n');
  final colors = Theme.of(context).colorScheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.delete_outline_rounded, color: colors.error),
      title: Text(title, textAlign: TextAlign.center),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annuler'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: colors.error, foregroundColor: colors.onError),
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Supprime ou quitte chaque activité ; renvoie le nombre de réussites et un message à afficher.
/// Un échec n'empêche pas de traiter les suivantes.
Future<({int done, String message})> deleteOrLeaveAll(ActivityRepository repository, List<Activity> activities) async {
  var deleted = 0;
  var left = 0;
  Object? error;
  for (final activity in activities) {
    try {
      await repository.deleteOrLeave(activity);
      activity.role == MemberRole.owner ? deleted++ : left++;
    } catch (e) {
      error ??= e;
    }
  }
  final failed = activities.length - deleted - left;
  if (failed == activities.length) return (done: 0, message: friendlyError(error!));
  final parts = [
    if (deleted > 0) deleted == 1 ? tr('Activité supprimée') : tr('{0} activités supprimées', [deleted]),
    if (left > 0) left == 1 ? tr('activité quittée') : tr('{0} activités quittées', [left]),
  ];
  var message = parts.join(', ');
  message = message[0].toUpperCase() + message.substring(1);
  if (failed > 0) message += tr(' · {0} en échec : {1}', [failed, friendlyError(error!)]);
  return (done: deleted + left, message: message);
}

/// Archive ou désarchive ; renvoie la réussite et un message à afficher.
/// [limited] : refusé car l'offre n'autorise pas plus d'activités en cours.
Future<({bool ok, String message, bool limited})> setArchivedAll(
  ActivityRepository repository,
  List<Activity> activities, {
  required bool archived,
}) async {
  try {
    await repository.setArchived([for (final a in activities) a.id], archived: archived);
  } catch (e) {
    return (ok: false, message: friendlyError(e), limited: e is PostgrestException && e.hint == 'plan_limit');
  }
  final n = activities.length;
  final message = archived
      ? (n == 1 ? tr('Activité archivée') : tr('{0} activités archivées', [n]))
      : (n == 1 ? tr('Activité désarchivée') : tr('{0} activités désarchivées', [n]));
  return (ok: true, message: message, limited: false);
}
