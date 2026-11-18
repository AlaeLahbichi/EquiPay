import 'package:flutter/material.dart';

import '../../l10n/i18n.dart';
import '../../models/budget.dart';
import '../../services/activity_repository.dart';
import '../../services/budget_repository.dart';
import '../../utils/dates.dart';
import '../../utils/money.dart';
import '../../widgets/currency_field.dart';

/// « 1 234,50 » ou « 1234.5 » → 1234.5 (null si invalide ou ≤ 0).
double? parseAmount(String text) {
  final v = double.tryParse(text.replaceAll(RegExp(r'[\s  ]'), '').replaceAll(',', '.'));
  return v == null || v <= 0 ? null : v;
}

String _amountText(double? v) => v == null ? '' : v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2);

Future<bool> _sheet(BuildContext context, Widget child) async =>
    await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => child,
    ) ??
    false;

/// Mise en page commune des fenêtres du budget.
class BudgetSheet extends StatelessWidget {
  const BudgetSheet({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _AmountField extends StatelessWidget {
  const _AmountField({required this.controller, required this.currency, this.label, this.error, this.autofocus = false});

  final TextEditingController controller;
  final String currency;
  final String? label;
  final String? error;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: autofocus,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
    decoration: InputDecoration(
      labelText: label ?? tr('Montant'),
      suffixText: currencySymbol(currency),
      errorText: error,
      border: const OutlineInputBorder(),
    ),
  );
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.saving, required this.onPressed, this.label, this.error});

  final bool saving;
  final VoidCallback onPressed;
  final String? label;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(error!, style: TextStyle(color: colors.error), textAlign: TextAlign.center),
          ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: saving ? null : onPressed,
          child: saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                )
              : Text(label ?? tr('Enregistrer')),
        ),
      ],
    );
  }
}

class _CategoryPicker extends StatelessWidget {
  const _CategoryPicker({required this.kind, required this.value, required this.onChanged});

  final BudgetKind kind;
  final BudgetCategory value;
  final ValueChanged<BudgetCategory> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final c in BudgetCategory.of(kind))
        ChoiceChip(
          avatar: Icon(c.icon, size: 18, color: c.color),
          label: Text(c.label),
          selected: c == value,
          showCheckmark: false,
          selectedColor: c.color.withValues(alpha: 0.18),
          onSelected: (_) => onChanged(c),
        ),
    ],
  );
}

// -----------------------------------------------------------------------------
// Création du budget
// -----------------------------------------------------------------------------

/// Premier lancement : devise, salaire et jour de paie.
class BudgetSetup extends StatefulWidget {
  const BudgetSetup({super.key, required this.onDone, this.defaultCurrency});

  final VoidCallback onDone;
  final String? defaultCurrency;

  @override
  State<BudgetSetup> createState() => _BudgetSetupState();
}

