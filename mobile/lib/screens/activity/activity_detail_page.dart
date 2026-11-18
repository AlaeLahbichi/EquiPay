import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/plan.dart';
import '../../models/activity.dart';
import '../../models/activity_overview.dart';
import '../../models/expense.dart';
import '../../services/account_service.dart';
import '../../services/activity_repository.dart';
import '../../services/expense_describer.dart';
import '../../services/expense_repository.dart';
import '../../services/pending_expenses.dart';
import '../../services/receipt_scanner.dart';
import '../../services/trip_repository.dart';
import '../../theme/app_colors.dart';
import '../../utils/dates.dart';
import '../../utils/money.dart';
import '../../utils/pick_photo.dart';
import '../../utils/reloader.dart';
import '../plans/plans_page.dart';
import '../../widgets/logo_loader.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/user_avatar.dart';
import 'activity_actions.dart';
import 'activity_chart_page.dart';
import 'activity_insights_page.dart';
import 'activity_summary_page.dart';
import 'owner_sheets.dart';
import 'trip_plan_page.dart';
import '../expenses/add_expense_sheet.dart';
import '../expenses/describe_expense_page.dart';
import '../expenses/expense_detail_page.dart';
import '../expenses/expense_form_page.dart';
import '../expenses/receipt_scan_page.dart';
import '../home/activity_tile.dart';
import '../../l10n/i18n.dart';

/// Détail d'une activité : total, dépenses, membres et photos.
/// L'owner voit aussi, discrètement, le code d'accès à partager, et peut modifier
/// l'activité (titre, photo) et gérer les participants (rôle, retrait).
/// Le menu ⋮ regroupe : modifier, archiver, résumé, graphiques, insights et supprimer (ou quitter).
/// La page se ferme avec un message quand l'activité est archivée, désarchivée, supprimée ou quittée.
class ActivityDetailPage extends StatefulWidget {
  const ActivityDetailPage({
    super.key,
    required this.activity,
    required this.repository,
    required this.expenses,
    required this.receipts,
    this.currentUserId,
  });

  final Activity activity;
  final ActivityRepository repository;
  final ExpenseRepository expenses;
  final ReceiptScanner receipts;
  final String? currentUserId;

  @override
  State<ActivityDetailPage> createState() => _ActivityDetailPageState();
}

class _ActivityDetailPageState extends State<ActivityDetailPage> {
  late Activity _activity = widget.activity;
  ActivityOverview? _overview;
  List<Expense> _expenses = const [];
  List<Photo> _photos = const [];

  /// Programme (voyages et sorties) : nombre d'éléments, null tant qu'il n'est pas chargé.
  int? _programCount;
  String? _error;
  StreamSubscription<void>? _changes;
  late final _reloader = Reloader(_fetch);
  var _tab = _Tab.expenses;
  var _memberSort = MemberSort.standard;
  var _busy = false;

  /// Envoi de photos en cours : (envoyées, total).
  (int, int)? _uploading;

  bool get _isOwner => _activity.role == MemberRole.owner;

  /// Owner et membres ajoutent des dépenses ; un spectateur les regarde seulement.
  bool get _canEdit => _activity.role != MemberRole.viewer;

  @override
  void initState() {
    super.initState();
    _load();
    // Nouvelle dépense, nouveau membre ou nouvelle photo : mise à jour en direct
    _changes = widget.repository.activityChanges(widget.activity.id).listen((_) => _reloader.schedule());
    // Dépenses hors ligne ajoutées ou envoyées au retour du réseau
    PendingExpenses.instance.addListener(_reloader.schedule);
  }

  @override
  void dispose() {
    PendingExpenses.instance.removeListener(_reloader.schedule);
    _changes?.cancel();
    _reloader.dispose();
    super.dispose();
  }

  Future<void> _load() => _reloader.now();

