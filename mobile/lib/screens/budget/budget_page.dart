import 'package:flutter/material.dart';

import '../../l10n/i18n.dart';
import '../../models/budget.dart';
import '../../models/plan.dart';
import '../../services/account_service.dart';
import '../../services/activity_repository.dart';
import '../../services/auth_service.dart';
import '../../services/budget_repository.dart';
import '../../services/notification_service.dart';
import '../../utils/dates.dart';
import '../../utils/money.dart';
import '../../widgets/logo_loader.dart';
import '../plans/plans_page.dart';
import 'budget_sheets.dart';

/// Onglet Budget : salaire, charges fixes, dépenses du mois, budgets par catégorie et épargne.
class BudgetPage extends StatefulWidget {
  const BudgetPage({super.key, required this.auth, required this.onSignInRequested});

  final AuthService auth;
  final VoidCallback onSignInRequested;

  @override
  State<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends State<BudgetPage> {
  BudgetRepository get _repo => BudgetRepository.instance;

  String? _userId;
  var _loading = true;
  String? _error;
  BudgetSettings? _settings;
  List<BudgetRecurring> _recurring = const [];
  Map<BudgetCategory, double> _limits = const {};
  List<BudgetGoal> _goals = const [];
  BudgetMonth? _data;
  var _month = DateTime(DateTime.now().year, DateTime.now().month);

  /// Rappels programmés pour ces réglages et ces charges (on ne reprogramme qu'en cas de changement).
  String? _scheduled;

  Plan get _plan => AccountService.instance.state.value?.plan ?? Plan.free;
  String get _currency => _settings?.currency ?? 'MAD';
  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  @override
  void initState() {
    super.initState();
    widget.auth.user.addListener(_onAuth);
    _onAuth();
  }

  @override
  void dispose() {
    widget.auth.user.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    final id = widget.auth.user.value?.id;
    if (id == _userId) return;
    _userId = id;
    _settings = null;
    _data = null;
    _scheduled = null;
    if (id != null) _load();
  }

  Future<void> _load() async {
    if (_userId == null) return;
    setState(() {
      _loading = _data == null && _settings == null;
      _error = null;
    });
    try {
      final settings = await _repo.settings();
      if (settings == null) {
        if (mounted) {
          setState(() {
            _settings = null;
            _loading = false;
          });
        }
        return;
      }
      final (recurring, entries, limits, goals) = await (
        _repo.recurring(),
        _repo.entries(_month),
        _repo.limits(),
        _repo.goals(),
      ).wait;
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _recurring = recurring;
        _limits = limits;
        _goals = goals;
        _data = BudgetMonth(month: _month, entries: entries, recurring: recurring, limits: limits);
        _loading = false;
      });
      _scheduleReminders();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  void _scheduleReminders() {
    final s = _settings;
    final signature = [
      s?.payday,
      s?.reminders,
      s?.currency,
      for (final r in _recurring) '${r.id}${r.day}${r.amount}${r.active}${r.name}',
    ].join('|');
    if (signature == _scheduled) return;
    _scheduled = signature;
    NotificationService.instance.scheduleBudget(s, _recurring);
  }

  void _changeMonth(int delta) {
    final target = DateTime(_month.year, _month.month + delta);
    final now = DateTime.now();
    final back = (now.year - target.year) * 12 + now.month - target.month;
    final limit = _plan.budgetHistoryMonths;
    if (limit != null && back >= limit) {
      showUpgradeSheet(
        context,
        title: tr('Historique du budget'),
        message: tr('L\'offre Gratuite garde les {0} derniers mois. Passe à une offre supérieure pour tout ton historique.', [limit]),
      );
      return;
    }
    setState(() {
      _month = target;
      _data = null;
    });
    _load();
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _addEntry({BudgetEntry? entry, BudgetKind kind = BudgetKind.expense}) async {
    final before = _data;
    if (!await showEntrySheet(context, currency: _currency, month: _month, entry: entry, kind: kind)) return;
    await _load();
    // Budget de la catégorie bientôt atteint ou dépassé : notification
    final after = _data;
    if (before == null || after == null) return;
    for (final e in _limits.entries) {
      final was = before.spentIn(e.key) / e.value;
      final now = after.spentIn(e.key) / e.value;
      if ((was < 0.8 && now >= 0.8) || (was < 1 && now >= 1)) {
        await NotificationService.instance.budgetAlert(e.key, after.spentIn(e.key), e.value, _currency);
      }
    }
  }

  /// Marque une charge comme payée ou un revenu comme reçu (ou l'annule).
  Future<void> _togglePlanned(PlannedItem item) async {
    try {
      if (item.entry case final entry?) {
        await _repo.deleteEntry(entry.id);
      } else {
        final r = item.recurring;
        final now = DateTime.now();
        await _repo.saveEntry(
          BudgetEntry(
            id: '',
            kind: r.kind,
            name: r.name,
            amount: r.amount,
            category: r.category,
            date: _isCurrentMonth ? DateTime(now.year, now.month, now.day) : item.date,
            recurringId: r.id,
          ),
        );
      }
      await _load();
    } catch (e) {
      _toast(friendlyError(e));
    }
  }

  Future<void> _deleteEntry(BudgetEntry entry) async {
    try {
      await _repo.deleteEntry(entry.id);
      _toast(tr('Mouvement supprimé'));
    } catch (e) {
      _toast(friendlyError(e));
    }
    await _load();
  }

  bool _toolsAllowed(String title, String message) {
    if (_plan.hasBudgetTools) return true;
    showUpgradeSheet(context, title: title, message: message);
    return false;
  }

  Future<void> _editLimit(BudgetCategory category) async {
    if (!_toolsAllowed(
      tr('Budget par catégorie'),
      tr('Fixe un budget maximum par catégorie et sois prévenu avant de le dépasser, à partir de l\'offre Plus.'),
    )) {
      return;
    }
    if (await showLimitSheet(context, category: category, currency: _currency, current: _limits[category])) {
      await _load();
    }
  }

  Future<void> _editGoal([BudgetGoal? goal]) async {
    if (!_toolsAllowed(
      tr('Objectifs d\'épargne'),
      tr('Crée des objectifs d\'épargne et suis ta progression, à partir de l\'offre Plus.'),
    )) {
      return;
    }
    if (await showGoalSheet(context, currency: _currency, goal: goal)) await _load();
  }

  Future<void> _openRecurring() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RecurringPage(currency: _currency)),
    );
    await _load();
  }

  Future<void> _openSettings() async {
    final s = _settings;
    if (s != null && await showBudgetSettingsSheet(context, s)) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = widget.auth.user.value != null;
    final ready = signedIn && _settings != null && _data != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Budget')),
        actions: [
          if (ready) ...[
            IconButton(
              tooltip: tr('Charges et revenus'),
              onPressed: _openRecurring,
              icon: const Icon(Icons.event_repeat_rounded),
            ),
            IconButton(tooltip: tr('Réglages'), onPressed: _openSettings, icon: const Icon(Icons.tune_rounded)),
          ],
        ],
      ),
      floatingActionButton: ready
          ? FloatingActionButton.extended(
              heroTag: 'budget-add',
              onPressed: _addEntry,
              icon: const Icon(Icons.add_rounded),
              label: Text(tr('Ajouter')),
            )
          : null,
      body: ValueListenableBuilder<AccountState?>(
        valueListenable: AccountService.instance.state,
        builder: (context, _, _) => _body(signedIn),
      ),
    );
  }

  Widget _body(bool signedIn) {
    final colors = Theme.of(context).colorScheme;
    if (!signedIn) {
      return _Message(
        icon: Icons.account_balance_wallet_rounded,
        title: tr('Connecte-toi pour gérer ton budget'),
        action: FilledButton(onPressed: widget.onSignInRequested, child: Text(tr('Se connecter'))),
      );
    }
    if (_loading) return Center(child: LogoLoader(logoSize: 100, message: tr('Chargement du budget…')));
    if (_error != null && _data == null) {
      return _Message(
        icon: Icons.wifi_off_rounded,
        title: _error!,
        action: FilledButton.tonal(onPressed: _load, child: Text(tr('Réessayer'))),
      );
    }
    if (_settings == null) {
      return BudgetSetup(onDone: _load, defaultCurrency: AccountService.instance.state.value?.defaultCurrency);
    }
    final data = _data;
    if (data == null) return const Center(child: CircularProgressIndicator());
    final incomes = data.planned.where((p) => p.recurring.kind == BudgetKind.income).toList();
    final bills = data.planned.where((p) => p.recurring.kind == BudgetKind.expense).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        children: [
          _MonthSwitcher(month: _month, onChange: _changeMonth),
          const SizedBox(height: 8),
          _Summary(data: data, currency: _currency, current: _isCurrentMonth),
          const SizedBox(height: 22),
          _SectionHeader(
            title: tr('Ce mois-ci'),
            action: TextButton(onPressed: _openRecurring, child: Text(tr('Gérer'))),
          ),
          if (data.planned.isEmpty)
            _Hint(
              text: tr('Ajoute ton salaire et tes charges fixes (loyer, factures, abonnements) : ils reviendront chaque mois.'),
              action: tr('Ajouter'),
              onTap: _openRecurring,
            )
          else
            _Card(
              children: [
                for (final p in [...incomes, ...bills])
                  _PlannedTile(item: p, currency: _currency, onToggle: () => _togglePlanned(p)),
              ],
            ),
          const SizedBox(height: 22),
          _SectionHeader(
            title: tr('Par catégorie'),
            action: _plan.hasBudgetTools
                ? null
                : Icon(Icons.workspace_premium_rounded, color: Plan.plus.color, size: 20),
          ),
          if (data.byCategory.isEmpty)
            _Hint(text: tr('Tes dépenses du mois apparaîtront ici, rangées par catégorie.'))
          else
            _Card(
              children: [
                for (final e in data.byCategory)
                  _CategoryTile(
                    category: e.key,
                    spent: e.value,
                    limit: _limits[e.key],
                    currency: _currency,
                    onTap: () => _editLimit(e.key),
                  ),
              ],
            ),
          const SizedBox(height: 22),
          _SectionHeader(
            title: tr('Objectifs d\'épargne'),
            action: TextButton.icon(
              onPressed: _editGoal,
              icon: Icon(_plan.hasBudgetTools ? Icons.add_rounded : Icons.workspace_premium_rounded, size: 18),
              label: Text(tr('Ajouter')),
            ),
          ),
          if (_goals.isEmpty)
            _Hint(text: tr('Vacances, fonds d\'urgence, nouveau téléphone… fixe-toi un objectif et suis ta progression.'))
          else
            for (final g in _goals) _GoalCard(goal: g, currency: _currency, onTap: () => _editGoal(g)),
          const SizedBox(height: 22),
          _SectionHeader(title: tr('Mouvements')),
          if (data.entries.isEmpty)
            _Hint(text: tr('Aucun mouvement ce mois-ci. Touche « Ajouter » pour noter une dépense ou un revenu.'))
          else
            _Card(
              children: [
                for (final e in data.entries)
                  Dismissible(
                    key: ValueKey(e.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: colors.error,
                      alignment: AlignmentDirectional.centerEnd,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Icon(Icons.delete_outline_rounded, color: colors.onError),
                    ),
                    onDismissed: (_) => _deleteEntry(e),
                    child: _EntryTile(entry: e, currency: _currency, onTap: () => _addEntry(entry: e)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Charges et revenus réguliers
// -----------------------------------------------------------------------------

class RecurringPage extends StatefulWidget {
  const RecurringPage({super.key, required this.currency});

  final String currency;

  @override
  State<RecurringPage> createState() => _RecurringPageState();
}

class _RecurringPageState extends State<RecurringPage> {
  List<BudgetRecurring>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await BudgetRepository.instance.recurring();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _edit({BudgetRecurring? item, BudgetKind kind = BudgetKind.expense}) async {
    if (await showRecurringSheet(context, currency: widget.currency, item: item, kind: kind)) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final colors = Theme.of(context).colorScheme;
    Widget section(String title, BudgetKind kind) {
      final list = items!.where((i) => i.kind == kind).toList();
      final total = list.where((i) => i.active).fold<double>(0, (s, i) => s + i.amount);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeader(
            title: '$title · ${formatMoney(total, widget.currency)}',
            action: TextButton.icon(
              onPressed: () => _edit(kind: kind),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr('Ajouter')),
            ),
          ),
          if (list.isEmpty)
            _Hint(
              text: kind == BudgetKind.income
                  ? tr('Salaire, loyer perçu, pension…')
                  : tr('Loyer, électricité, internet, abonnements, crédit…'),
            )
          else
            _Card(
              children: [
                for (final i in list)
                  ListTile(
                    onTap: () => _edit(item: i),
                    leading: CircleAvatar(
                      backgroundColor: i.category.color.withValues(alpha: 0.14),
                      child: Icon(i.category.icon, color: i.category.color),
                    ),
                    title: Text(
                      i.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        decoration: i.active ? null : TextDecoration.lineThrough,
                      ),
                    ),
                    subtitle: Text(
                      i.active ? tr('Le {0} de chaque mois', [i.day]) : tr('Désactivée'),
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    trailing: Text(
                      formatMoney(i.amount, widget.currency),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 20),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('Charges et revenus'))),
      body: items == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  tr('Ce qui revient chaque mois. Tu seras prévenu 2 jours avant chaque charge à payer.'),
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                section(tr('Revenus'), BudgetKind.income),
                section(tr('Charges fixes'), BudgetKind.expense),
              ],
            ),
    );
  }
}

// -----------------------------------------------------------------------------
// Éléments de l'écran
// -----------------------------------------------------------------------------

class _MonthSwitcher extends StatelessWidget {
  const _MonthSwitcher({required this.month, required this.onChange});

  final DateTime month;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(onPressed: () => onChange(-1), icon: const Icon(Icons.chevron_left_rounded)),
        Expanded(
          child: Text(
            formatMonth(month),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          onPressed: () => onChange(1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.data, required this.currency, required this.current});

  final BudgetMonth data;
  final String currency;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final left = data.leftToLive;
    final days = data.daysLeft(DateTime.now());
    final negative = left < 0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: negative
              ? const [Color(0xFFDC2626), Color(0xFF9F1239)]
              : const [Color(0xFF0D9488), Color(0xFF0F766E)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('Reste à vivre'), style: const TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 4),
          Text(
            formatMoney(left, currency),
            style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900),
          ),
          if (current && days > 0 && left > 0)
            Text(
              tr('≈ {0} par jour pendant {1} jours', [formatMoney(left / days, currency), days]),
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _Figure(
                  icon: Icons.north_east_rounded,
                  label: tr('Revenus'),
                  value: formatMoney(data.income, currency),
                  extra: data.incomeToCome > 0 ? tr('+{0} à venir', [formatMoney(data.incomeToCome, currency)]) : null,
                ),
              ),
              Expanded(
                child: _Figure(
                  icon: Icons.south_west_rounded,
                  label: tr('Dépenses'),
                  value: formatMoney(data.spent, currency),
                  extra: data.billsToPay > 0 ? tr('+{0} à payer', [formatMoney(data.billsToPay, currency)]) : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.icon, required this.label, required this.value, this.extra});

  final IconData icon;
  final String label;
  final String value;
  final String? extra;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, color: Colors.white70, size: 16),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
      if (extra != null) Text(extra!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    ],
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6, left: 4),
    child: Row(
      children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
        ?action,
      ],
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    child: Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 68, endIndent: 16),
          children[i],
        ],
      ],
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text, this.action, this.onTap});

  final String text;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(child: Text(text, style: TextStyle(color: colors.onSurfaceVariant))),
          if (action != null) TextButton(onPressed: onTap, child: Text(action!)),
        ],
      ),
    );
  }
}

