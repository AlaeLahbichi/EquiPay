import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../models/user_profile.dart';
import 'offline_store.dart';
import 'pending_expenses.dart';
import '../l10n/i18n.dart';

abstract class AuthService {
  /// Utilisateur connecté, ou null (visiteur).
  ValueListenable<UserProfile?> get user;

  /// Jeton à envoyer à l'API Python (null si visiteur).
  String? get accessToken;

  Future<void> signInWithEmail({required String email, required String password});

  /// Renvoie true si l'utilisateur doit d'abord confirmer son email.
  Future<bool> signUpWithEmail({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  });

  /// Ouvre la page de connexion Google ; la session arrive au retour dans l'app.
  Future<void> signInWithGoogle();

  Future<void> signOut();

  /// Change le nom complet et le pseudo (a-z, 0-9, _ ; 3 à 30 caractères).
  Future<void> updateProfile({required String fullName, required String username});

  /// Remplace la photo de profil (image JPEG).
  Future<void> updateAvatar(Uint8List jpeg);

  /// Demande le changement d'email : effectif après clic sur le lien reçu.
  Future<void> updateEmail(String email);

  /// Supprime définitivement le compte et toutes ses données.
  Future<void> deleteAccount();
}

class UsernameTakenException implements Exception {
  @override
  String toString() => tr('Ce pseudo est déjà pris.');
}

class GoogleNotEnabledException implements Exception {
  @override
  String toString() => tr('La connexion avec Google n\'est pas encore activée.');
}

class SupabaseAuthService implements AuthService {
  SupabaseAuthService(this._client) {
    _onSession(_client.auth.currentUser);
    // Le service vit aussi longtemps que l'app : pas besoin d'arrêter l'écoute
    _client.auth.onAuthStateChange.listen((state) {
      if (state.event != AuthChangeEvent.tokenRefreshed) _onSession(state.session?.user);
    });
  }

  final SupabaseClient _client;
  final _user = ValueNotifier<UserProfile?>(null);

  static const _timeout = Duration(seconds: 20);

  @override
  ValueListenable<UserProfile?> get user => _user;

  @override
  String? get accessToken => _client.auth.currentSession?.accessToken;

  // Affiche tout de suite les infos de la session, puis complète avec le profil
  Future<void> _onSession(User? authUser) async {
    if (authUser == null) {
      // Déconnexion : les copies hors ligne et les dépenses en attente de ce compte sont effacées
      if (_user.value != null) {
        await OfflineStore.instance.clear();
        await PendingExpenses.instance.clear();
      }
      _user.value = null;
      return;
    }
    if (_user.value?.id != authUser.id) _user.value = UserProfile.fromAuth(authUser);
    try {
      final row = await OfflineStore.instance.fetch(
        'profile:${authUser.id}',
        () => _client
            .from('profiles')
            .select('id, email, full_name, username, avatar_url')
            .eq('id', authUser.id)
            .maybeSingle()
            .timeout(_timeout),
        (json) => json == null ? null : Map<String, dynamic>.from(json as Map),
      );
      if (row != null && _client.auth.currentUser?.id == authUser.id) {
        _user.value = UserProfile.fromRow(row);
      }
    } catch (_) {
      // Hors ligne sans copie : on garde les infos de la session
    }
  }

  @override
  Future<void> signInWithEmail({required String email, required String password}) async {
    await _client.auth.signInWithPassword(email: email.trim(), password: password).timeout(_timeout);
  }

  @override
  Future<bool> signUpWithEmail({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    final res = await _client.auth
        .signUp(
          email: email.trim(),
          password: password,
          data: {'full_name': '${firstName.trim()} ${lastName.trim()}'},
          emailRedirectTo: Env.authRedirect,
        )
        .timeout(_timeout);
    return res.session == null;
  }

  @override
  Future<void> signInWithGoogle() async {
    // Évite d'ouvrir une page d'erreur tant que Google n'est pas configuré dans Supabase
    final res = await http
        .get(Uri.parse('${Env.supabaseUrl}/auth/v1/settings'), headers: {'apikey': Env.supabasePublishableKey})
        .timeout(_timeout);
    final external = (jsonDecode(res.body) as Map)['external'] as Map? ?? const {};
    if (external['google'] != true) throw GoogleNotEnabledException();
    await _client.auth.signInWithOAuth(OAuthProvider.google, redirectTo: Env.authRedirect);
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  String get _uid => _client.auth.currentUser!.id;

  @override
  Future<void> updateProfile({required String fullName, required String username}) async {
    try {
      await _client
          .from('profiles')
          .update({'full_name': fullName.trim(), 'username': username.trim().toLowerCase()})
          .eq('id', _uid)
          .timeout(_timeout);
    } on PostgrestException catch (e) {
      if (e.code == '23505') throw UsernameTakenException(); // valeur déjà utilisée
      rethrow;
    }
    await _onSession(_client.auth.currentUser);
  }

  @override
  Future<void> updateAvatar(Uint8List jpeg) async {
    // Nouveau nom à chaque fois : l'ancienne image n'est pas resservie par le cache
    final path = '$_uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
    final bucket = _client.storage.from('avatars');
    await bucket
        .uploadBinary(path, jpeg, fileOptions: const FileOptions(contentType: 'image/jpeg'))
        .timeout(const Duration(seconds: 60));
    await _client.from('profiles').update({'avatar_url': bucket.getPublicUrl(path)}).eq('id', _uid).timeout(_timeout);
    await _onSession(_client.auth.currentUser);
  }

  @override
  Future<void> updateEmail(String email) async {
    await _client.auth
        .updateUser(UserAttributes(email: email.trim()), emailRedirectTo: Env.authRedirect)
        .timeout(_timeout);
  }

  @override
  Future<void> deleteAccount() async {
    await _client.rpc('delete_my_account').timeout(_timeout);
    // Le compte n'existe plus côté serveur : on efface seulement la session locale
    await _client.auth.signOut(scope: SignOutScope.local);
  }
}