  Future<void> _fetch() async {
    try {
      final results = await Future.wait<Object>([
        widget.repository.overview(widget.activity.id),
        widget.expenses.expenses(widget.activity.id),
        widget.expenses.activityPhotos(widget.activity.id),
      ]);
      if (!mounted) return;
      setState(() {
        _overview = results[0] as ActivityOverview;
        _expenses = results[1] as List<Expense>;
        _photos = results[2] as List<Photo>;
        _error = null;
      });
      if (hasProgram(_activity)) await _loadProgramCount();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _loadProgramCount() async {
    try {
      final items = await TripRepository.instance.items(widget.activity.id);
      if (mounted) setState(() => _programCount = items.length);
    } catch (_) {
      // Le programme s'ouvre quand même ; le nombre s'affichera au prochain chargement
    }
  }

  Future<void> _openProgram() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TripPlanPage(activity: _activity, currentUserId: widget.currentUserId),
      ),
    );
    if (mounted) await _loadProgramCount();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _editActivity() async {
    final updated = await showEditActivitySheet(
      context,
      widget.repository,
      _activity,
      currencyLocked: (_overview?.expenseCount ?? 0) > 0,
    );
    if (updated == null || !mounted) return;
    final currencyChanged = updated.currency != _activity.currency;
    setState(() => _activity = updated);
    _toast(tr('Activité mise à jour'));
    // Les montants s'affichent dans la nouvelle devise
    if (currencyChanged) await _load();
  }

