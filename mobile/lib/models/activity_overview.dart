import 'activity.dart';
import 'user_profile.dart';

/// Un membre de l'activité et ses dépenses (montants dans la devise de l'activité).
class MemberSummary {
  const MemberSummary({
    required this.profile,
    required this.role,
    required this.totalPaid,
    required this.totalOwed,
    required this.balance,
  });

  final UserProfile profile;
  final MemberRole role;

  /// Total des dépenses payées par ce membre.
  final double totalPaid;

  /// Sa part de toutes les dépenses.
  final double totalOwed;

  /// Payé − dû : positif, on lui doit de l'argent ; négatif, il en doit.
  final double balance;
}

/// Vue d'ensemble d'une activité : total des dépenses et membres.
class ActivityOverview {
  const ActivityOverview({
    required this.currency,
    required this.total,
    required this.expenseCount,
    required this.members,
  });

  final String currency;
  final double total;
  final int expenseCount;

  /// Créateur d'abord, puis du plus gros payeur au plus petit.
  final List<MemberSummary> members;
}
