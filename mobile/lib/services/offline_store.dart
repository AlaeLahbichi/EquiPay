import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Copie locale des dernières données chargées, pour que l'app reste consultable hors ligne.
///
/// Chaque lecture réussie est gardée sur le téléphone ; sans réseau, on renvoie cette copie.
/// Les clés contiennent l'identifiant de l'utilisateur, et tout est effacé à la déconnexion.
class OfflineStore {
  OfflineStore([this._prefs]);

  /// Remplacé dans main.dart par la version enregistrée sur le téléphone. Par défaut : en mémoire (tests).
  static OfflineStore instance = OfflineStore();

  static Future<OfflineStore> load() async {
    try {
      return OfflineStore(await SharedPreferences.getInstance());
    } catch (_) {
      return OfflineStore();
    }
  }

  static const _prefix = 'offline:';

  final SharedPreferences? _prefs;
  final _memory = <String, String>{};

  /// Statut du réseau (branché sur NetworkStatus dans main.dart).
  ValueListenable<bool> online = ValueNotifier(true);

  Object? read(String key) {
    final raw = _prefs?.getString('$_prefix$key') ?? _memory[key];
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, Object? value) async {
    final raw = jsonEncode(value);
    _memory[key] = raw;
    try {
      await _prefs?.setString('$_prefix$key', raw);
    } catch (_) {
      // Stockage plein ou indisponible : la copie reste en mémoire
    }
  }

  Future<void> remove(String key) async {
    _memory.remove(key);
    await _prefs?.remove('$_prefix$key');
  }

  /// Charge [load] et garde le résultat (JSON) ; sans réseau, renvoie la dernière copie.
  /// Sans copie, l'erreur d'origine est relancée.
  Future<T> fetch<T>(String key, Future<Object?> Function() load, T Function(Object? json) parse) async {
    final cached = read(key);
    if (!online.value && cached != null) return parse(cached);
    try {
      final json = await load();
      unawaited(write(key, json));
      return parse(json);
    } catch (e) {
      // ParallelWaitError : plusieurs requêtes lancées ensemble ont échoué (souvent faute de réseau)
      if (cached != null && (isNetworkError(e) || e is ParallelWaitError)) return parse(cached);
      rethrow;
    }
  }

  /// Efface toutes les copies (déconnexion).
  Future<void> clear() async {
    _memory.clear();
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key in prefs.getKeys().where((k) => k.startsWith(_prefix)).toList()) {
      await prefs.remove(key);
    }
  }
}

/// Erreur due au réseau (pas de connexion, serveur injoignable ou trop lent).
bool isNetworkError(Object error) => error is TimeoutException || isOfflineError(error);

/// Requête qui n'a pas pu partir faute de réseau (contrairement à un délai dépassé,
/// où le serveur a peut-être enregistré la demande).
bool isOfflineError(Object error) {
  if (error is AuthRetryableFetchException) return true;
  final text = error.toString();
  return text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('Failed host lookup') ||
      text.contains('Connection');
}

/// Liste de lignes JSON (copie locale ou réponse de Supabase).
List<Map<String, dynamic>> jsonRows(Object? json) => [
  for (final r in json as List) Map<String, dynamic>.from(r as Map),
];
