import 'package:flutter/material.dart';

import '../../models/activity.dart';
import '../../models/plan.dart';
import '../../services/account_service.dart';
import '../../services/activity_repository.dart';
import '../../services/expense_repository.dart';
import '../../services/receipt_scanner.dart';
import '../../widgets/logo_loader.dart';
import '../activity/activity_actions.dart';
import '../activity/activity_detail_page.dart';
import '../home/activity_tile.dart';
import '../plans/plans_page.dart';
import '../../l10n/i18n.dart';

/// Activités archivées par l'utilisateur : les consulter, les désarchiver ou les supprimer.
class ArchivedActivitiesPage extends StatefulWidget {
  const ArchivedActivitiesPage({
    super.key,
    required this.repository,
    required this.expenses,
    required this.receipts,
    this.currentUserId,
  });

  final ActivityRepository repository;
  final ExpenseRepository expenses;
  final ReceiptScanner receipts;
  final String? currentUserId;

  @override
  State<ArchivedActivitiesPage> createState() => _ArchivedActivitiesPageState();
}

enum _Action { open, unarchive, delete }

class _ArchivedActivitiesPageState extends State<ArchivedActivitiesPage> {
  List<Activity>? _activities;
  String? _error;

  /// Activité en cours de traitement (désarchivage ou suppression).
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final activities = await widget.repository.myActivities(archived: true);
      if (!mounted) return;
      setState(() {
        _activities = activities;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open(Activity activity) async {
    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ActivityDetailPage(
          activity: activity,
          repository: widget.repository,
          expenses: widget.expenses,
          receipts: widget.receipts,
          currentUserId: widget.currentUserId,
        ),
      ),
    );
    if (!mounted) return;
    if (message != null) _toast(message);
    await _load();
  }

  Future<void> _onAction(Activity activity, _Action action) async {
    switch (action) {
      case _Action.open:
        await _open(activity);
      case _Action.unarchive:
        setState(() => _busyId = activity.id);
        final result = await setArchivedAll(widget.repository, [activity], archived: false);
        if (!mounted) return;
        setState(() => _busyId = null);
        if (result.limited) {
          await showUpgradeSheet(
            context,
            title: tr('Limite d\'activités en cours'),
            message: (AccountService.instance.state.value?.plan ?? Plan.free).limitMessage(PlanFeature.activities),
            feature: PlanFeature.activities,
          );
          return;
        }
        _toast(result.ok ? tr('{0} : elle est de retour dans tes activités', [result.message]) : result.message);
        await _load();
      case _Action.delete:
        if (!await confirmDeleteOrLeave(context, [activity]) || !mounted) return;
        setState(() => _busyId = activity.id);
        final result = await deleteOrLeaveAll(widget.repository, [activity]);
        if (!mounted) return;
        setState(() => _busyId = null);
        _toast(result.message);
        await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activities = _activities;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Activités archivées'))),
      body: switch ((activities, _error)) {
        (null, final String error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_off_rounded, size: 36, color: colors.onSurfaceVariant),
                const SizedBox(height: 8),
                Text(error, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton.tonal(onPressed: _load, child: Text(tr('Réessayer'))),
              ],
            ),
          ),
        ),
        (null, _) => Center(child: LogoLoader(logoSize: 90, message: tr('Chargement des archives…'))),
        (final List<Activity> list, _) when list.isEmpty => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: colors.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
                  child: Icon(Icons.inventory_2_outlined, size: 40, color: colors.primary),
                ),
                const SizedBox(height: 16),
                Text(tr('Aucune activité archivée'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  tr('Archive une activité terminée depuis son menu ⋮ ou en sélectionnant plusieurs activités '
                  'sur l\'accueil : elle sera rangée ici.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        (final List<Activity> list, _) => RefreshIndicator(
          onRefresh: _load,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: list.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 2),
                  child: Text(
                    tr('Archivées pour toi seulement : les autres participants les voient toujours.'),
                    style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                  ),
                );
              }
              final activity = list[i - 1];
              return _ArchivedTile(
                activity: activity,
                busy: _busyId == activity.id,
                onAction: (action) => _onAction(activity, action),
              );
            },
          ),
        ),
      },
    );
  }
}

class _ArchivedTile extends StatelessWidget {
  const _ArchivedTile({required this.activity, required this.busy, required this.onAction});

  final Activity activity;
  final bool busy;
  final ValueChanged<_Action> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final owner = activity.role == MemberRole.owner;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : () => onAction(_Action.open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(
            children: [
              ActivityLogo(activity: activity),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      activity.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    Text(activity.type.label, style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                )
              else ...[
                IconButton(
                  tooltip: tr('Désarchiver'),
                  onPressed: () => onAction(_Action.unarchive),
                  icon: Icon(Icons.unarchive_outlined, color: colors.primary),
                ),
                IconButton(
                  tooltip: owner ? tr('Supprimer') : tr('Quitter l\'activité'),
                  onPressed: () => onAction(_Action.delete),
                  icon: Icon(owner ? Icons.delete_outline_rounded : Icons.logout_rounded, color: colors.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
