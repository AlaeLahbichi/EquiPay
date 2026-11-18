import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/join_request.dart';

/// Changement reçu en temps réel sur une demande.
class RequestChange {
  const RequestChange({required this.id, required this.userId, required this.status, required this.inserted});

  final String id;

  /// Auteur de la demande.
  final String userId;
  final JoinRequestStatus status;

  /// true : nouvelle demande ; false : demande mise à jour (réponse, annulation).
  final bool inserted;
}

abstract class RequestRepository {
  /// Demandes envoyées par l'utilisateur et demandes reçues pour ses activités.
  Future<List<JoinRequest>> myRequests();

  /// Réponse de l'owner : la personne devient membre si [accept].
  Future<void> respond(String requestId, {required bool accept});

  /// Le demandeur retire sa demande en attente.
  Future<void> cancel(String requestId);

  /// Le demandeur a vu les réponses à ses demandes.
  Future<void> markSeen();

  Stream<RequestChange> changes(String userId);
}

class SupabaseRequestRepository implements RequestRepository {
  SupabaseRequestRepository(this._client);

  final SupabaseClient _client;

  static const _timeout = Duration(seconds: 20);

  @override
  Future<List<JoinRequest>> myRequests() async {
    final rows = await _client
        .from('join_requests')
        .select('*, profiles(id, email, full_name, username, avatar_url)')
        .order('created_at', ascending: false)
        .limit(100)
        .timeout(_timeout);
    return rows.map(JoinRequest.fromRow).toList();
  }

  @override
  Future<void> respond(String requestId, {required bool accept}) =>
      _client.rpc('respond_join_request', params: {'p_request': requestId, 'p_accept': accept}).timeout(_timeout);

  @override
  Future<void> cancel(String requestId) =>
      _client.rpc('cancel_join_request', params: {'p_request': requestId}).timeout(_timeout);

  @override
  Future<void> markSeen() => _client.rpc('mark_join_requests_seen').timeout(_timeout);

  // Les règles RLS filtrent : on ne reçoit que ses demandes et celles de ses activités
  @override
  Stream<RequestChange> changes(String userId) {
    final controller = StreamController<RequestChange>();
    RealtimeChannel? channel;
    controller.onListen = () {
      channel = _client
          .channel('join_requests:$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'join_requests',
            callback: (payload) {
              final row = payload.newRecord;
              if (row.isEmpty) return; // suppression (compte supprimé…)
              controller.add(
                RequestChange(
                  id: row['id'] as String,
                  userId: row['user_id'] as String,
                  status: JoinRequestStatus.values.byName(row['status'] as String),
                  inserted: payload.eventType == PostgresChangeEvent.insert,
                ),
              );
            },
          )
          .subscribe();
    };
    controller.onCancel = () async {
      if (channel != null) await _client.removeChannel(channel!);
    };
    return controller.stream;
  }
}
