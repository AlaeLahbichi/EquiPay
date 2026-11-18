import 'package:flutter/material.dart';

import '../l10n/i18n.dart';

enum BudgetKind { income, expense }

/// Catégories du budget (fixes : rien n'est créé dans la base).
enum BudgetCategory {
  logement('Logement', Icons.home_rounded, Color(0xFF0D9488)),
  courses('Courses', Icons.shopping_cart_rounded, Color(0xFF16A34A)),
  transport('Transport', Icons.directions_car_rounded, Color(0xFF2563EB)),
  factures('Factures', Icons.receipt_long_rounded, Color(0xFF0891B2)),
  abonnements('Abonnements', Icons.subscriptions_rounded, Color(0xFF7C3AED)),
  sante('Santé', Icons.local_hospital_rounded, Color(0xFFDC2626)),
  restaurants('Restaurants', Icons.restaurant_rounded, Color(0xFFEA580C)),
  loisirs('Loisirs', Icons.sports_esports_rounded, Color(0xFFDB2777)),
  shopping('Shopping', Icons.shopping_bag_rounded, Color(0xFFC026D3)),
  education('Éducation', Icons.school_rounded, Color(0xFF4F46E5)),
  famille('Famille', Icons.family_restroom_rounded, Color(0xFFCA8A04)),
  credit('Crédit', Icons.credit_card_rounded, Color(0xFF475569)),
  epargne('Épargne', Icons.savings_rounded, Color(0xFF059669)),
  autre('Autre', Icons.more_horiz_rounded, Color(0xFF64748B)),
  // Revenus
  salaire('Salaire', Icons.payments_rounded, Color(0xFF059669), income: true),
  prime('Prime', Icons.emoji_events_rounded, Color(0xFFCA8A04), income: true),
  freelance('Freelance', Icons.laptop_mac_rounded, Color(0xFF2563EB), income: true),
  loyerPercu('Loyer perçu', Icons.apartment_rounded, Color(0xFF0D9488), income: true),
  aide('Aides', Icons.volunteer_activism_rounded, Color(0xFFDB2777), income: true),
  autreRevenu('Autre revenu', Icons.add_card_rounded, Color(0xFF64748B), income: true);

  const BudgetCategory(this._label, this.icon, this.color, {this.income = false});

  final String _label;
  final IconData icon;
  final Color color;
  final bool income;

  String get label => _label.tr;

  static List<BudgetCategory> of(BudgetKind kind) =>
      values.where((c) => c.income == (kind == BudgetKind.income)).toList();

  static BudgetCategory fromName(String? name) =>
      values.firstWhere((c) => c.name == name, orElse: () => BudgetCategory.autre);
}

/// Réglages du budget de l'utilisateur.
class BudgetSettings {
  const BudgetSettings({required this.currency, required this.payday, this.reminders = true});

  final String currency;

  /// Jour de paie (1 à 31 ; adapté aux mois plus courts).
  final int payday;

  /// Rappels des charges à payer et du jour de paie.
  final bool reminders;

  factory BudgetSettings.fromRow(Map<String, dynamic> r) => BudgetSettings(
    currency: (r['currency'] as String).trim(),
    payday: (r['payday'] as num).toInt(),
    reminders: r['reminders'] as bool? ?? true,
  );

  Map<String, Object?> toRow() => {'currency': currency, 'payday': payday, 'reminders': reminders};
}

/// Revenu ou charge qui revient chaque mois (salaire, loyer, abonnement…).
class BudgetRecurring {
  const BudgetRecurring({
    required this.id,
    required this.kind,
    required this.name,
    required this.amount,
    required this.category,
    required this.day,
    this.active = true,
  });

  final String id;
  final BudgetKind kind;
  final String name;
  final double amount;
  final BudgetCategory category;

  /// Jour du mois (paie, prélèvement…).
  final int day;
  final bool active;

  /// Date dans le mois donné (le 31 devient le 30 ou le 28 selon le mois).
  DateTime dateIn(DateTime month) {
    final last = DateTime(month.year, month.month + 1, 0).day;
    return DateTime(month.year, month.month, day.clamp(1, last));
  }

  factory BudgetRecurring.fromRow(Map<String, dynamic> r) => BudgetRecurring(
    id: r['id'] as String,
    kind: BudgetKind.values.byName(r['kind'] as String),
    name: r['name'] as String,
    amount: _num(r['amount']),
    category: BudgetCategory.fromName(r['category'] as String?),
    day: (r['day'] as num).toInt(),
    active: r['active'] as bool? ?? true,
  );

  Map<String, Object?> toRow() => {
    'kind': kind.name,
    'name': name.trim(),
    'amount': amount,
    'category': category.name,
    'day': day,
    'active': active,
  };
}

/// Mouvement du mois : dépense, revenu, charge payée ou salaire reçu.
class BudgetEntry {
  const BudgetEntry({
    required this.id,
    required this.kind,
    required this.name,
    required this.amount,
    required this.category,
    required this.date,
    this.recurringId,
    this.note,
  });

  final String id;
  final BudgetKind kind;
  final String name;
  final double amount;
  final BudgetCategory category;
  final DateTime date;

  /// Charge ou revenu régulier réglé par ce mouvement.
  final String? recurringId;
  final String? note;

