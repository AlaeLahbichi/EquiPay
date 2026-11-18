import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/activity.dart';
import '../../models/plan.dart';
import '../../services/account_service.dart';
import '../../services/activity_repository.dart';
import '../../services/auth_service.dart';
import '../../services/expense_repository.dart';
import '../../services/receipt_scanner.dart';
import '../../services/network_status.dart';
import '../../utils/reloader.dart';
import '../../widgets/logo_loader.dart';
import '../activity/activity_actions.dart';
import '../activity/activity_detail_page.dart';
import '../plans/plans_page.dart';
import 'activity_sheets.dart';
import 'activity_tile.dart';
import 'add_button.dart';
import '../../l10n/i18n.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.repository,
    required this.expenses,
    required this.receipts,
    required this.auth,
    required this.network,
    required this.onSignInRequested,
  });

  final ActivityRepository repository;
  final ExpenseRepository expenses;
  final ReceiptScanner receipts;
  final AuthService auth;
  final NetworkStatus network;

  /// Ouvre l'onglet Profil pour se connecter.
  final VoidCallback onSignInRequested;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Activity>? _activities;
  String? _error;
  StreamSubscription<void>? _changes;
  late final _reloader = Reloader(_fetch);
  String? _userId;

  /// Mode sélection (appui long sur une activité) : identifiants sélectionnés, null hors sélection.
  Set<String>? _selected;
  var _busy = false;

  bool get _signedIn => _userId != null;
  bool get _selecting => _selected != null;

  @override
  void initState() {
    super.initState();
    widget.auth.user.addListener(_onAuthChange);
    widget.network.online.addListener(_onNetworkChange);
    _start(widget.auth.user.value?.id);
  }

  @override
  void dispose() {
    _changes?.cancel();
    _reloader.dispose();
    widget.auth.user.removeListener(_onAuthChange);
    widget.network.online.removeListener(_onNetworkChange);
    super.dispose();
  }

  // Connexion, déconnexion ou changement de compte : on repart de zéro
  void _onAuthChange() {
    final userId = widget.auth.user.value?.id;
    if (userId == _userId) return; // simple mise à jour du profil
    setState(() => _start(userId));
  }

  void _start(String? userId) {
    _userId = userId;
    _activities = null;
    _selected = null;
    _error = null;
    _changes?.cancel();
    _changes = null;
    if (userId == null) return;
    _load();
    // Mise à jour en temps réel (ex. invitation acceptée depuis un autre appareil)
    _changes = widget.repository.changes().listen((_) => _reloader.schedule());
  }

  // Retour du réseau : on recharge si le dernier chargement avait échoué
  void _onNetworkChange() {
    if (widget.network.online.value && _error != null && _signedIn) _load();
  }

  Future<void> _load() => _reloader.now();

  Future<void> _fetch() async {
    final userId = _userId;
    try {
      final activities = await widget.repository.myActivities();
      if (!mounted || userId != _userId) return;
      setState(() {
        _activities = activities;
        _error = null;
        // Activités disparues entre-temps (supprimées ailleurs) : on les retire de la sélection
        final ids = {for (final a in activities) a.id};
        _selected?.removeWhere((id) => !ids.contains(id));
        if (activities.isEmpty) _selected = null;
      });
    } catch (e) {
      if (!mounted || userId != _userId) return;
      setState(() => _error = friendlyError(e));
      // Une liste est déjà affichée : on prévient sans la masquer
      if (_activities != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error!)));
      }
    }
  }

  Future<void> _openAddSheet() async {
    final result = await showAddActivitySheet(context, widget.repository);
    if (result == AddResult.none) return;
    if (result == AddResult.createdWithoutLogo && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Activité créée, mais le logo n\'a pas pu être envoyé.'))));
    }
    if (result == AddResult.requested && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Demande envoyée ! Tu seras prévenu dès que le créateur répond.'))));
      return;
    }
    await _load();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _startSelection(Activity activity) {
    HapticFeedback.selectionClick();
    setState(() => _selected = {activity.id});
  }

  void _toggle(Activity activity) {
    final selected = _selected!;
    setState(() {
      if (!selected.remove(activity.id)) selected.add(activity.id);
    });
  }

  void _endSelection() => setState(() => _selected = null);

  List<Activity> get _selectedActivities => [
    for (final a in _activities ?? const <Activity>[])
      if (_selected?.contains(a.id) ?? false) a,
  ];

  Future<void> _archiveSelected() async {
    final activities = _selectedActivities;
    if (activities.isEmpty) return;
    setState(() => _busy = true);
    final result = await setArchivedAll(widget.repository, activities, archived: true);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _selected = null;
    });
    _toast(result.ok ? tr('{0} · retrouve-les dans Profil > Activités archivées', [result.message]) : result.message);
    await _load();
  }

  Future<void> _deleteSelected() async {
    final activities = _selectedActivities;
    if (activities.isEmpty || !await confirmDeleteOrLeave(context, activities) || !mounted) return;
    setState(() => _busy = true);
    final result = await deleteOrLeaveAll(widget.repository, activities);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected = null;
    });
    _toast(result.message);
    await _load();
  }

  Future<void> _openActivity(Activity activity) async {
    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ActivityDetailPage(
          activity: activity,
          repository: widget.repository,
          expenses: widget.expenses,
          receipts: widget.receipts,
          currentUserId: widget.auth.user.value?.id,
        ),
      ),
    );
    // Titre ou photo modifiés, participant retiré, activité archivée ou supprimée : on rafraîchit la liste
    if (!mounted) return;
    if (message != null) _toast(message);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final activities = _activities ?? const <Activity>[];
    final selected = _selected;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endSelection();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ValueListenableBuilder<AccountState?>(
                valueListenable: AccountService.instance.state,
                builder: (context, account, _) {
                  final limit = account?.plan.limit(PlanFeature.activities);
                  final active = activities.where((a) => a.role == MemberRole.owner).length;
                  return _Header(
                    plan: _signedIn ? account?.plan : null,
                    activeLabel: _signedIn && _activities != null && limit != null ? tr('{0}/{1} en cours', [active, limit]) : null,
                    selectedCount: selected?.length,
                    canSelect: activities.isNotEmpty,
                    allSelected: selected != null && selected.length == activities.length,
                    onSelect: () => setState(() => _selected = {}),
                    onCancel: _endSelection,
                    onSelectAll: () => setState(() {
                      _selected = selected?.length == activities.length ? {} : {for (final a in activities) a.id};
                    }),
                  );
                },
              ),
              Expanded(child: _buildContent()),
              if (_signedIn)
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: selected == null
                      ? Padding(
                          key: const ValueKey('add'),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: AddButton(onPressed: _openAddSheet)),
                        )
                      : _SelectionBar(
                          key: const ValueKey('selection'),
                          busy: _busy,
                          enabled: selected.isNotEmpty,
                          onArchive: _archiveSelected,
                          onDelete: _deleteSelected,
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (!_signedIn) {
      return _Message(
        icon: Icons.person_outline_rounded,
        title: tr('Connecte-toi pour commencer'),
        subtitle: tr('Crée tes activités et partage tes dépenses avec tes amis.'),
        action: FilledButton(onPressed: widget.onSignInRequested, child: Text(tr('Se connecter'))),
      );
    }
    if (_error != null && _activities == null) {
      return _Message(
        icon: Icons.wifi_off_rounded,
        title: tr('Impossible de charger tes activités'),
        subtitle: _error!,
        action: FilledButton.tonal(onPressed: _load, child: Text(tr('Réessayer'))),
      );
    }
    final activities = _activities;
    if (activities == null) {
      return Center(child: LogoLoader(logoSize: 110, message: tr('Chargement de tes activités…')));
    }
    if (activities.isEmpty) {
      return _Message(
        icon: Icons.luggage_rounded,
        title: tr('Aucune activité'),
        subtitle: tr('Crée ta première activité ou rejoins celle d\'un ami avec son code.'),
        action: FilledButton.tonal(onPressed: _openAddSheet, child: Text(tr('Créer ou rejoindre une activité'))),
      );
    }
    final selected = _selected;
    return RefreshIndicator(
      onRefresh: _load,
      child: ValueListenableBuilder<AccountState?>(
        valueListenable: AccountService.instance.state,
        builder: (context, account, _) {
          final plan = account?.plan ?? Plan.free;
          final limit = plan.limit(PlanFeature.activities);
          final active = activities.where((a) => a.role == MemberRole.owner).length;
          final atLimit = limit != null && active >= limit;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            children: [
              if (account != null && selected == null && (plan == Plan.free || atLimit) && plan.next != null) ...[
                _UpgradeBanner(plan: plan, active: active, limit: limit),
                const SizedBox(height: 12),
              ],
              for (final activity in activities) ...[
                ActivityTile(
                  activity: activity,
                  selected: selected?.contains(activity.id),
                  onTap: selected == null ? () => _openActivity(activity) : () => _toggle(activity),
                  onLongPress: selected == null ? () => _startSelection(activity) : () => _toggle(activity),
                ),
                const SizedBox(height: 10),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.selectedCount,
    required this.canSelect,
    required this.allSelected,
    required this.onSelect,
    required this.onCancel,
    required this.onSelectAll,
    this.plan,
    this.activeLabel,
  });

  /// Offre de l'utilisateur connecté (null : visiteur).
  final Plan? plan;

  /// « 2/3 en cours » quand l'offre limite les activités.
  final String? activeLabel;

  /// Nombre d'activités sélectionnées, null hors mode sélection.
  final int? selectedCount;
  final bool canSelect;
  final bool allSelected;
  final VoidCallback onSelect;
  final VoidCallback onCancel;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final count = selectedCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('EquiPay'),
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: colors.primary,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              if (plan case final plan?) _PlanChip(plan: plan),
            ],
          ),
          Text(tr('by Alae Lahbichi'), style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: Row(
              children: [
                if (count != null)
                  IconButton(
                    tooltip: tr('Annuler la sélection'),
                    visualDensity: VisualDensity.compact,
                    onPressed: onCancel,
                    icon: const Icon(Icons.close_rounded),
                  ),
                Expanded(
                  child: Text(
                    count == null
                        ? (activeLabel == null ? tr('Mes activités') : tr('Mes activités · {0}', [activeLabel]))
                        : count == 0
                        ? tr('Sélectionne des activités')
                        : tr('{0} sélectionnée{1}', [count, count > 1 ? 's' : '']),
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: colors.onSurface),
                  ),
                ),
                if (count != null)
                  TextButton(
                    onPressed: onSelectAll,
                    child: Text(allSelected ? tr('Tout désélectionner') : tr('Tout sélectionner')),
                  )
                else if (canSelect)
                  TextButton.icon(
                    onPressed: onSelect,
                    icon: const Icon(Icons.checklist_rounded, size: 20),
                    label: Text(tr('Sélectionner')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.subtitle, required this.action});

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: colors.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: colors.primary),
            ),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            action,
          ],
        ),
      ),
    );
  }
}