class _PlannedTile extends StatelessWidget {
  const _PlannedTile({required this.item, required this.currency, required this.onToggle});

  final PlannedItem item;
  final String currency;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final r = item.recurring;
    final income = r.kind == BudgetKind.income;
    final late = !item.done && DateTime.now().isAfter(item.date.add(const Duration(days: 1)));
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: r.category.color.withValues(alpha: 0.14),
        child: Icon(r.category.icon, color: r.category.color),
      ),
      title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        item.done
            ? (income ? tr('Reçu le {0}', [formatDate(item.entry!.date)]) : tr('Payé le {0}', [formatDate(item.entry!.date)]))
            : (income ? tr('Prévu le {0}', [formatDate(item.date)]) : tr('À payer le {0}', [formatDate(item.date)])),
        style: TextStyle(color: late ? colors.error : colors.onSurfaceVariant),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${income ? '+' : '−'}${formatMoney(r.amount, currency)}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: income ? const Color(0xFF059669) : null,
              decoration: item.done ? TextDecoration.lineThrough : null,
            ),
          ),
          IconButton(
            tooltip: item.done ? tr('Annuler') : (income ? tr('Marquer reçu') : tr('Marquer payé')),
            onPressed: onToggle,
            icon: Icon(
              item.done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
              color: item.done ? const Color(0xFF059669) : colors.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.spent,
    required this.limit,
    required this.currency,
    required this.onTap,
  });

  final BudgetCategory category;
  final double spent;
  final double? limit;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l = limit;
    final ratio = l == null ? null : spent / l;
    final color = ratio == null
        ? category.color
        : ratio >= 1
        ? colors.error
        : ratio >= 0.8
        ? const Color(0xFFEA580C)
        : category.color;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: category.color.withValues(alpha: 0.14),
              child: Icon(category.icon, color: category.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(category.label, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(
                        l == null ? formatMoney(spent, currency) : '${formatMoney(spent, currency)} / ${formatMoney(l, currency)}',
                        style: TextStyle(fontWeight: FontWeight.w700, color: ratio != null && ratio >= 1 ? colors.error : null),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ratio?.clamp(0, 1).toDouble() ?? 0,
                      minHeight: 6,
                      color: color,
                      backgroundColor: colors.surfaceContainerHighest,
                    ),
                  ),
                  if (l == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        tr('Touche pour fixer un budget'),
                        style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal, required this.currency, required this.onTap});

  final BudgetGoal goal;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final monthly = goal.monthlyNeeded(DateTime.now());
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(goal.reached ? Icons.emoji_events_rounded : Icons.savings_rounded, color: const Color(0xFF059669)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(goal.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                  Text('${(goal.progress * 100).round()} %', style: const TextStyle(fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: goal.progress,
                  minHeight: 8,
                  color: const Color(0xFF059669),
                  backgroundColor: colors.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                [
                  tr('{0} sur {1}', [formatMoney(goal.saved, currency), formatMoney(goal.target, currency)]),
                  if (goal.reached) tr('Objectif atteint 🎉'),
                  if (monthly != null) tr('{0} par mois', [formatMoney(monthly, currency)]),
                  if (goal.deadline != null && !goal.reached) tr('pour le {0}', [formatDate(goal.deadline!)]),
                ].join(' · '),
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.currency, required this.onTap});

  final BudgetEntry entry;
  final String currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final income = entry.kind == BudgetKind.income;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: entry.category.color.withValues(alpha: 0.14),
        child: Icon(entry.category.icon, color: entry.category.color),
      ),
      title: Text(entry.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('${entry.category.label} · ${formatDate(entry.date, relative: true)}'),
      trailing: Text(
        '${income ? '+' : '−'}${formatMoney(entry.amount, currency)}',
        style: TextStyle(fontWeight: FontWeight.w700, color: income ? const Color(0xFF059669) : null),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.action});

  final IconData icon;
  final String title;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: colors.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: colors.primary),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            action,
          ],
        ),
      ),
    );
  }
}