  factory BudgetEntry.fromRow(Map<String, dynamic> r) => BudgetEntry(
    id: r['id'] as String,
    kind: BudgetKind.values.byName(r['kind'] as String),
    name: r['name'] as String,
    amount: _num(r['amount']),
    category: BudgetCategory.fromName(r['category'] as String?),
    date: DateTime.parse(r['entry_date'] as String),
    recurringId: r['recurring_id'] as String?,
    note: r['note'] as String?,
  );

  Map<String, Object?> toRow() => {
    'kind': kind.name,
    'name': name.trim(),
    'amount': amount,
    'category': category.name,
    'entry_date': isoDate(date),
    'recurring_id': recurringId,
    'note': (note ?? '').trim().isEmpty ? null : note!.trim(),
  };
}

/// Objectif d'épargne.
class BudgetGoal {
  const BudgetGoal({required this.id, required this.name, required this.target, required this.saved, this.deadline});

  final String id;
  final String name;
  final double target;
  final double saved;
  final DateTime? deadline;

  double get progress => target <= 0 ? 0 : (saved / target).clamp(0, 1).toDouble();
  bool get reached => saved >= target;

  /// Somme à mettre de côté chaque mois pour atteindre l'objectif à temps (null sans échéance).
  double? monthlyNeeded(DateTime now) {
    final d = deadline;
    if (d == null || reached) return null;
    final months = (d.year - now.year) * 12 + d.month - now.month;
    return (target - saved) / (months < 1 ? 1 : months);
  }

  factory BudgetGoal.fromRow(Map<String, dynamic> r) => BudgetGoal(
    id: r['id'] as String,
    name: r['name'] as String,
    target: _num(r['target']),
    saved: _num(r['saved']),
    deadline: r['deadline'] == null ? null : DateTime.parse(r['deadline'] as String),
  );

  Map<String, Object?> toRow() => {
    'name': name.trim(),
    'target': target,
    'saved': saved,
    'deadline': deadline == null ? null : isoDate(deadline!),
  };
}

/// Ligne du mois pour une charge ou un revenu régulier : déjà réglé ou encore à venir.
class PlannedItem {
  const PlannedItem({required this.recurring, required this.date, this.entry});

  final BudgetRecurring recurring;
  final DateTime date;

  /// Mouvement qui l'a réglé (null : pas encore payé / reçu).
  final BudgetEntry? entry;

  bool get done => entry != null;
}

/// Calculs d'un mois : revenus, dépenses, reste à vivre, dépenses par catégorie.
class BudgetMonth {
  BudgetMonth({
    required DateTime month,
    required this.entries,
    required List<BudgetRecurring> recurring,
    this.limits = const {},
  }) : month = DateTime(month.year, month.month) {
    final byRecurring = {
      for (final e in entries)
        if (e.recurringId != null) e.recurringId!: e,
    };
    planned = [
      for (final r in recurring)
        if (r.active || byRecurring.containsKey(r.id))
          PlannedItem(recurring: r, date: r.dateIn(this.month), entry: byRecurring[r.id]),
    ]..sort((a, b) => a.date.compareTo(b.date));
  }

  final DateTime month;
  final List<BudgetEntry> entries;
  final Map<BudgetCategory, double> limits;
  late final List<PlannedItem> planned;

  double _sum(BudgetKind kind) => entries.where((e) => e.kind == kind).fold(0, (s, e) => s + e.amount);

  double _pending(BudgetKind kind) =>
      planned.where((p) => !p.done && p.recurring.kind == kind).fold(0, (s, p) => s + p.recurring.amount);

  /// Revenus reçus ce mois-ci.
  double get income => _sum(BudgetKind.income);

  /// Dépenses faites ce mois-ci.
  double get spent => _sum(BudgetKind.expense);

  /// Revenus réguliers pas encore reçus (salaire à venir…).
  double get incomeToCome => _pending(BudgetKind.income);

  /// Charges fixes pas encore payées.
  double get billsToPay => _pending(BudgetKind.expense);

  /// Ce qui restera à la fin du mois : revenus (reçus et à venir) − dépenses (faites et charges à venir).
  double get leftToLive => income + incomeToCome - spent - billsToPay;

  /// Jours restants dans le mois (aujourd'hui compris), 0 pour un mois passé.
  int daysLeft(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final end = DateTime(month.year, month.month + 1, 0);
    if (today.isAfter(end)) return 0;
    final start = today.isBefore(month) ? month : today;
    return end.difference(start).inDays + 1;
  }

  /// Dépenses par catégorie, de la plus grosse à la plus petite.
  List<MapEntry<BudgetCategory, double>> get byCategory {
    final totals = <BudgetCategory, double>{};
    for (final e in entries.where((e) => e.kind == BudgetKind.expense)) {
      totals[e.category] = (totals[e.category] ?? 0) + e.amount;
    }
    for (final c in limits.keys) {
      totals.putIfAbsent(c, () => 0);
    }
    return totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  }

  double spentIn(BudgetCategory category) => entries
      .where((e) => e.kind == BudgetKind.expense && e.category == category)
      .fold(0, (s, e) => s + e.amount);
}

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

double _num(Object? v) => (v as num?)?.toDouble() ?? double.tryParse('$v') ?? 0;
