import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../l10n/i18n.dart';

enum ActivityType {
  voyage('Voyage', Icons.flight_takeoff_rounded, AppColors.voyage),
  sortie('Sortie', Icons.celebration_rounded, AppColors.sortie),
  quotidien('Quotidien', Icons.home_rounded, AppColors.quotidien),
  credit('Crédit', Icons.credit_card_rounded, AppColors.credit);

  const ActivityType(this._label, this.icon, this.color);

  final String _label;

  String get label => _label.tr;
  final IconData icon;
  final Color color;
}

enum MemberRole { owner, member, viewer }

class Activity {
  const Activity({
    required this.id,
    required this.name,
    required this.type,
    required this.role,
    this.coverUrl,
    this.currency = 'EUR',
    this.archived = false,
  });

  final String id;
  final String name;
  final ActivityType type;
  final MemberRole role;
  final String? coverUrl;

  /// Devise de l'activité (code ISO, ex. « EUR »).
  final String currency;

  /// Rangée par l'utilisateur dans « Activités archivées » (archivage propre à chacun).
  final bool archived;

  Activity copyWith({String? name, String? Function()? coverUrl, String? currency, bool? archived}) => Activity(
    id: id,
    name: name ?? this.name,
    type: type,
    role: role,
    coverUrl: coverUrl == null ? this.coverUrl : coverUrl(),
    currency: currency ?? this.currency,
    archived: archived ?? this.archived,
  );

  /// Construit une activité à partir d'une ligne de activity_members avec activities(...) joint.
  factory Activity.fromMembership(Map<String, dynamic> row) {
    final activity = row['activities'] as Map<String, dynamic>;
    return Activity(
      id: activity['id'] as String,
      name: activity['name'] as String,
      type: ActivityType.values.byName(activity['type'] as String),
      role: MemberRole.values.byName(row['role'] as String),
      coverUrl: activity['cover_url'] as String?,
      currency: activity['default_currency'] as String? ?? 'EUR',
      archived: row['archived_at'] != null,
    );
  }
}
