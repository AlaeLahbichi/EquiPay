import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/trip_item.dart';
import 'offline_store.dart';
import '../l10n/i18n.dart';

/// Programme d'un voyage ou d'une sortie : activités à faire et votes pour / contre.
abstract class TripRepository {
  /// Service utilisé par l'app (remplacé par la version Supabase dans main.dart).
  static TripRepository instance = MemoryTripRepository();

  /// Éléments du programme, avec les votes et le vote de l'utilisateur connecté.
  Future<List<TripItem>> items(String activityId);

  Future<void> add(String activityId, TripItemDraft draft);

  Future<void> update(TripItem item, TripItemDraft draft);

  Future<void> delete(TripItem item);

  Future<void> setDone(TripItem item, bool done);

  /// Enregistre la position trouvée pour un élément qui n'en avait pas (pour la carte).
  Future<void> setPosition(TripItem item, double latitude, double longitude);

  /// Applique le trajet proposé : jour (s'il est donné) et heure de l'élément.
  Future<void> schedule(TripItem item, {DateTime? date, required TimeOfDay time});

  /// 1 pour, -1 contre, 0 pour retirer son vote.
  Future<void> vote(TripItem item, int vote);

  /// Émet un événement quand un élément ou un vote du programme change.
  Stream<void> changes(String activityId);
}

class SupabaseTripRepository implements TripRepository {
  SupabaseTripRepository(this._client);

  final SupabaseClient _client;

  static const _timeout = Duration(seconds: 20);

  String _userId() {
    final user = _client.auth.currentUser;
    if (user == null) throw AuthException(tr('Connecte-toi pour voir le programme.'));
    return user.id;
  }

  @override
  Future<List<TripItem>> items(String activityId) async {
    final userId = _userId();
    return OfflineStore.instance.fetch(
      'trip:$activityId',
      () async {
        final (rows, votes) = await (
          _client
              .from('trip_items')
              .select()
              .eq('activity_id', activityId)
              .order('planned_on', ascending: true, nullsFirst: false)
              .order('planned_at', ascending: true, nullsFirst: false)
              .order('created_at')
              .timeout(_timeout),
          _client.from('trip_votes').select('item_id, user_id, vote').eq('activity_id', activityId).timeout(_timeout),
        ).wait;
        return {'items': rows, 'votes': votes};
      },
      (json) {
        final data = json as Map;
        final votes = jsonRows(data['votes']);
        return [for (final r in jsonRows(data['items'])) TripItem.fromRow(r, votes: votes, userId: userId)];
      },
    );
  }

  @override
  Future<void> add(String activityId, TripItemDraft draft) async {
    _userId();
    await _client.from('trip_items').insert({'activity_id': activityId, ...draft.toRow()}).timeout(_timeout);
  }

  @override
  Future<void> update(TripItem item, TripItemDraft draft) async {
    final rows = await _client
        .from('trip_items')
        .update(draft.toRow())
        .eq('id', item.id)
        .select('id')
        .timeout(_timeout);
    if (rows.isEmpty) {
      throw PostgrestException(message: tr('Seul l\'auteur ou le créateur peut modifier cet élément'));
    }
  }

  @override
  Future<void> delete(TripItem item) async {
    final rows = await _client.from('trip_items').delete().eq('id', item.id).select('id').timeout(_timeout);
    if (rows.isEmpty) {
      throw PostgrestException(message: tr('Seul l\'auteur ou le créateur peut supprimer cet élément'));
    }
  }

  @override
  Future<void> setDone(TripItem item, bool done) async {
    final rows = await _client
        .from('trip_items')
        .update({'done': done})
        .eq('id', item.id)
        .select('id')
        .timeout(_timeout);
    if (rows.isEmpty) throw PostgrestException(message: tr('Seul l\'auteur ou le créateur peut cocher cet élément'));
  }

  @override
  Future<void> setPosition(TripItem item, double latitude, double longitude) async {
    await _client
        .from('trip_items')
        .update({'latitude': latitude, 'longitude': longitude})
        .eq('id', item.id)
        .timeout(_timeout);
  }

  @override
  Future<void> schedule(TripItem item, {DateTime? date, required TimeOfDay time}) async {
    final draft = TripItemDraft(name: item.name, date: date ?? item.date, time: time).toRow();
    final rows = await _client
        .from('trip_items')
        .update({'planned_on': draft['planned_on'], 'planned_at': draft['planned_at']})
        .eq('id', item.id)
        .select('id')
        .timeout(_timeout);
    if (rows.isEmpty) throw PostgrestException(message: tr('Seul le créateur peut appliquer ce programme'));
  }

