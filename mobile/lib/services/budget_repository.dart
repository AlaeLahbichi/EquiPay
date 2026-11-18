import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/budget.dart';
import 'offline_store.dart';

/// Budget mensuel de l'utilisateur connecté.
abstract class BudgetRepository {
  /// Service de l'app (remplacé dans main.dart). Par défaut : en mémoire (tests).
  static BudgetRepository instance = MemoryBudgetRepository();

  /// null : budget pas encore créé.
  Future<BudgetSettings?> settings();

  Future<void> saveSettings(BudgetSettings settings);

  Future<List<BudgetRecurring>> recurring();

  /// Crée (id vide) ou modifie un revenu / une charge qui revient chaque mois.
  Future<void> saveRecurring(BudgetRecurring item);

  Future<void> deleteRecurring(String id);

  /// Mouvements du mois (les plus récents d'abord).
  Future<List<BudgetEntry>> entries(DateTime month);

  /// Crée (id vide) ou modifie un mouvement.
  Future<void> saveEntry(BudgetEntry entry);

  Future<void> deleteEntry(String id);

  /// Budget maximum par catégorie.
  Future<Map<BudgetCategory, double>> limits();

  /// null : retire le budget de la catégorie.
  Future<void> setLimit(BudgetCategory category, double? amount);

  Future<List<BudgetGoal>> goals();

  /// Crée (id vide) ou modifie un objectif.
  Future<void> saveGoal(BudgetGoal goal);

  Future<void> deleteGoal(String id);
}

class SupabaseBudgetRepository implements BudgetRepository {
  SupabaseBudgetRepository(this._client);

  final SupabaseClient _client;

  static const _timeout = Duration(seconds: 20);

  String _uid() {
    final user = _client.auth.currentUser;
    if (user == null) throw const AuthException('Connecte-toi pour gérer ton budget.');
    return user.id;
  }

  @override
  Future<BudgetSettings?> settings() {
    final uid = _uid();
    return OfflineStore.instance.fetch(
      'budget_settings:$uid',
      () => _client.from('budget_settings').select().eq('user_id', uid).maybeSingle().timeout(_timeout),
      (json) => json == null ? null : BudgetSettings.fromRow(Map<String, dynamic>.from(json as Map)),
    );
  }

  @override
  Future<void> saveSettings(BudgetSettings s) async {
    final uid = _uid();
    await _client.from('budget_settings').upsert({'user_id': uid, ...s.toRow()}).timeout(_timeout);
  }

  @override
  Future<List<BudgetRecurring>> recurring() {
    final uid = _uid();
    return OfflineStore.instance.fetch(
      'budget_recurring:$uid',
      () => _client
          .from('budget_recurring')
          .select()
          .eq('user_id', uid)
          .order('day')
          .order('created_at')
          .timeout(_timeout),
      (json) => jsonRows(json).map(BudgetRecurring.fromRow).toList(),
    );
  }

  @override
  Future<void> saveRecurring(BudgetRecurring item) => _save('budget_recurring', item.id, item.toRow());

  @override
  Future<void> deleteRecurring(String id) => _delete('budget_recurring', id);

  @override
  Future<List<BudgetEntry>> entries(DateTime month) {
    final uid = _uid();
    final from = DateTime(month.year, month.month);
    final to = DateTime(month.year, month.month + 1);
    return OfflineStore.instance.fetch(
      'budget_entries:$uid:${isoDate(from)}',
      () => _client
          .from('budget_entries')
          .select()
          .eq('user_id', uid)
          .gte('entry_date', isoDate(from))
          .lt('entry_date', isoDate(to))
          .order('entry_date', ascending: false)
          .order('created_at', ascending: false)
          .timeout(_timeout),
      (json) => jsonRows(json).map(BudgetEntry.fromRow).toList(),
    );
  }

  @override
  Future<void> saveEntry(BudgetEntry entry) async {
    try {
      await _save('budget_entries', entry.id, entry.toRow());
    } on PostgrestException catch (e) {
      if (e.code == '23505') throw const PostgrestException(message: 'Déjà réglé ce mois-ci.');
      rethrow;
    }
  }

  @override
  Future<void> deleteEntry(String id) => _delete('budget_entries', id);

