import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/expense.dart';
import 'package:mobile_app/services/offline_store.dart';
import 'package:mobile_app/services/pending_expenses.dart';

ExpenseDraft _draft(String name) => ExpenseDraft(
  activityId: 'a1',
  name: name,
  amount: 120,
  currency: 'MAD',
  date: DateTime(2026, 10, 29),
  paidBy: 'u1',
  shares: const {'u1': 50, 'u2': 50},
);

void main() {
  setUp(() async {
    OfflineStore.instance = OfflineStore();
    await PendingExpenses.instance.clear();
  });

  test('sans réseau, la dernière copie est renvoyée', () async {
    final store = OfflineStore.instance;
    expect(await store.fetch('k', () async => [1, 2], (j) => (j as List).length), 2);
    final r = await store.fetch('k', () async => throw const SocketException('coupé'), (j) => (j as List).length);
    expect(r, 2);
    // Erreur qui n'est pas due au réseau : relancée
    expect(store.fetch('k', () async => throw StateError('x'), (j) => j), throwsStateError);
  });

  test('hors ligne : la copie est utilisée sans attendre le serveur', () async {
    final store = OfflineStore.instance;
    await store.fetch('k', () async => 'copie', (j) => j);
    store.online = ValueNotifier(false);
    var called = false;
    final r = await store.fetch('k', () async {
      called = true;
      return 'serveur';
    }, (j) => j);
    expect(r, 'copie');
    expect(called, isFalse);
  });

  test('dépenses en attente : ajout, modification puis envoi au retour du réseau', () async {
    final pending = PendingExpenses.instance;
    final id = await pending.put(_draft('Taxi'), userId: 'u1');
    expect(PendingExpenses.isLocalId(id), isTrue);
    await pending.put(_draft('Taxi aéroport'), userId: 'u1', expenseId: id);
    expect(pending.forActivity('a1').single.toExpense().name, 'Taxi aéroport');
    expect(pending.forActivity('a1').single.toExpense().pending, isTrue);

    final sent = <String>[];
    final result = await pending.sync('u1', (draft, _) async => sent.add(draft.name));
    expect(sent, ['Taxi aéroport']);
    expect(result.sent, 1);
    expect(pending.items, isEmpty);
  });

  test('envoi interrompu par le réseau : la dépense reste en attente', () async {
    final pending = PendingExpenses.instance;
    await pending.put(_draft('Dîner'), userId: 'u1');
    final result = await pending.sync('u1', (_, _) async => throw const SocketException('coupé'));
    expect(result.sent, 0);
    expect(pending.items, hasLength(1));
    // Brouillon gardé en JSON sur le téléphone, relu à l'identique
    final copy = ExpenseDraft.fromJson(Map<String, dynamic>.from(_draft('Dîner').toJson()));
    expect(copy.shares, {'u1': 50.0, 'u2': 50.0});
    unawaited(pending.clear());
  });
}