  Future<void> _onMenu(_MenuAction action) async {
    final overview = _overview;
    switch (action) {
      case _MenuAction.edit:
        await _editActivity();
      case _MenuAction.archive:
        await _toggleArchive();
      case _MenuAction.summary:
        if (overview == null) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                ActivitySummaryPage(activity: _activity, overview: overview, currentUserId: widget.currentUserId),
          ),
        );
      case _MenuAction.chart:
        if (overview == null || !_insightsAllowed()) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                ActivityChartPage(activity: _activity, overview: overview, currentUserId: widget.currentUserId),
          ),
        );
      case _MenuAction.insights:
        if (overview == null || !_insightsAllowed()) return;
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => ActivityInsightsPage(
              activity: _activity,
              overview: overview,
              expenses: _expenses,
              currentUserId: widget.currentUserId,
            ),
          ),
        );
      case _MenuAction.delete:
        await _deleteOrLeave();
    }
  }

  /// Graphiques et statistiques : réservés aux offres payantes.
  bool _insightsAllowed() {
    final plan = AccountService.instance.state.value?.plan ?? Plan.free;
    if (plan.hasInsights) return true;
    showUpgradeSheet(
      context,
      title: tr('Graphiques et statistiques'),
      message: tr('Les graphiques des dépenses et les statistiques sont disponibles à partir de l\'offre Plus.'),
    );
    return false;
  }

  Future<void> _toggleArchive() async {
    setState(() => _busy = true);
    final result = await setArchivedAll(widget.repository, [_activity], archived: !_activity.archived);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      Navigator.of(context).pop(result.message);
    } else if (result.limited) {
      await showUpgradeSheet(
        context,
        title: tr('Limite d\'activités en cours'),
        message: (AccountService.instance.state.value?.plan ?? Plan.free).limitMessage(PlanFeature.activities),
        feature: PlanFeature.activities,
      );
    } else {
      _toast(result.message);
    }
  }

  Future<void> _deleteOrLeave() async {
    if (!await confirmDeleteOrLeave(context, [_activity]) || !mounted) return;
    setState(() => _busy = true);
    final result = await deleteOrLeaveAll(widget.repository, [_activity]);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.done > 0) {
      Navigator.of(context).pop(result.message);
    } else {
      _toast(result.message);
    }
  }

  Future<void> _manageMember(MemberSummary member) async {
    final message = await showMemberActionsSheet(context, widget.repository, activityId: _activity.id, member: member);
    if (message == null || !mounted) return;
    _toast(message);
    await _load();
  }

  /// Logo de l'activité en grand ; l'owner peut le changer depuis la visionneuse.
  void _openLogo() {
    final url = _activity.coverUrl;
    if (url == null) {
      if (_isOwner) _editActivity();
      return;
    }
    openPhotoViewer(
      context,
      photos: [
        ViewerPhoto(image: NetworkImage(url), heroTag: 'activity-logo-${_activity.id}', caption: _activity.name),
      ],
      action: _isOwner
          ? ViewerAction(icon: Icons.edit_outlined, label: tr('Modifier l\'activité'), onPressed: _editActivity)
          : null,
    );
  }

  void _openAvatar(MemberSummary member) {
    final url = member.profile.avatarUrl;
    if (url == null || url.isEmpty) return;
    openPhotoViewer(
      context,
      photos: [
        ViewerPhoto(
          image: NetworkImage(url),
          heroTag: 'avatar-${member.profile.id}',
          caption: member.profile.displayName,
        ),
      ],
    );
  }

  Future<void> _addExpense() async {
    final overview = _overview;
    final userId = widget.currentUserId;
    if (overview == null || userId == null) return;
    final method = await showAddExpenseSheet(context);
    if (!mounted) return;
    ReceiptScan? scan;
    DescribedExpense? described;
    Uint8List? photo;
    if (method == ExpenseMethod.describe) {
      // 1. Phrase libre  2. comprise par le modèle  3. formulaire pré-rempli
      described = await Navigator.of(context).push<DescribedExpense>(
        MaterialPageRoute(
          builder: (_) => DescribeExpensePage(activity: _activity, members: overview.members, currentUserId: userId),
        ),
      );
      if (described == null || !mounted) return;
    } else if (method == ExpenseMethod.scan) {
      // 1. Photo du ticket (appareil photo ou galerie)  2. lecture par le modèle  3. formulaire pré-rempli
      photo = await pickPhoto(context, title: tr('Photo du ticket'), maxSize: 2000);
      if (photo == null || !mounted) return;
      scan = await Navigator.of(context).push<ReceiptScan>(
        MaterialPageRoute(
          builder: (_) => ReceiptScanPage(image: photo!, scanner: widget.receipts),
        ),
      );
      if (scan == null || !mounted) return;
      if (identical(scan, ReceiptScanPage.manual)) scan = null; // saisie à la main, photo jointe
    } else if (method != ExpenseMethod.manual) {
      return;
    }
    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ExpenseFormPage(
          activity: _activity,
          members: overview.members,
          currentUserId: userId,
          repository: widget.expenses,
          prefill: scan,
          described: described,
          initialPhoto: photo,
        ),
      ),
    );
    if (message == null || !mounted) return;
    _toast(message);
    setState(() => _tab = _Tab.expenses);
    await _load();
  }

  Future<void> _openExpense(Expense expense) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExpenseDetailPage(
          activity: _activity,
          expense: expense,
          members: _overview?.members ?? const [],
          currentUserId: widget.currentUserId,
          expenses: widget.expenses,
          activities: widget.repository,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _addPhotos() async {
    final images = await pickPhotos(context, title: tr('Photos de l\'activité'));
    if (images.isEmpty || !mounted) return;
    setState(() => _uploading = (0, images.length));
    Object? error;
    var sent = 0;
    // Une par une : la progression reste lisible et un échec n'annule pas les autres
    for (final bytes in images) {
      try {
        await widget.expenses.addActivityPhoto(_activity.id, bytes);
        sent++;
      } catch (e) {
        error ??= e;
      }
      if (mounted) setState(() => _uploading = (sent, images.length));
    }
    if (!mounted) return;
    setState(() => _uploading = null);
    final failed = images.length - sent;
    if (failed == 0) {
      _toast(sent == 1 ? tr('Photo ajoutée') : tr('{0} photos ajoutées', [sent]));
    } else if (sent == 0) {
      _toast(friendlyError(error!));
    } else {
      _toast(tr('{0} photos ajoutées, {1} n\'ont pas pu être envoyées', [sent, failed]));
    }
    await _load();
  }

  void _openPhotos(int index) {
    final photos = _photos;
    final names = {for (final m in _overview?.members ?? const <MemberSummary>[]) m.profile.id: m.profile.displayName};
    openPhotoViewer(
      context,
      initialIndex: index,
      photos: [
        for (final p in photos)
          ViewerPhoto(
            image: NetworkImage(p.url),
            heroTag: 'activity-photo-${p.id}',
            caption: [
              tr('Ajoutée par {0}', [names[p.uploadedBy] ?? tr('un ancien membre')]),
              if (p.createdAt != null) formatDate(p.createdAt!.toLocal(), relative: true),
            ].join(' · '),
            // Photos partagées : tout membre, spectateur compris, peut les supprimer
            canDelete: true,
          ),
      ],
      onDelete: (i) async {
        await widget.expenses.deletePhoto(photos[i]);
        if (mounted) {
          _toast(tr('Photo supprimée'));
          await _load();
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final activity = _activity;
    final colors = Theme.of(context).colorScheme;
    final overview = _overview;
    return Scaffold(
      appBar: AppBar(
        title: Text(activity.name),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            )
          else
            _ActivityMenu(
              isOwner: _isOwner,
              archived: activity.archived,
              hasOverview: overview != null,
              onSelected: _onMenu,
            ),
        ],
      ),
      floatingActionButton: _canEdit && overview != null
          ? FloatingActionButton.extended(
              onPressed: _addExpense,
              tooltip: tr('Ajouter une dépense'),
              icon: const Icon(Icons.add_rounded),
              label: Text(tr('Dépense')),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            Center(
              child: GestureDetector(
                onTap: _openLogo,
                child: Hero(
                  tag: 'activity-logo-${activity.id}',
                  child: ActivityLogo(activity: activity, size: 84),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              activity.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            Text(
              activity.type.label,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            if (_isOwner) ...[
              const SizedBox(height: 10),
              Center(
                child: _AccessCode(activityId: activity.id, repository: widget.repository),
              ),
            ],
            const SizedBox(height: 24),
            if (overview == null && _error != null)
              _ErrorBox(message: _error!, onRetry: _load)
            else if (overview == null)
              Padding(
                padding: EdgeInsets.only(top: 24),
                child: Center(child: LogoLoader(logoSize: 80, message: tr('Chargement des dépenses…'))),
              )
            else ...[
              _TotalCard(overview: overview),
              if (hasProgram(activity)) ...[
                const SizedBox(height: 12),
                _ProgramCard(count: _programCount, onTap: _openProgram),
              ],
              const SizedBox(height: 20),
              SegmentedButton<_Tab>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: _Tab.expenses, label: Text(tr('Dépenses ({0})', [_expenses.length]))),
                  ButtonSegment(value: _Tab.members, label: Text(tr('Membres ({0})', [overview.members.length]))),
                  ButtonSegment(value: _Tab.photos, label: Text(tr('Photos ({0})', [_photos.length]))),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
              const SizedBox(height: 16),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: switch (_tab) {
                  _Tab.expenses => _ExpenseList(
                    key: const ValueKey(_Tab.expenses),
                    expenses: _expenses,
                    members: overview.members,
                    activityCurrency: activity.currency,
                    currentUserId: widget.currentUserId,
                    canAdd: _canEdit,
                    onAdd: _addExpense,
                    onOpen: _openExpense,
                  ),
                  _Tab.members => _MemberList(
                    key: const ValueKey(_Tab.members),
                    overview: overview,
                    sort: _memberSort,
                    onSort: (sort) => setState(() => _memberSort = sort),
                    isOwner: _isOwner,
                    currentUserId: widget.currentUserId,
                    onManage: _manageMember,
                    onAvatar: _openAvatar,
                  ),
                  _Tab.photos => _PhotoGrid(
                    key: const ValueKey(_Tab.photos),
                    photos: _photos,
                    uploading: _uploading,
                    onAdd: _addPhotos,
                    onOpen: _openPhotos,
                  ),
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _Tab { expenses, members, photos }

enum _MenuAction { edit, archive, summary, chart, insights, delete }

/// Menu ⋮ de l'activité. « Supprimer » (ou « Quitter » pour un participant) est un bouton rouge en bas.
class _ActivityMenu extends StatelessWidget {
  const _ActivityMenu({
    required this.isOwner,
    required this.archived,
    required this.hasOverview,
    required this.onSelected,
  });

  final bool isOwner;
  final bool archived;

  /// Le résumé, les graphiques et les insights attendent le chargement des dépenses.
  final bool hasOverview;
  final ValueChanged<_MenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    PopupMenuItem<_MenuAction> item(_MenuAction value, IconData icon, String label, {bool enabled = true}) =>
        PopupMenuItem(
          value: value,
          enabled: enabled,
          child: Row(
            children: [
              Icon(icon, size: 22, color: enabled ? colors.primary : colors.onSurfaceVariant),
              const SizedBox(width: 14),
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          ),
        );
    return PopupMenuButton<_MenuAction>(
      tooltip: tr('Plus d\'actions'),
      icon: const Icon(Icons.more_vert_rounded),
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 250),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      onSelected: onSelected,
      itemBuilder: (_) => [
        if (isOwner) item(_MenuAction.edit, Icons.edit_outlined, tr('Modifier')),
        item(
          _MenuAction.archive,
          archived ? Icons.unarchive_outlined : Icons.archive_outlined,
          archived ? tr('Désarchiver') : tr('Archiver'),
        ),
        item(_MenuAction.summary, Icons.account_balance_wallet_outlined, tr('Résumé'), enabled: hasOverview),
        item(_MenuAction.chart, Icons.pie_chart_outline_rounded, tr('Graphique des dépenses'), enabled: hasOverview),
        item(_MenuAction.insights, Icons.insights_rounded, tr('Insights'), enabled: hasOverview),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _MenuAction.delete,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(color: colors.error, borderRadius: BorderRadius.circular(12)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(isOwner ? Icons.delete_outline_rounded : Icons.logout_rounded, size: 20, color: colors.onError),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    isOwner ? tr('Supprimer') : tr('Quitter l\'activité'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onError, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Tri de la liste des participants.
enum MemberSort {
  standard('Par défaut', Icons.sort_rounded),
  alphabetical('A → Z', Icons.sort_by_alpha_rounded),
  balanceLowest('Solde ↑', Icons.trending_down_rounded),
  balanceHighest('Solde ↓', Icons.trending_up_rounded);

  const MemberSort(this._label, this.icon);

  final String _label;

  String get label => _label.tr;
  final IconData icon;

  /// Par défaut : l'ordre du serveur (créateur, puis plus gros payeur).
  List<MemberSummary> apply(List<MemberSummary> members) {
    String key(MemberSummary m) => removeAccents(m.profile.displayName.toLowerCase());
    final sorted = List.of(members);
    switch (this) {
      case MemberSort.standard:
        break;
      case MemberSort.alphabetical:
        sorted.sort((a, b) => key(a).compareTo(key(b)));
      case MemberSort.balanceLowest:
        sorted.sort((a, b) => a.balance.compareTo(b.balance));
      case MemberSort.balanceHighest:
        sorted.sort((a, b) => b.balance.compareTo(a.balance));
    }
    return sorted;
  }
}

/// « Élodie » → « elodie » pour un tri alphabétique naturel.
String removeAccents(String text) {
  const from = 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿœæ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyyoa';
  final buffer = StringBuffer();
  for (final char in text.split('')) {
    final i = from.indexOf(char);
    buffer.write(i < 0 ? char : to[i]);
  }
  return buffer.toString();
}

class _ExpenseList extends StatelessWidget {
  const _ExpenseList({
    super.key,
    required this.expenses,
    required this.members,
    required this.activityCurrency,
    required this.currentUserId,
    required this.canAdd,
    required this.onAdd,
    required this.onOpen,
  });

  final List<Expense> expenses;
  final List<MemberSummary> members;
  final String activityCurrency;
  final String? currentUserId;
  final bool canAdd;
  final VoidCallback onAdd;
  final ValueChanged<Expense> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (expenses.isEmpty) {
      return _EmptyState(
        icon: Icons.receipt_long_outlined,
        text: tr('Aucune dépense pour le moment.'),
        action: canAdd
            ? FilledButton.tonalIcon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded),
                label: Text(tr('Ajouter une dépense')),
              )
            : null,
      );
    }
    final names = {for (final m in members) m.profile.id: m.profile.displayName};
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Column(
        children: [
          for (var i = 0; i < expenses.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 72, endIndent: 16),
            InkWell(
              onTap: () => onOpen(expenses[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: (expenses[i].pending ? colors.tertiary : colors.primary).withValues(alpha: 0.12),
                      child: Icon(
                        expenses[i].pending ? Icons.cloud_upload_outlined : Icons.receipt_long_rounded,
                        color: expenses[i].pending ? colors.tertiary : colors.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            expenses[i].name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          Text(
                            expenses[i].pending
                                ? tr('En attente d\'envoi · sera envoyée au retour du réseau')
                                : tr('Payé par {0}'
                                      ' · {1}', [expenses[i].paidBy == currentUserId ? 'toi' : names[expenses[i].paidBy] ?? tr('un ancien membre'), formatDate(expenses[i].date, relative: true)]),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatMoney(expenses[i].amount, expenses[i].currency),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        if (expenses[i].currency != activityCurrency)
                          Text(
                            '≈ ${formatMoney(expenses[i].convertedAmount, activityCurrency)}',
                            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MemberList extends StatelessWidget {
  const _MemberList({
    super.key,
    required this.overview,
    required this.sort,
    required this.onSort,
    required this.isOwner,
    required this.currentUserId,
    required this.onManage,
    required this.onAvatar,
  });

  final ActivityOverview overview;
  final MemberSort sort;
  final ValueChanged<MemberSort> onSort;
  final bool isOwner;
  final String? currentUserId;
  final ValueChanged<MemberSummary> onManage;
  final ValueChanged<MemberSummary> onAvatar;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final members = sort.apply(overview.members);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (overview.members.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                for (final option in MemberSort.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      avatar: Icon(option.icon, size: 18),
                      showCheckmark: false,
                      label: Text(option.label),
                      selected: option == sort,
                      onSelected: (_) => onSort(option),
                    ),
                  ),
              ],
            ),
          ),
        if (isOwner && overview.members.length > 1)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              tr('Touche un participant pour changer son rôle ou le retirer'),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          child: Column(
            children: [
              for (var i = 0; i < members.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 72, endIndent: 16),
                _MemberRow(
                  key: ValueKey(members[i].profile.id),
                  member: members[i],
                  currency: overview.currency,
                  isMe: members[i].profile.id == currentUserId,
                  onTap: isOwner && members[i].role != MemberRole.owner ? () => onManage(members[i]) : null,
                  onAvatarTap: () => onAvatar(members[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid({
    super.key,
    required this.photos,
    required this.uploading,
    required this.onAdd,
    required this.onOpen,
  });

  final List<Photo> photos;
  final (int, int)? uploading;
  final VoidCallback onAdd;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Tous les membres, spectateurs compris, peuvent ajouter des photos
    final tiles = [
      Material(
        color: colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: uploading != null ? null : onAdd,
          child: Center(
            child: switch (uploading) {
              (final sent, final total) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5, value: total > 1 ? sent / total : null),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$sent / $total',
                    style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              null => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_a_photo_outlined, color: colors.primary),
                  const SizedBox(height: 6),
                  Text(
                    tr('Ajouter'),
                    style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            },
          ),
        ),
      ),
      for (var i = 0; i < photos.length; i++)
        GestureDetector(
          onTap: () => onOpen(i),
          child: Hero(
            tag: 'activity-photo-${photos[i].id}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.network(
                photos[i].url,
                fit: BoxFit.cover,
                // Miniature : décodée à la taille affichée (3 par ligne), pas en 1600 px
                cacheWidth: 400,
                errorBuilder: (_, _, _) =>
                    Container(color: colors.surfaceContainerHighest, child: const Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.count(
          crossAxisCount: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: tiles,
        ),
        if (photos.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              tr('Partage les photos du voyage, les devis ou les souvenirs avec le groupe.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(icon, size: 40, color: colors.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

/// Code d'accès de l'owner : masqué par défaut, petit et discret, avec copie en un geste.
class _AccessCode extends StatefulWidget {
  const _AccessCode({required this.activityId, required this.repository});

  final String activityId;
  final ActivityRepository repository;

  @override
  State<_AccessCode> createState() => _AccessCodeState();
}

class _AccessCodeState extends State<_AccessCode> {
  late Future<String?> _code = widget.repository.joinCode(widget.activityId);
  var _visible = false;

  /// « ABCDEFGH » → « ABCD-EFGH ».
  static String _format(String code) => code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

  void _copy(String code) {
    Clipboard.setData(ClipboardData(text: code));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('Code copié : partage-le pour inviter quelqu\'un'))));
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return FutureBuilder<String?>(
      future: _code,
      builder: (context, snap) {
        final code = snap.data == null ? null : _format(snap.data!);
        if (snap.hasError) {
          return TextButton(
            onPressed: () => setState(() => _code = widget.repository.joinCode(widget.activityId)),
            child: Text(tr('Code indisponible · réessayer'), style: TextStyle(fontSize: 12)),
          );
        }
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(color: muted.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded, size: 14, color: muted),
              const SizedBox(width: 6),
              Text(
                code == null ? '…' : (_visible ? code : '••••-••••'),
                style: TextStyle(
                  fontSize: 13,
                  color: muted,
                  letterSpacing: 1.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              _SmallIcon(
                tooltip: _visible ? tr('Masquer le code') : tr('Afficher le code'),
                icon: _visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                onPressed: code == null ? null : () => setState(() => _visible = !_visible),
              ),
              _SmallIcon(
                tooltip: tr('Copier le code'),
                icon: Icons.copy_rounded,
                onPressed: code == null ? null : () => _copy(code),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SmallIcon extends StatelessWidget {
  const _SmallIcon({required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 16,
      visualDensity: VisualDensity.compact,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      icon: Icon(icon),
    );
  }
}

/// Accès au programme du voyage ou de la sortie (to-do list, votes, carte).
class _ProgramCard extends StatelessWidget {
  const _ProgramCard({required this.count, required this.onTap});

  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final n = count;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          child: Icon(Icons.map_outlined, color: colors.onPrimaryContainer),
        ),
        title: Text(tr('Programme'), style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          n == null
              ? tr('Activités à faire, votes et carte')
              : n == 0
              ? tr('Rien de prévu : ajoute la première activité')
              : tr('{0} activité{1} prévue{2} · votes et carte', [n, n > 1 ? 's' : '', n > 1 ? 's' : '']),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.overview});

  final ActivityOverview overview;

  @override
  Widget build(BuildContext context) {
    final count = overview.expenseCount;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, Color(0xFF14B8A6)],
        ),
      ),
      child: Column(
        children: [
          Text(tr('Total des dépenses'), style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 4),
          Text(
            formatMoney(overview.total, overview.currency),
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            count == 0 ? tr('Aucune dépense pour le moment') : tr('{0} dépense{1}', [count, count > 1 ? 's' : '']),
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.member,
    required this.currency,
    required this.isMe,
    this.onTap,
    this.onAvatarTap,
  });

  final MemberSummary member;
  final String currency;
  final bool isMe;

  /// Owner uniquement : ouvre la gestion du participant.
  final VoidCallback? onTap;

  /// Affiche la photo de profil en grand.
  final VoidCallback? onAvatarTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (roleLabel, roleColor) = switch (member.role) {
      MemberRole.owner => (tr('Créateur'), AppColors.accent),
      MemberRole.member => (tr('Membre'), colors.primary),
      MemberRole.viewer => (tr('Spectateur'), AppColors.neutral),
    };
    final balance = member.balance;
    final balanceColor = balance > 0
        ? AppColors.positive
        : balance < 0
        ? AppColors.negative
        : colors.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, onTap == null ? 16 : 6, 12),
        child: Row(
          children: [
            GestureDetector(
              onTap: onAvatarTap,
              child: Hero(
                tag: 'avatar-${member.profile.id}',
                child: UserAvatar(user: member.profile, size: 44),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMe ? '${member.profile.displayName} (toi)' : member.profile.displayName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: roleColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      roleLabel,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: roleColor),
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatMoney(member.totalPaid, currency),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                Text(tr('payé'), style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
                if (balance != 0)
                  Text(
                    '${balance > 0 ? '+' : ''}${formatMoney(balance, currency)}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: balanceColor),
                  ),
              ],
            ),
            if (onTap != null) ...[
              const SizedBox(width: 2),
              Icon(Icons.more_vert_rounded, size: 20, color: colors.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(Icons.wifi_off_rounded, size: 36, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton.tonal(onPressed: onRetry, child: Text(tr('Réessayer'))),
      ],
    );
  }
}
