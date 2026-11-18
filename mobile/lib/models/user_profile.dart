import 'package:supabase_flutter/supabase_flutter.dart';

/// Utilisateur connecté (table profiles).
class UserProfile {
  const UserProfile({required this.id, required this.email, this.fullName, this.username, this.avatarUrl});

  final String id;
  final String email;
  final String? fullName;
  final String? username;
  final String? avatarUrl;

  /// Nom affiché : nom complet, sinon la partie avant le @ de l'email.
  String get displayName => (fullName?.trim().isNotEmpty ?? false) ? fullName!.trim() : email.split('@').first;

  /// Version immédiate (sans réseau) à partir de la session.
  factory UserProfile.fromAuth(User user) {
    final meta = user.userMetadata ?? const {};
    return UserProfile(
      id: user.id,
      email: user.email ?? '',
      fullName: (meta['full_name'] ?? meta['name']) as String?,
      avatarUrl: (meta['avatar_url'] ?? meta['picture']) as String?,
    );
  }

  factory UserProfile.fromRow(Map<String, dynamic> row) => UserProfile(
    id: row['id'] as String,
    email: row['email'] as String,
    fullName: row['full_name'] as String?,
    username: row['username'] as String?,
    avatarUrl: row['avatar_url'] as String?,
  );
}