/// Actions sur les activités sélectionnées.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    super.key,
    required this.busy,
    required this.enabled,
    required this.onArchive,
    required this.onDelete,
  });

  final bool busy;
  final bool enabled;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = enabled && !busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: busy
          ? const SizedBox(height: 52, child: Center(child: CircularProgressIndicator()))
          : Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: active ? onArchive : null,
                    icon: const Icon(Icons.archive_outlined),
                    label: Text(tr('Archiver')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: colors.error,
                      foregroundColor: colors.onError,
                    ),
                    onPressed: active ? onDelete : null,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(tr('Supprimer')),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Badge de l'offre dans l'en-tête : ouvre les offres.
class _PlanChip extends StatelessWidget {
  const _PlanChip({required this.plan});

  final Plan plan;

  @override
  Widget build(BuildContext context) {
    return Material(
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: plan.isPaid ? planGradient(plan) : LinearGradient(colors: [Plan.plus.color, Plan.pro.color]),
        ),
        child: InkWell(
          onTap: () => openPlans(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(
                  plan.isPaid ? plan.label : tr('Passer à Plus'),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bandeau d'invitation à passer à l'offre supérieure (Gratuit, ou limite d'activités atteinte).
class _UpgradeBanner extends StatelessWidget {
  const _UpgradeBanner({required this.plan, required this.active, required this.limit});

  final Plan plan;
  final int active;
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final next = plan.next!;
    final atLimit = limit != null && active >= limit!;
    return Material(
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(gradient: planGradient(next)),
        child: InkWell(
          onTap: () => openPlans(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                Icon(atLimit ? Icons.rocket_launch_rounded : Icons.auto_awesome_rounded, color: Colors.white, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        atLimit
                            ? tr('Limite atteinte : {0}/{1} activités en cours', [active, limit])
                            : tr('Passe à EquiPay {0}', [next.label]),
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tr('{0}, '
                        'plus de scans et les statistiques · {1} DH/mois', [PlanFeature.activities.allowance(next.limit(PlanFeature.activities)), next.monthlyPrice]),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
