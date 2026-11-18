import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/activity.dart';
import '../models/activity_overview.dart';
import '../models/user_profile.dart';
import 'offline_store.dart';
import '../l10n/i18n.dart';

abstract class ActivityRepository {
  /// Prépare les données au démarrage de l'app.
  Future<void> ensureReady();

  /// Activités dont l'utilisateur connecté est membre (les plus récentes d'abord) :
  /// les activités en cours, ou celles qu'il a archivées.
  Future<List<Activity>> myActivities({bool archived = false});

  /// Archive ou désarchive des activités pour l'utilisateur connecté uniquement.
  Future<void> setArchived(List<String> activityIds, {required bool archived});

  /// Owner : supprime l'activité pour tout le monde (dépenses et photos comprises).
  /// Sinon : quitte l'activité (refusé par la base si l'utilisateur a des dépenses).
  Future<void> deleteOrLeave(Activity activity);

  /// Crée une activité, avec un logo optionnel (image JPEG).
  /// Renvoie false si l'activité est créée mais que le logo n'a pas pu être envoyé.
  Future<bool> create({required String name, required ActivityType type, required String currency, Uint8List? logo});

  /// Envoie une demande pour rejoindre une activité avec son code (ex. "FN3V-HM7S").
  /// L'owner doit ensuite l'accepter.
  Future<void> join(String code);

  /// Code à partager pour rejoindre l'activité (visible par l'owner uniquement, sinon null).
  Future<String?> joinCode(String activityId);

  /// Émet un événement quand la liste des activités de l'utilisateur change.
  Stream<void> changes();

  /// Total des dépenses et membres de l'activité avec leurs dépenses (visible par tous les membres).
  Future<ActivityOverview> overview(String activityId);

  /// Émet un événement quand une dépense, un membre ou une photo de l'activité change.
  Stream<void> activityChanges(String activityId);

  /// Owner : change le nom, la devise et/ou la photo de l'activité
  /// (removeCover : revenir au logo par défaut). La devise est refusée si l'activité a des dépenses.
  Future<Activity> updateActivity(
    Activity activity, {
    required String name,
    required String currency,
    Uint8List? cover,
    bool removeCover = false,
  });

  /// Owner : passe un participant en membre ou en spectateur.
  Future<void> setMemberRole(String activityId, String userId, MemberRole role);

  /// Owner : retire un participant (refusé par la base s'il a des dépenses).
  Future<void> removeMember(String activityId, String userId);
}

class SupabaseActivityRepository implements ActivityRepository {
  SupabaseActivityRepository(this._client);

  final SupabaseClient _client;

  static const _timeout = Duration(seconds: 20);

  Future<String> _userId() async {
    final user = _client.auth.currentUser;
    if (user == null) throw AuthException(tr('Connecte-toi pour accéder à tes activités.'));
    return user.id;
  }

  // La session est restaurée par Supabase.initialize, sans appel réseau
  @override
  Future<void> ensureReady() async {}

  @override
  Future<List<Activity>> myActivities({bool archived = false}) async {
    final userId = await _userId();
    final query = _client
        .from('activity_members')
        .select('role, joined_at, archived_at, activities(id, name, type, cover_url, default_currency)')
        .eq('user_id', userId);
    return OfflineStore.instance.fetch(
      'activities:$userId:${archived ? 'archived' : 'current'}',
      () => (archived ? query.not('archived_at', 'is', null) : query.isFilter('archived_at', null))
          .order(archived ? 'archived_at' : 'joined_at', ascending: false)
          .timeout(_timeout),
      (json) => jsonRows(json).map(Activity.fromMembership).toList(),
    );
  }

  @override
  Future<void> setArchived(List<String> activityIds, {required bool archived}) async {
    await _userId();
    if (activityIds.isEmpty) return;
    await _client
        .rpc('set_activities_archived', params: {'p_activities': activityIds, 'p_archived': archived})
        .timeout(_timeout);
  }