  @override
  Future<Map<BudgetCategory, double>> limits() {
    final uid = _uid();
    return OfflineStore.instance.fetch(
      'budget_limits:$uid',
      () => _client.from('budget_limits').select('category, amount').eq('user_id', uid).timeout(_timeout),
      (json) => {
        for (final r in jsonRows(json))
          BudgetCategory.fromName(r['category'] as String?): (r['amount'] as num).toDouble(),
      },
    );
  }

  @override
  Future<void> setLimit(BudgetCategory category, double? amount) async {
    final uid = _uid();
    if (amount == null) {
      await _client.from('budget_limits').delete().eq('user_id', uid).eq('category', category.name).timeout(_timeout);
    } else {
      await _client
          .from('budget_limits')
          .upsert({'user_id': uid, 'category': category.name, 'amount': amount})
          .timeout(_timeout);
    }
  }

  @override
  Future<List<BudgetGoal>> goals() {
    final uid = _uid();
    return OfflineStore.instance.fetch(
      'budget_goals:$uid',
      () => _client.from('budget_goals').select().eq('user_id', uid).order('created_at').timeout(_timeout),
      (json) => jsonRows(json).map(BudgetGoal.fromRow).toList(),
    );
  }

  @override
  Future<void> saveGoal(BudgetGoal goal) => _save('budget_goals', goal.id, goal.toRow());

  @override
  Future<void> deleteGoal(String id) => _delete('budget_goals', id);

  Future<void> _save(String table, String id, Map<String, Object?> row) async {
    _uid();
    if (id.isEmpty) {
      await _client.from(table).insert(row).timeout(_timeout);
    } else {
      await _client.from(table).update(row).eq('id', id).timeout(_timeout);
    }
  }

  Future<void> _delete(String table, String id) async {
    _uid();
    await _client.from(table).delete().eq('id', id).timeout(_timeout);
  }
}

/// Budget gardé en mémoire (tests, aperçu).
class MemoryBudgetRepository implements BudgetRepository {
  BudgetSettings? _settings;
  final _recurring = <BudgetRecurring>[];
  final _entries = <BudgetEntry>[];
  final _limits = <BudgetCategory, double>{};
  final _goals = <BudgetGoal>[];
  var _next = 0;

  String _id(String id) => id.isEmpty ? 'm${_next++}' : id;

  @override
  Future<BudgetSettings?> settings() async => _settings;

  @override
  Future<void> saveSettings(BudgetSettings settings) async => _settings = settings;

  @override
  Future<List<BudgetRecurring>> recurring() async => [..._recurring]..sort((a, b) => a.day.compareTo(b.day));

  @override
  Future<void> saveRecurring(BudgetRecurring r) async {
    _recurring.removeWhere((x) => x.id == r.id);
    _recurring.add(
      BudgetRecurring(
        id: _id(r.id),
        kind: r.kind,
        name: r.name,
        amount: r.amount,
        category: r.category,
        day: r.day,
        active: r.active,
      ),
    );
  }

  @override
  Future<void> deleteRecurring(String id) async => _recurring.removeWhere((x) => x.id == id);

  @override
  Future<List<BudgetEntry>> entries(DateTime month) async =>
      _entries.where((e) => e.date.year == month.year && e.date.month == month.month).toList()
        ..sort((a, b) => b.date.compareTo(a.date));

  @override
  Future<void> saveEntry(BudgetEntry e) async {
    _entries.removeWhere((x) => x.id == e.id);
    _entries.add(
      BudgetEntry(
        id: _id(e.id),
        kind: e.kind,
        name: e.name,
        amount: e.amount,
        category: e.category,
        date: e.date,
        recurringId: e.recurringId,
        note: e.note,
      ),
    );
  }

  @override
  Future<void> deleteEntry(String id) async => _entries.removeWhere((x) => x.id == id);

  @override
  Future<Map<BudgetCategory, double>> limits() async => {..._limits};

  @override
  Future<void> setLimit(BudgetCategory category, double? amount) async =>
      amount == null ? _limits.remove(category) : _limits[category] = amount;

  @override
  Future<List<BudgetGoal>> goals() async => [..._goals];

  @override
  Future<void> saveGoal(BudgetGoal g) async {
    final i = _goals.indexWhere((x) => x.id == g.id);
    final goal = BudgetGoal(id: _id(g.id), name: g.name, target: g.target, saved: g.saved, deadline: g.deadline);
    i < 0 ? _goals.add(goal) : _goals[i] = goal;
  }

  @override
  Future<void> deleteGoal(String id) async => _goals.removeWhere((x) => x.id == id);
}
