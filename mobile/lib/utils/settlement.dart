import 'dart:math' as math;

import '../models/activity_overview.dart';

/// Un remboursement pour équilibrer les comptes : [from] donne [amount] à [to].
class Settlement {
  const Settlement(this.from, this.to, this.amount);

  final MemberSummary from;
  final MemberSummary to;
  final double amount;
}

/// Remboursements pour remettre tous les soldes à zéro, en un minimum de virements :
/// le plus gros débiteur rembourse le plus gros créancier, et ainsi de suite.
List<Settlement> settleUp(List<MemberSummary> members) {
  final debtors = [
    for (final m in members)
      if (m.balance < -0.005) (m, -m.balance),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final creditors = [
    for (final m in members)
      if (m.balance > 0.005) (m, m.balance),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final result = <Settlement>[];
  var d = 0;
  var c = 0;
  var owe = debtors.isEmpty ? 0.0 : debtors[0].$2;
  var due = creditors.isEmpty ? 0.0 : creditors[0].$2;
  while (d < debtors.length && c < creditors.length) {
    final amount = math.min(owe, due);
    if (amount >= 0.01) result.add(Settlement(debtors[d].$1, creditors[c].$1, (amount * 100).round() / 100));
    owe -= amount;
    due -= amount;
    if (owe < 0.005 && ++d < debtors.length) owe = debtors[d].$2;
    if (due < 0.005 && ++c < creditors.length) due = creditors[c].$2;
  }
  return result;
}
