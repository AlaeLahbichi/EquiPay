import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/join_request.dart';
import '../models/user_profile.dart';
import 'auth_service.dart';
import 'request_repository.dart';
import '../l10n/i18n.dart';

/// Message affiché au destinataire quand une demande change (nouvelle demande, réponse…).
class RequestNotice {
  const RequestNotice(this.message, {required this.incoming});

  final String message;

  /// true : concerne une demande reçue (côté owner).
  final bool incoming;
}

/// État de l'onglet Requests pour l'utilisateur connecté, tenu à jour en temps réel.
class RequestsController extends ChangeNotifier {
  RequestsController({required this.repository, required this.auth}) {
    auth.user.addListener(_onAuthChange);
    _onAuthChange();
  }

  final RequestRepository repository;
  final AuthService auth;

  final _notices = StreamController<RequestNotice>.broadcast();
  StreamSubscription<RequestChange>? _changes;
  String? _userId;
  var _markingSeen = false;

  List<JoinRequest> _all = const [];
  bool loaded = false;
  String? error;

  /// Demandes reçues pour mes activités (les demandes annulées ne sont plus affichées).
  List<JoinRequest> get incoming =>
      _all.where((r) => r.requester.id != _userId && r.status != JoinRequestStatus.cancelled).toList();

  /// Demandes que j'ai envoyées.
  List<JoinRequest> get outgoing => _all.where((r) => r.requester.id == _userId).toList();

  int get pendingIncoming => incoming.where((r) => r.isPending).length;
  int get unseenOutgoing => outgoing.where((r) => !r.seenByRequester).length;

  /// Pastille de l'onglet : demandes à traiter + réponses pas encore vues.
  int get badge => pendingIncoming + unseenOutgoing;

  Stream<RequestNotice> get notices => _notices.stream;

  UserProfile? get user => auth.user.value;

  void _onAuthChange() {
    final userId = auth.user.value?.id;
    if (userId == _userId) return;
    _userId = userId;
    _changes?.cancel();
    _changes = null;
    _all = const [];
    loaded = false;
    error = null;
    notifyListeners();
    if (userId == null) return;
    refresh();
    _changes = repository.changes(userId).listen(_onChange);
  }

  Future<void> refresh() async {
    final userId = _userId;
    try {
      final all = await repository.myRequests();
      if (userId != _userId) return;
      _all = all;
      error = null;
    } catch (e) {
      if (userId != _userId) return;
      error = tr('Impossible de charger les demandes.');
    }
    loaded = true;
    notifyListeners();
  }

  // Changement en direct : on recharge puis on prévient le destinataire
  Future<void> _onChange(RequestChange change) async {
    await refresh();
    final request = _all.where((r) => r.id == change.id).firstOrNull;
    if (request == null) return;
    final mine = change.userId == _userId;
    final notice = switch ((mine, change.inserted, change.status)) {
      (false, true, JoinRequestStatus.pending) => RequestNotice(
        tr('{0} veut rejoindre « {1} »', [request.requester.displayName, request.activityName]),
        incoming: true,
      ),
      (false, false, JoinRequestStatus.cancelled) => RequestNotice(
        tr('{0} a annulé sa demande pour « {1} »', [request.requester.displayName, request.activityName]),
        incoming: true,
      ),
      (true, false, JoinRequestStatus.accepted) => RequestNotice(
        tr('Ta demande pour « {0} » a été acceptée 🎉', [request.activityName]),
        incoming: false,
      ),
      (true, false, JoinRequestStatus.rejected) => RequestNotice(
        tr('Ta demande pour « {0} » a été refusée', [request.activityName]),
        incoming: false,
      ),
      _ => null,
    };
    if (notice != null) _notices.add(notice);
  }

  Future<void> respond(JoinRequest request, {required bool accept}) async {
    await repository.respond(request.id, accept: accept);
    await refresh();
  }

  Future<void> cancel(JoinRequest request) async {
    await repository.cancel(request.id);
    await refresh();
  }

  /// Appelé quand l'utilisateur ouvre l'onglet : les réponses sont considérées comme vues.
  Future<void> markSeen() async {
    if (unseenOutgoing == 0 || _markingSeen) return;
    _markingSeen = true;
    try {
      await repository.markSeen();
      await refresh();
    } catch (_) {
      // Sans réseau : la pastille restera jusqu'à la prochaine ouverture
    } finally {
      _markingSeen = false;
    }
  }

  @override
  void dispose() {
    auth.user.removeListener(_onAuthChange);
    _changes?.cancel();
    _notices.close();
    super.dispose();
  }
}