  @override
  Future<void> deleteOrLeave(Activity activity) async {
    final userId = await _userId();
    if (activity.role != MemberRole.owner) {
      try {
        await removeMember(activity.id, userId);
      } on PostgrestException catch (e) {
        if (!e.message.contains('dépenses')) rethrow;
        throw PostgrestException(
          message: tr('Tu as des dépenses dans « {0} » : tu ne peux pas la quitter. Archive-la plutôt.', [activity.name]),
        );
      }
      return;
    }
    // Fichiers des photos et reçus : les lignes partent en cascade, pas les fichiers
    final files = await _client
        .from('attachments')
        .select('storage_path')
        .eq('activity_id', activity.id)
        .timeout(_timeout);
    final deleted = await _client.from('activities').delete().eq('id', activity.id).select('id').timeout(_timeout);
    if (deleted.isEmpty) throw PostgrestException(message: tr('Seul le créateur peut supprimer l\'activité'));
    if (files.isEmpty) return;
    try {
      await _client.storage
          .from('attachments')
          .remove([for (final f in files) f['storage_path'] as String])
          .timeout(_timeout);
    } catch (_) {
      // Fichiers déjà absents : sans conséquence pour l'utilisateur
    }
  }

  @override
  Future<bool> create({
    required String name,
    required ActivityType type,
    required String currency,
    Uint8List? logo,
  }) async {
    await _userId();
    final row = await _client
        .from('activities')
        .insert({'name': name.trim(), 'type': type.name, 'default_currency': currency})
        .select('id')
        .single()
        .timeout(_timeout);
    if (logo == null) return true;

    try {
      final id = row['id'] as String;
      final path = '$id/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final bucket = _client.storage.from('activity-covers');
      await bucket
          .uploadBinary(path, logo, fileOptions: const FileOptions(contentType: 'image/jpeg'))
          .timeout(const Duration(seconds: 60));
      await _client.from('activities').update({'cover_url': bucket.getPublicUrl(path)}).eq('id', id).timeout(_timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> join(String code) async {
    await _userId();
    await _client.rpc('join_activity_by_code', params: {'p_code': code}).timeout(_timeout);
  }

  @override
  Future<String?> joinCode(String activityId) => OfflineStore.instance.fetch(
    'join_code:$activityId',
    () => _client
        .from('activity_join_codes')
        .select('code')
        .eq('activity_id', activityId)
        .maybeSingle()
        .timeout(_timeout),
    (json) => (json as Map?)?['code'] as String?,
  );

  @override
  Future<ActivityOverview> overview(String activityId) => OfflineStore.instance.fetch(
    'overview:$activityId',
    () => _loadOverview(activityId),
    (json) => _overview(Map<String, dynamic>.from(json as Map)),
  );

  /// Lignes brutes (gardées telles quelles pour le hors-ligne).
  Future<Map<String, Object?>> _loadOverview(String activityId) async {
    final (balances, totals) = await (
      _client
          .from('activity_balances')
          .select('user_id, role, total_paid, total_owed, balance')
          .eq('activity_id', activityId)
          .timeout(_timeout),
      _client
          .from('activity_totals')
          .select('currency, total_amount, expense_count')
          .eq('activity_id', activityId)
          .single()
          .timeout(_timeout),
    ).wait;
    final ids = balances.map((b) => b['user_id'] as String).toList();
    final profiles = await _client
        .from('profiles')
        .select('id, email, full_name, username, avatar_url')
        .inFilter('id', ids)
        .timeout(_timeout);
    return {'balances': balances, 'totals': totals, 'profiles': profiles};
  }

  ActivityOverview _overview(Map<String, dynamic> json) {
    final balances = jsonRows(json['balances']);
    final totals = Map<String, dynamic>.from(json['totals'] as Map);
    final profiles = jsonRows(json['profiles']);
    final byId = {for (final p in profiles) p['id'] as String: UserProfile.fromRow(p)};

    final members =
        [
          for (final b in balances)
            if (byId[b['user_id']] case final profile?)
              MemberSummary(
                profile: profile,
                role: MemberRole.values.byName(b['role'] as String),
                totalPaid: _num(b['total_paid']),
                totalOwed: _num(b['total_owed']),
                balance: _num(b['balance']),
              ),
        ]..sort((a, b) {
          if ((a.role == MemberRole.owner) != (b.role == MemberRole.owner)) {
            return a.role == MemberRole.owner ? -1 : 1;
          }
          return b.totalPaid.compareTo(a.totalPaid);
        });
    return ActivityOverview(
      currency: totals['currency'] as String,
      total: _num(totals['total_amount']),
      expenseCount: (totals['expense_count'] as num).toInt(),
      members: members,
    );
  }

  @override
  Stream<void> activityChanges(String activityId) {
    final controller = StreamController<void>();
    RealtimeChannel? channel;
    controller.onListen = () {
      final filter = PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'activity_id', value: activityId);
      channel = _client.channel('activity:$activityId');
      for (final table in ['expenses', 'activity_members', 'attachments']) {
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

  @override
  Future<Activity> updateActivity(
    Activity activity, {
    required String name,
    required String currency,
    Uint8List? cover,
    bool removeCover = false,
  }) async {
    await _userId();
    final changes = <String, dynamic>{'name': name.trim()};
    if (currency != activity.currency) changes['default_currency'] = currency;
    if (cover != null) {
      final path = '${activity.id}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final bucket = _client.storage.from('activity-covers');
      await bucket
          .uploadBinary(path, cover, fileOptions: const FileOptions(contentType: 'image/jpeg'))
          .timeout(const Duration(seconds: 60));
      changes['cover_url'] = bucket.getPublicUrl(path);
    } else if (removeCover) {
      changes['cover_url'] = null;
    }
    final row = await _client
        .from('activities')
        .update(changes)
        .eq('id', activity.id)
        .select('name, cover_url, default_currency')
        .maybeSingle()
        .timeout(_timeout);
    if (row == null) throw PostgrestException(message: tr('Seul le créateur peut modifier l\'activité'));
    return activity.copyWith(
      name: row['name'] as String,
      coverUrl: () => row['cover_url'] as String?,
      currency: row['default_currency'] as String,
    );
  }

  @override
  Future<void> setMemberRole(String activityId, String userId, MemberRole role) async {
    if (role == MemberRole.owner) throw ArgumentError('Le rôle de créateur ne se transfère pas');
    final rows = await _client
        .from('activity_members')
        .update({'role': role.name})
        .eq('activity_id', activityId)
        .eq('user_id', userId)
        .select('user_id')
        .timeout(_timeout);
    if (rows.isEmpty) throw PostgrestException(message: tr('Seul le créateur peut changer les rôles'));
  }

  @override
  Future<void> removeMember(String activityId, String userId) async {
    final rows = await _client
        .from('activity_members')
        .delete()
        .eq('activity_id', activityId)
        .eq('user_id', userId)
        .select('user_id')
        .timeout(_timeout);
    if (rows.isEmpty) throw PostgrestException(message: tr('Seul le créateur peut retirer un participant'));
  }

  @override
  Stream<void> changes() {
    final controller = StreamController<void>();
    RealtimeChannel? channel;
    controller.onListen = () async {
      try {
        final userId = await _userId();
        channel = _client
            .channel('memberships:$userId')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'activity_members',
              filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: userId),
              callback: (_) => controller.add(null),
            )
            .subscribe();
      } catch (_) {
        // Hors ligne : pas de temps réel, la page se recharge au retour du réseau
      }
    };
    controller.onCancel = () async {
      if (channel != null) await _client.removeChannel(channel!);
    };
    return controller.stream;
  }
}

double _num(Object? v) => (v as num?)?.toDouble() ?? 0;

/// Message lisible pour l'utilisateur à partir d'une erreur.
String friendlyError(Object error) {
  if (error is TimeoutException) {
    return tr('Le serveur met trop de temps à répondre. Réessaie dans un instant.');
  }
  // Plusieurs requêtes lancées ensemble : on explique la première erreur
  if (error is ParallelWaitError) {
    final first = (error.errors as Record?).toString();
    if (first.contains('SocketException') || first.contains('ClientException') || first.contains('host lookup')) {
      return tr('Pas de connexion internet.');
    }
    if (first.contains('TimeoutException')) {
      return tr('Le serveur met trop de temps à répondre. Réessaie dans un instant.');
    }
  }
  if (isOfflineError(error)) {
    return tr('Pas de connexion internet.');
  }
  if (error is PostgrestException) return error.message.tr; // messages connus de la base traduits
  if (error is AuthException) return tr('Connexion impossible : {0}', [error.message]);
  return tr('Une erreur est survenue. Réessaie.');
}
