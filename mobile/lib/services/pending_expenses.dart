import 'package:flutter/material.dart';

import '../models/expense.dart';
import 'offline_store.dart';

/// Messages affichés hors d'une page précise (ex. dépenses envoyées au retour du réseau).
final appMessenger = GlobalKey<ScaffoldMessengerState>();

/// Dépense ajoutée ou modifiée sans réseau, en attente d'envoi.
class PendingExpense {
  const PendingExpense({
    required this.localId,
    required this.userId,
    required this.draft,
    required this.createdAt,
    this.expenseId,
  });

  /// Identifiant provisoire (« local-… »), utilisé tant que la dépense n'est pas envoyée.
  final String localId;

  /// Dépense existante modifiée hors ligne (null : nouvelle dépense).
  final String? expenseId;
  final String userId;
  final ExpenseDraft draft;
  final DateTime createdAt;

  /// Identifiant sous lequel l'app la montre.
  String get id => expenseId ?? localId;

  Expense toExpense() => Expense(
    id: id,
    pending: true,
    activityId: draft.activityId,
    createdBy: userId,
    paidBy: draft.paidBy,
    name: draft.name,
    description: draft.description.isEmpty ? null : draft.description,
    amount: draft.amount,
    currency: draft.currency,
    exchangeRate: draft.exchangeRate,
    date: draft.date,
    country: draft.country.isEmpty ? null : draft.country,
    city: draft.city.isEmpty ? null : draft.city,
    address: draft.address.isEmpty ? null : draft.address,
    createdAt: createdAt,
    shares: [for (final e in draft.shares.entries) ExpenseShare(userId: e.key, percentage: e.value)],
  );

  Map<String, Object?> toJson() => {
    'local_id': localId,
    'expense_id': expenseId,
    'user_id': userId,
    'created_at': createdAt.toIso8601String(),
    'draft': draft.toJson(),
  };

  factory PendingExpense.fromJson(Map<String, dynamic> j) => PendingExpense(
    localId: j['local_id'] as String,
    expenseId: j['expense_id'] as String?,
    userId: j['user_id'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
    draft: ExpenseDraft.fromJson(Map<String, dynamic>.from(j['draft'] as Map)),
  );
}

/// File d'attente des dépenses enregistrées hors ligne, gardée sur le téléphone.
class PendingExpenses extends ChangeNotifier {
  PendingExpenses._();

  static final instance = PendingExpenses._();

  static const _key = 'pending_expenses';

  List<PendingExpense>? _items;
  var _syncing = false;

  List<PendingExpense> get items => _items ??= _read();

  List<PendingExpense> _read() {
    try {
      final json = OfflineStore.instance.read(_key);
      if (json is! List) return [];
      return [for (final j in json) PendingExpense.fromJson(Map<String, dynamic>.from(j as Map))];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save() async {
    await OfflineStore.instance.write(_key, [for (final p in items) p.toJson()]);
    notifyListeners();
  }

  static bool isLocalId(String id) => id.startsWith('local-');

  List<PendingExpense> forActivity(String activityId) => [
    for (final p in items)
      if (p.draft.activityId == activityId) p,
  ];

  PendingExpense? byId(String id) {
    for (final p in items) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Ajoute (ou remplace, si la même dépense est déjà en attente) ; renvoie l'identifiant à montrer.
  Future<String> put(ExpenseDraft draft, {required String userId, String? expenseId}) async {
    final existing = expenseId == null ? null : byId(expenseId);
    final entry = PendingExpense(
      localId: existing?.localId ?? 'local-${DateTime.now().microsecondsSinceEpoch}',
      expenseId: existing?.expenseId ?? (expenseId != null && !isLocalId(expenseId) ? expenseId : null),
      userId: userId,
      draft: draft,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
    items.removeWhere((p) => p.localId == entry.localId);
    items.add(entry);
    await _save();
    return entry.id;
  }

  Future<void> remove(String id) async {
    items.removeWhere((p) => p.id == id);
    await _save();
  }

  Future<void> clear() async {
    _items = [];
    await OfflineStore.instance.remove(_key);
    notifyListeners();
  }

  /// Envoie les dépenses en attente de [userId], dans l'ordre. Celles refusées par le serveur
  /// (ex. participant retiré entre-temps) sont abandonnées ; sans réseau, on s'arrête là.
  Future<({int sent, int rejected})> sync(
    String userId,
    Future<void> Function(ExpenseDraft draft, String? expenseId) send,
  ) async {
    if (_syncing) return (sent: 0, rejected: 0);
    _syncing = true;
    var sent = 0;
    var rejected = 0;
    try {
      for (final p in items.where((p) => p.userId == userId).toList()) {
        try {
          await send(p.draft, p.expenseId);
          sent++;
        } catch (e) {
          if (isNetworkError(e)) break;
          rejected++;
        }
        items.removeWhere((x) => x.localId == p.localId);
        await _save();
      }
    } finally {
      _syncing = false;
    }
    return (sent: sent, rejected: rejected);
  }
}
