import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/expense.dart';
import 'offline_store.dart';
import 'pending_expenses.dart';
import '../l10n/i18n.dart';

/// Dépenses et photos d'une activité.
abstract class ExpenseRepository {
  /// Dépenses de l'activité, les plus récentes d'abord, avec leur répartition.
  Future<List<Expense>> expenses(String activityId);

  /// Une dépense et sa photo (null si elle n'existe plus).
  Future<(Expense, Photo?)?> expense(String expenseId);

  /// Crée (expenseId null) ou modifie une dépense et sa répartition. Renvoie son identifiant.
  Future<String> save(ExpenseDraft draft, {String? expenseId});

  Future<void> delete(Expense expense);

  /// Remplace la photo de la dépense (1 maximum).
  Future<void> setExpensePhoto(String activityId, String expenseId, Uint8List jpeg);

  Future<void> deletePhoto(Photo photo);

  /// Photos de l'activité (hors justificatifs de dépenses), les plus récentes d'abord.
  Future<List<Photo>> activityPhotos(String activityId);

  Future<void> addActivityPhoto(String activityId, Uint8List jpeg);
}

class SupabaseExpenseRepository implements ExpenseRepository {
  SupabaseExpenseRepository(this._client);

  final SupabaseClient _client;

  static const _timeout = Duration(seconds: 20);
  static const _uploadTimeout = Duration(seconds: 60);
  static const _bucket = 'attachments';

  StorageFileApi get _files => _client.storage.from(_bucket);

  PendingExpenses get _pending => PendingExpenses.instance;

  @override
  Future<List<Expense>> expenses(String activityId) async {
    final saved = await OfflineStore.instance.fetch(
      'expenses:$activityId',
      () => _client
          .from('expenses')
          .select('*, expense_shares(user_id, percentage)')
          .eq('activity_id', activityId)
          .order('expense_date', ascending: false)
          .order('created_at', ascending: false)
          .timeout(_timeout),
      (json) => jsonRows(json).map(Expense.fromRow).toList(),
    );
    // Dépenses enregistrées hors ligne : les modifiées remplacent l'ancienne version, les nouvelles en tête
    final pending = {for (final p in _pending.forActivity(activityId)) p.id: p.toExpense()};
    if (pending.isEmpty) return saved;
    final known = {for (final e in saved) e.id};
    return [
      for (final e in pending.values)
        if (!known.contains(e.id)) e,
      for (final e in saved) pending[e.id] ?? e,
    ];
  }

  @override
  Future<(Expense, Photo?)?> expense(String expenseId) async {
    if (_pending.byId(expenseId) case final p?) return (p.toExpense(), null);
    final row = await OfflineStore.instance.fetch(
      'expense:$expenseId',
      () => _client
          .from('expenses')
          .select('*, expense_shares(user_id, percentage)')
          .eq('id', expenseId)
          .maybeSingle()
          .timeout(_timeout),
      (json) => json == null ? null : Map<String, dynamic>.from(json as Map),
    );
    if (row == null) return null;
    Photo? photo;
    try {
      final photos = await _client
          .from('attachments')
          .select()
          .eq('expense_id', expenseId)
          .order('created_at', ascending: false)
          .limit(1)
          .timeout(_timeout);
      photo = (await _signed(photos)).firstOrNull;
    } catch (e) {
      if (!isNetworkError(e)) rethrow; // hors ligne : la dépense s'affiche sans sa photo
    }
    return (Expense.fromRow(row), photo);
  }

  @override
  Future<String> save(ExpenseDraft d, {String? expenseId}) async {
    final userId = _client.auth.currentUser?.id;
    // Sans réseau (ou dépense pas encore envoyée) : gardée sur le téléphone, envoyée au retour de la connexion
    if (userId != null &&
        (!OfflineStore.instance.online.value || (expenseId != null && PendingExpenses.isLocalId(expenseId)))) {
      return _pending.put(d, userId: userId, expenseId: expenseId);
    }
    try {
      return await _send(d, expenseId);
    } catch (e) {
      if (userId == null || !isOfflineError(e)) rethrow;
      return _pending.put(d, userId: userId, expenseId: expenseId);
    }
  }