  @override
  Future<void> vote(TripItem item, int vote) async {
    final userId = _userId();
    if (vote == 0) {
      await _client.from('trip_votes').delete().eq('item_id', item.id).eq('user_id', userId).timeout(_timeout);
      return;
    }
    await _client
        .from('trip_votes')
        .upsert({
          'item_id': item.id,
          'activity_id': item.activityId,
          'user_id': userId,
          'vote': vote,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .timeout(_timeout);
  }

  @override
  Stream<void> changes(String activityId) {
    final controller = StreamController<void>();
    RealtimeChannel? channel;
    controller.onListen = () {
      final filter = PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'activity_id', value: activityId);
      channel = _client.channel('trip:$activityId');
      for (final table in ['trip_items', 'trip_votes']) {
        channel!.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          filter: filter,
          callback: (_) => controller.add(null),
        );
      }
      channel!.subscribe();
    };
    controller.onCancel = () async {
      if (channel != null) await _client.removeChannel(channel!);
    };
    return controller.stream;
  }
}

/// Programme gardé en mémoire : sert par défaut (tests, aperçu) avant le branchement à Supabase.
class MemoryTripRepository implements TripRepository {
  MemoryTripRepository({this.userId = 'u1'});

  final String userId;
  final _items = <String, List<TripItem>>{};
  final _votes = <String, Map<String, int>>{}; // élément → (utilisateur → vote)
  final _changes = StreamController<void>.broadcast();
  var _nextId = 1;

  /// Ajoute un vote d'un autre participant (tests).
  void addVote(String itemId, String user, int vote) {
    (_votes[itemId] ??= {})[user] = vote;
    _changes.add(null);
  }

  TripItem _withVotes(TripItem item) {
    final votes = _votes[item.id] ?? const {};
    return item.copyWith(
      upVotes: votes.values.where((v) => v > 0).length,
      downVotes: votes.values.where((v) => v < 0).length,
      myVote: votes[userId] ?? 0,
    );
  }

  @override
  Future<List<TripItem>> items(String activityId) async => [
    for (final item in _items[activityId] ?? const <TripItem>[]) _withVotes(item),
  ];

  TripItem _build(String id, String activityId, String createdBy, TripItemDraft d, {bool done = false}) => TripItem(
    id: id,
    activityId: activityId,
    createdBy: createdBy,
    name: d.name.trim(),
    place: TripItemDraft.clean(d.place),
    address: TripItemDraft.clean(d.address),
    date: d.date,
    time: d.time,
    latitude: d.latitude,
    longitude: d.longitude,
    done: done,
  );

  @override
  Future<void> add(String activityId, TripItemDraft draft) async {
    (_items[activityId] ??= []).add(_build('t${_nextId++}', activityId, userId, draft));
    _changes.add(null);
  }

  void _replace(TripItem item, TripItem Function(TripItem) change) {
    final list = _items[item.activityId]!;
    final i = list.indexWhere((e) => e.id == item.id);
    list[i] = change(list[i]);
    _changes.add(null);
  }

  @override
  Future<void> update(TripItem item, TripItemDraft draft) async =>
      _replace(item, (old) => _build(old.id, old.activityId, old.createdBy, draft, done: old.done));

  @override
  Future<void> delete(TripItem item) async {
    _items[item.activityId]?.removeWhere((e) => e.id == item.id);
    _votes.remove(item.id);
    _changes.add(null);
  }

  @override
  Future<void> setDone(TripItem item, bool done) async => _replace(item, (old) => old.copyWith(done: done));

  @override
  Future<void> setPosition(TripItem item, double latitude, double longitude) async =>
      _replace(item, (old) => old.copyWith(latitude: latitude, longitude: longitude));

  @override
  Future<void> schedule(TripItem item, {DateTime? date, required TimeOfDay time}) async => _replace(
    item,
    (old) => TripItem(
      id: old.id,
      activityId: old.activityId,
      createdBy: old.createdBy,
      name: old.name,
      place: old.place,
      address: old.address,
      date: date ?? old.date,
      time: time,
      latitude: old.latitude,
      longitude: old.longitude,
      done: old.done,
    ),
  );

  @override
  Future<void> vote(TripItem item, int vote) async {
    final votes = _votes[item.id] ??= {};
    if (vote == 0) {
      votes.remove(userId);
    } else {
      votes[userId] = vote;
    }
    _changes.add(null);
  }

  @override
  Stream<void> changes(String activityId) => _changes.stream;
}