class _BudgetSetupState extends State<BudgetSetup> {
  late String _currency = widget.defaultCurrency ?? 'MAD';
  final _salary = TextEditingController();
  var _payday = 28;
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _salary.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final salary = parseAmount(_salary.text);
    if (_salary.text.trim().isNotEmpty && salary == null) {
      setState(() => _error = tr('Montant invalide'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = BudgetRepository.instance;
      await repo.saveSettings(BudgetSettings(currency: _currency, payday: _payday));
      if (salary != null) {
        await repo.saveRecurring(
          BudgetRecurring(
            id: '',
            kind: BudgetKind.income,
            name: tr('Salaire'),
            amount: salary,
            category: BudgetCategory.salaire,
            day: _payday,
          ),
        );
      }
      widget.onDone();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        CircleAvatar(
          radius: 32,
          backgroundColor: colors.primary.withValues(alpha: 0.12),
          child: Icon(Icons.account_balance_wallet_rounded, color: colors.primary, size: 32),
        ),
        const SizedBox(height: 16),
        Text(tr('Gère ton salaire chaque mois'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          tr('Note ton salaire et tes charges fixes : EquiPay calcule ce qu\'il te reste à vivre et te rappelle ce qu\'il faut payer.'),
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 15),
        ),
        const SizedBox(height: 24),
        CurrencyField(value: _currency, onChanged: (c) => setState(() => _currency = c)),
        const SizedBox(height: 16),
        _AmountField(controller: _salary, currency: _currency, label: tr('Salaire net mensuel')),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          initialValue: _payday,
          decoration: InputDecoration(labelText: tr('Jour de paie'), border: const OutlineInputBorder()),
          items: [
            for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text(tr('Le {0} du mois', [d]))),
          ],
          onChanged: (d) => setState(() => _payday = d ?? 28),
        ),
        const SizedBox(height: 24),
        _SaveButton(saving: _saving, onPressed: _create, label: tr('Créer mon budget'), error: _error),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Mouvement (dépense ou revenu du mois)
// -----------------------------------------------------------------------------

/// Ajoute ou modifie un mouvement ; renvoie true s'il est enregistré.
Future<bool> showEntrySheet(
  BuildContext context, {
  required String currency,
  required DateTime month,
  BudgetEntry? entry,
  BudgetKind kind = BudgetKind.expense,
}) => _sheet(context, _EntrySheet(currency: currency, month: month, entry: entry, kind: entry?.kind ?? kind));

class _EntrySheet extends StatefulWidget {
  const _EntrySheet({required this.currency, required this.month, required this.kind, this.entry});

  final String currency;
  final DateTime month;
  final BudgetKind kind;
  final BudgetEntry? entry;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  late var _kind = widget.kind;
  late final _name = TextEditingController(text: widget.entry?.name ?? '');
  late final _amount = TextEditingController(text: _amountText(widget.entry?.amount));
  late var _category =
      widget.entry?.category ?? (widget.kind == BudgetKind.income ? BudgetCategory.prime : BudgetCategory.courses);
  late var _date = widget.entry?.date ?? _defaultDate();
  var _saving = false;
  String? _error;
  String? _amountError;

  DateTime _defaultDate() {
    final now = DateTime.now();
    if (now.year == widget.month.year && now.month == widget.month.month) return DateTime(now.year, now.month, now.day);
    return DateTime(widget.month.year, widget.month.month, 1);
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    setState(() => _amountError = amount == null ? tr('Montant invalide') : null);
    if (amount == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await BudgetRepository.instance.saveEntry(
        BudgetEntry(
          id: widget.entry?.id ?? '',
          kind: _kind,
          name: _name.text.trim().isEmpty ? _category.label : _name.text.trim(),
          amount: amount,
          category: _category,
          date: _date,
          recurringId: widget.entry?.recurringId,
          note: widget.entry?.note,
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 366)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    return BudgetSheet(
      title: widget.entry != null
          ? tr('Modifier')
          : _kind == BudgetKind.expense
          ? tr('Nouvelle dépense')
          : tr('Nouveau revenu'),
      children: [
        if (widget.entry == null) ...[
          SegmentedButton<BudgetKind>(
            segments: [
              ButtonSegment(
                value: BudgetKind.expense,
                label: Text(tr('Dépense')),
                icon: const Icon(Icons.south_west_rounded),
              ),
              ButtonSegment(
                value: BudgetKind.income,
                label: Text(tr('Revenu')),
                icon: const Icon(Icons.north_east_rounded),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() {
              _kind = s.first;
              _category = _kind == BudgetKind.income ? BudgetCategory.prime : BudgetCategory.courses;
            }),
          ),
          const SizedBox(height: 16),
        ],
        _AmountField(controller: _amount, currency: widget.currency, error: _amountError, autofocus: true),
        const SizedBox(height: 14),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: tr('Libellé (facultatif)'),
            hintText: _kind == BudgetKind.expense ? tr('Ex. Courses Marjane') : tr('Ex. Prime de fin d\'année'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        _CategoryPicker(kind: _kind, value: _category, onChanged: (c) => setState(() => _category = c)),
        const SizedBox(height: 10),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_rounded),
          title: Text(formatDate(_date)),
          trailing: TextButton(onPressed: _pickDate, child: Text(tr('Changer'))),
        ),
        const SizedBox(height: 8),
        _SaveButton(saving: _saving, onPressed: _save, error: _error),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Revenu ou charge qui revient chaque mois
// -----------------------------------------------------------------------------

Future<bool> showRecurringSheet(
  BuildContext context, {
  required String currency,
  BudgetRecurring? item,
  BudgetKind kind = BudgetKind.expense,
}) => _sheet(context, _RecurringSheet(currency: currency, item: item, kind: item?.kind ?? kind));

class _RecurringSheet extends StatefulWidget {
  const _RecurringSheet({required this.currency, required this.kind, this.item});

  final String currency;
  final BudgetKind kind;
  final BudgetRecurring? item;

  @override
  State<_RecurringSheet> createState() => _RecurringSheetState();
}

class _RecurringSheetState extends State<_RecurringSheet> {
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  late final _amount = TextEditingController(text: _amountText(widget.item?.amount));
  late var _category =
      widget.item?.category ?? (widget.kind == BudgetKind.income ? BudgetCategory.salaire : BudgetCategory.logement);
  late var _day = widget.item?.day ?? (widget.kind == BudgetKind.income ? 28 : 5);
  late var _active = widget.item?.active ?? true;
  var _saving = false;
  String? _error;
  String? _nameError;
  String? _amountError;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseAmount(_amount.text);
    setState(() {
      _amountError = amount == null ? tr('Montant invalide') : null;
      _nameError = _name.text.trim().isEmpty ? tr('Donne un nom') : null;
    });
    if (amount == null || _nameError != null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await BudgetRepository.instance.saveRecurring(
        BudgetRecurring(
          id: widget.item?.id ?? '',
          kind: widget.kind,
          name: _name.text.trim(),
          amount: amount,
          category: _category,
          day: _day,
          active: _active,
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  Future<void> _delete() async {
    setState(() => _saving = true);
    try {
      await BudgetRepository.instance.deleteRecurring(widget.item!.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final income = widget.kind == BudgetKind.income;
    return BudgetSheet(
      title: widget.item != null
          ? tr('Modifier')
          : income
          ? tr('Revenu chaque mois')
          : tr('Charge fixe chaque mois'),
      children: [
        TextField(
          controller: _name,
          autofocus: widget.item == null,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: tr('Nom'),
            hintText: income ? tr('Ex. Salaire') : tr('Ex. Loyer, Internet, Netflix'),
            errorText: _nameError,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        _AmountField(controller: _amount, currency: widget.currency, error: _amountError),
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          initialValue: _day,
          decoration: InputDecoration(
            labelText: income ? tr('Reçu le') : tr('À payer le'),
            border: const OutlineInputBorder(),
          ),
          items: [
            for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text(tr('Le {0} du mois', [d]))),
          ],
          onChanged: (d) => setState(() => _day = d ?? _day),
        ),
        const SizedBox(height: 14),
        _CategoryPicker(kind: widget.kind, value: _category, onChanged: (c) => setState(() => _category = c)),
        if (widget.item != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Active')),
            subtitle: Text(tr('Désactive-la si elle ne revient plus (l\'historique est gardé).')),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
        const SizedBox(height: 12),
        _SaveButton(saving: _saving, onPressed: _save, error: _error),
        if (widget.item != null)
          TextButton.icon(
            onPressed: _saving ? null : _delete,
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(tr('Supprimer')),
          ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Budget d'une catégorie, objectifs et réglages
// -----------------------------------------------------------------------------

Future<bool> showLimitSheet(
  BuildContext context, {
  required BudgetCategory category,
  required String currency,
  double? current,
}) => _sheet(context, _LimitSheet(category: category, currency: currency, current: current));

class _LimitSheet extends StatefulWidget {
  const _LimitSheet({required this.category, required this.currency, this.current});

  final BudgetCategory category;
  final String currency;
  final double? current;

  @override
  State<_LimitSheet> createState() => _LimitSheetState();
}

class _LimitSheetState extends State<_LimitSheet> {
  late final _amount = TextEditingController(text: _amountText(widget.current));
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save(double? amount) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await BudgetRepository.instance.setLimit(widget.category, amount);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BudgetSheet(
      title: tr('Budget {0}', [widget.category.label]),
      children: [
        Text(tr('Montant maximum à dépenser chaque mois dans cette catégorie. Tu es prévenu à 80 % et au dépassement.')),
        const SizedBox(height: 14),
        _AmountField(controller: _amount, currency: widget.currency, autofocus: true),
        const SizedBox(height: 16),
        _SaveButton(
          saving: _saving,
          error: _error,
          onPressed: () {
            final v = parseAmount(_amount.text);
            if (v == null) {
              setState(() => _error = tr('Montant invalide'));
            } else {
              _save(v);
            }
          },
        ),
        if (widget.current != null)
          TextButton(onPressed: _saving ? null : () => _save(null), child: Text(tr('Retirer le budget'))),
      ],
    );
  }
}

Future<bool> showGoalSheet(BuildContext context, {required String currency, BudgetGoal? goal}) =>
    _sheet(context, _GoalSheet(currency: currency, goal: goal));

class _GoalSheet extends StatefulWidget {
  const _GoalSheet({required this.currency, this.goal});

  final String currency;
  final BudgetGoal? goal;

  @override
  State<_GoalSheet> createState() => _GoalSheetState();
}

class _GoalSheetState extends State<_GoalSheet> {
  late final _name = TextEditingController(text: widget.goal?.name ?? '');
  late final _target = TextEditingController(text: _amountText(widget.goal?.target));
  final _add = TextEditingController();
  late var _deadline = widget.goal?.deadline;
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _add.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final target = parseAmount(_target.text);
    final add = _add.text.trim().isEmpty ? 0.0 : parseAmount(_add.text);
    if (_name.text.trim().isEmpty || target == null || add == null) {
      setState(() => _error = tr('Indique un nom et un montant valide'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await BudgetRepository.instance.saveGoal(
        BudgetGoal(
          id: widget.goal?.id ?? '',
          name: _name.text.trim(),
          target: target,
          saved: (widget.goal?.saved ?? 0) + add,
          deadline: _deadline,
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  Future<void> _delete() async {
    setState(() => _saving = true);
    try {
      await BudgetRepository.instance.deleteGoal(widget.goal!.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final goal = widget.goal;
    return BudgetSheet(
      title: goal == null ? tr('Nouvel objectif d\'épargne') : goal.name,
      children: [
        if (goal != null) ...[
          Text(
            tr('{0} épargnés sur {1}', [formatMoney(goal.saved, widget.currency), formatMoney(goal.target, widget.currency)]),
          ),
          const SizedBox(height: 12),
          _AmountField(controller: _add, currency: widget.currency, label: tr('Ajouter à l\'épargne'), autofocus: true),
          const SizedBox(height: 14),
        ],
        TextField(
          controller: _name,
          autofocus: goal == null,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: tr('Objectif'),
            hintText: tr('Ex. Vacances d\'été'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        _AmountField(controller: _target, currency: widget.currency, label: tr('Montant à atteindre')),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.flag_rounded),
          title: Text(_deadline == null ? tr('Sans échéance') : tr('Pour le {0}', [formatDate(_deadline!)])),
          trailing: TextButton(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _deadline ?? DateTime.now().add(const Duration(days: 180)),
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 3650)),
              );
              if (picked != null) setState(() => _deadline = picked);
            },
            child: Text(tr('Choisir')),
          ),
        ),
        _SaveButton(saving: _saving, onPressed: _save, error: _error),
        if (goal != null)
          TextButton.icon(
            onPressed: _saving ? null : _delete,
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(tr('Supprimer')),
          ),
      ],
    );
  }
}

Future<bool> showBudgetSettingsSheet(BuildContext context, BudgetSettings settings) =>
    _sheet(context, _SettingsSheet(settings: settings));

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.settings});

  final BudgetSettings settings;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late var _currency = widget.settings.currency;
  late var _payday = widget.settings.payday;
  late var _reminders = widget.settings.reminders;
  var _saving = false;
  String? _error;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await BudgetRepository.instance.saveSettings(
        BudgetSettings(currency: _currency, payday: _payday, reminders: _reminders),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BudgetSheet(
      title: tr('Réglages du budget'),
      children: [
        CurrencyField(value: _currency, onChanged: (c) => setState(() => _currency = c)),
        const SizedBox(height: 14),
        DropdownButtonFormField<int>(
          initialValue: _payday,
          decoration: InputDecoration(labelText: tr('Jour de paie'), border: const OutlineInputBorder()),
          items: [
            for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text(tr('Le {0} du mois', [d]))),
          ],
          onChanged: (d) => setState(() => _payday = d ?? _payday),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Rappels')),
          subtitle: Text(tr('Charges à payer 2 jours avant, et jour de paie')),
          value: _reminders,
          onChanged: (v) => setState(() => _reminders = v),
        ),
        const SizedBox(height: 8),
        _SaveButton(saving: _saving, onPressed: _save, error: _error),
      ],
    );
  }
}