  /// Envoie les dépenses enregistrées hors ligne ; renvoie le nombre envoyé et refusé.
  Future<({int sent, int rejected})> syncPending() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null || _pending.items.isEmpty) return (sent: 0, rejected: 0);
    return _pending.sync(userId, (draft, expenseId) => _send(draft, expenseId));
  }

  Future<String> _send(ExpenseDraft d, String? expenseId) async {
    final id = await _client
        .rpc(
          'save_expense',
          params: {
            'p_expense_id': expenseId,
            'p_activity_id': d.activityId,
            'p_name': d.name,
            'p_description': d.description,
            'p_amount': d.amount,
            'p_currency': d.currency,
            'p_exchange_rate': d.exchangeRate,
            'p_expense_date': _isoDate(d.date),
            'p_paid_by': d.paidBy,
            'p_country': d.country,
            'p_city': d.city,
            'p_address': d.address,
            'p_shares': [
              for (final e in d.shares.entries) {'user_id': e.key, 'percentage': e.value},
            ],
          },
        )
        .timeout(_timeout);
    return id as String;
  }

  @override
  Future<void> delete(Expense expense) async {
    if (expense.pending) {
      await _pending.remove(expense.id);
      if (PendingExpenses.isLocalId(expense.id)) return; // jamais envoyée : rien à supprimer sur le serveur
    }
    // Fichier de la photo d'abord (la ligne disparaît avec la dépense)
    final photos = await _client.from('attachments').select('storage_path').eq('expense_id', expense.id);
    if (photos.isNotEmpty) {
      await _removeFiles([for (final p in photos) p['storage_path'] as String]);
    }
    final deleted = await _client.from('expenses').delete().eq('id', expense.id).select('id').timeout(_timeout);
    if (deleted.isEmpty) {
      throw PostgrestException(message: tr('Seul le créateur de la dépense peut la supprimer'));
    }
  }

  @override
  Future<void> setExpensePhoto(String activityId, String expenseId, Uint8List jpeg) async {
    final old = await _client.from('attachments').select().eq('expense_id', expenseId).timeout(_timeout);
    for (final row in old) {
      await deletePhoto(_photo(row, ''));
    }
    await _upload(activityId, jpeg, expenseId: expenseId);
  }

  @override
  Future<void> deletePhoto(Photo photo) async {
    final deleted = await _client.from('attachments').delete().eq('id', photo.id).select('id').timeout(_timeout);
    if (deleted.isEmpty) {
      throw PostgrestException(message: tr('Tu ne peux pas supprimer cette photo'));
    }
    await _removeFiles([photo.storagePath]);
  }

  @override
  Future<List<Photo>> activityPhotos(String activityId) async {
    if (!OfflineStore.instance.online.value) return const [];
    try {
      final rows = await _client
          .from('attachments')
          .select()
          .eq('activity_id', activityId)
          .isFilter('expense_id', null)
          .order('created_at', ascending: false)
          .timeout(_timeout);
      return await _signed(rows);
    } catch (e) {
      // Hors ligne : les photos (liens temporaires) ne sont pas gardées, le reste de l'activité s'affiche
      if (isNetworkError(e)) return const [];
      rethrow;
    }
  }

  @override
  Future<void> addActivityPhoto(String activityId, Uint8List jpeg) => _upload(activityId, jpeg);

  // Le premier dossier du chemin doit être l'activité (règles d'accès du stockage)
  Future<void> _upload(String activityId, Uint8List jpeg, {String? expenseId}) async {
    final path = '$activityId/${expenseId ?? 'photos'}/${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _files
        .uploadBinary(path, jpeg, fileOptions: const FileOptions(contentType: 'image/jpeg'))
        .timeout(_uploadTimeout);
    try {
      await _client
          .from('attachments')
          .insert({
            'activity_id': activityId,
            'expense_id': expenseId,
            'kind': expenseId == null ? 'photo' : 'recu',
            'storage_path': path,
          })
          .timeout(_timeout);
    } catch (_) {
      await _removeFiles([path]); // pas de fichier orphelin
      rethrow;
    }
  }

  Future<void> _removeFiles(List<String> paths) async {
    paths.forEach(_signedUrls.remove);
    try {
      await _files.remove(paths).timeout(_timeout);
    } catch (_) {
      // Fichier déjà absent : sans conséquence pour l'utilisateur
    }
  }

  /// Liens signés déjà obtenus : chemin → (lien, expiration). Garder le même lien évite de
  /// re-télécharger l'image à chaque rechargement (le cache d'images se base sur l'URL).
  final _signedUrls = <String, (String, DateTime)>{};

  static const _signedValidity = Duration(hours: 1);

  /// Photos avec un lien signé (le stockage des reçus est privé).
  Future<List<Photo>> _signed(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return const [];
    // Un lien qui expire dans moins de 10 min est renouvelé
    final soon = DateTime.now().add(const Duration(minutes: 10));
    final missing = [
      for (final r in rows)
        if (_signedUrls[r['storage_path']] case final cached when cached == null || cached.$2.isBefore(soon))
          r['storage_path'] as String,
    ];
    if (missing.isNotEmpty) {
      final expiry = DateTime.now().add(_signedValidity);
      final results = await _files.createSignedUrlsResult(missing, _signedValidity.inSeconds).timeout(_timeout);
      for (final r in results.whereType<SignedUrlSuccess>()) {
        if (r.signedUrl.isNotEmpty) _signedUrls[r.path] = (r.signedUrl, expiry);
      }
    }
    // Fichier introuvable : la photo est simplement ignorée
    return [
      for (final r in rows)
        if (_signedUrls[r['storage_path']] case final cached?) _photo(r, cached.$1),
    ];
  }

  Photo _photo(Map<String, dynamic> r, String url) => Photo(
    id: r['id'] as String,
    activityId: r['activity_id'] as String,
    expenseId: r['expense_id'] as String?,
    uploadedBy: r['uploaded_by'] as String,
    storagePath: r['storage_path'] as String,
    url: url,
    createdAt: r['created_at'] == null ? null : DateTime.parse(r['created_at'] as String),
  );
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
