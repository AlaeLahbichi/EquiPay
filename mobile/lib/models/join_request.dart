import 'user_profile.dart';

enum JoinRequestStatus { pending, accepted, rejected, cancelled }

/// Demande pour rejoindre une activité (envoyée avec le code de l'activité).
class JoinRequest {
  const JoinRequest({
    required this.id,
    required this.activityId,
    required this.activityName,
    required this.requester,
    required this.status,
    required this.createdAt,
    this.activityCover,
    this.decidedAt,
    this.seenByRequester = true,
  });

  final String id;
  final String activityId;
  final String activityName;
  final String? activityCover;
  final UserProfile requester;
  final JoinRequestStatus status;
  final DateTime createdAt;
  final DateTime? decidedAt;

  /// false : l'owner a répondu et le demandeur n'a pas encore vu la réponse.
  final bool seenByRequester;

  bool get isPending => status == JoinRequestStatus.pending;

  /// Ligne de join_requests avec profiles(...) joint (le demandeur).
  factory JoinRequest.fromRow(Map<String, dynamic> row) => JoinRequest(
    id: row['id'] as String,
    activityId: row['activity_id'] as String,
    activityName: row['activity_name'] as String,
    activityCover: row['activity_cover'] as String?,
    requester: UserProfile.fromRow(row['profiles'] as Map<String, dynamic>),
    status: JoinRequestStatus.values.byName(row['status'] as String),
    createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
    decidedAt: row['decided_at'] == null ? null : DateTime.parse(row['decided_at'] as String).toLocal(),
    seenByRequester: row['seen_by_requester'] as bool? ?? true,
  );
}
