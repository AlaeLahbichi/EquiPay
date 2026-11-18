import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/activity.dart';
import '../../models/activity_overview.dart';
import '../../theme/app_colors.dart';
import '../../utils/money.dart';
import '../../utils/settlement.dart';
import '../../widgets/user_avatar.dart';
import '../../l10n/i18n.dart';

/// Résumé de l'activité : pour chaque personne, à qui elle doit rembourser et de qui elle doit recevoir.
/// Les virements sont ceux de [settleUp] (le minimum pour remettre tous les soldes à zéro).
class ActivitySummaryPage extends StatelessWidget {
  const ActivitySummaryPage({super.key, required this.activity, required this.overview, this.currentUserId});

  final Activity activity;
  final ActivityOverview overview;
  final String? currentUserId;

  bool _isMe(MemberSummary m) => m.profile.id == currentUserId;

  String _name(MemberSummary m) => _isMe(m) ? tr('Toi') : m.profile.displayName;

  /// Toi d'abord, puis ceux qui doivent recevoir, puis ceux qui doivent rembourser.
  /// Les lecteurs sans aucune dépense ne sont pas listés.
  List<MemberSummary> _people() {
    final people = [
      for (final m in overview.members)
        if (m.role != MemberRole.viewer || m.totalPaid > 0 || m.totalOwed > 0) m,
    ];
    people.sort((a, b) {
      if (_isMe(a) != _isMe(b)) return _isMe(a) ? -1 : 1;
      return b.balance.compareTo(a.balance);
    });
    return people;
  }

  String _shareText(List<Settlement> settlements) {
    String money(double v) => formatMoney(v, overview.currency);
    final lines = [tr('Résumé « {0} »', [activity.name]), tr('Total des dépenses : {0}', [money(overview.total)]), ''];
    if (settlements.isEmpty) {
      lines.add(tr('Tout le monde est à jour.'));
    } else {
      for (final s in settlements) {
        lines.add(tr('• {0} doit {1} à {2}', [s.from.profile.displayName, money(s.amount), s.to.profile.displayName]));
      }
    }
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final settlements = settleUp(overview.members);
    final people = _people();
    String money(double v) => formatMoney(v, overview.currency);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Résumé')),
        actions: [
          if (overview.expenseCount > 0)
            IconButton(
              tooltip: tr('Copier le résumé'),
              icon: const Icon(Icons.copy_rounded),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _shareText(settlements)));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(tr('Résumé copié'))));
              },
            ),
        ],
      ),
      body: overview.expenseCount == 0
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.receipt_long_outlined, size: 56, color: colors.onSurfaceVariant),
                    const SizedBox(height: 12),
                    Text(
                      tr('Aucune dépense pour le moment :\nle résumé apparaîtra dès la première.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _Header(
                  total: money(overview.total),
                  expenseCount: overview.expenseCount,
                  transferCount: settlements.length,
                ),
                const SizedBox(height: 16),
                for (final person in people) ...[
                  _PersonCard(
                    person: person,
                    name: _name(person),
                    isMe: _isMe(person),
                    money: money,
                    pays: [
                      for (final s in settlements)
                        if (s.from.profile.id == person.profile.id) (_name(s.to), s.amount),
                    ],
                    receives: [
                      for (final s in settlements)
                        if (s.to.profile.id == person.profile.id) (_name(s.from), s.amount),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.total, required this.expenseCount, required this.transferCount});

  final String total;
  final int expenseCount;
  final int transferCount;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final settled = transferCount == 0;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: BorderRadius.circular(22)),
      child: Row(
        children: [
          Icon(settled ? Icons.verified_rounded : Icons.swap_horiz_rounded, size: 36, color: colors.onPrimaryContainer),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  settled
                      ? tr('Tout le monde est à jour')
                      : transferCount == 1
                      ? tr('1 remboursement pour tout équilibrer')
                      : tr('{0} remboursements pour tout équilibrer', [transferCount]),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: colors.onPrimaryContainer),
                ),
                const SizedBox(height: 4),
                Text(
                  tr('{0} · {1} dépense{2}', [total, expenseCount, expenseCount > 1 ? 's' : '']),
                  style: TextStyle(color: colors.onPrimaryContainer.withValues(alpha: 0.8)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({
    required this.person,
    required this.name,
    required this.isMe,
    required this.money,
    required this.pays,
    required this.receives,
  });

  final MemberSummary person;
  final String name;
  final bool isMe;
  final String Function(double) money;

  /// (à qui, combien)
  final List<(String, double)> pays;

  /// (de qui, combien)
  final List<(String, double)> receives;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final balance = person.balance;
    final (label, color) = balance > 0.005
        ? (tr('Doit recevoir {0}', [money(balance)]), AppColors.positive)
        : balance < -0.005
        ? (tr('Doit rembourser {0}', [money(-balance)]), AppColors.negative)
        : (tr('À jour'), AppColors.neutral);

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: isMe ? BorderSide(color: colors.primary, width: 1.5) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                UserAvatar(user: person.profile, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tr('A payé {0} · Sa part {1}', [money(person.totalPaid), money(person.totalOwed)]),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  label,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            if (pays.isNotEmpty || receives.isNotEmpty) const SizedBox(height: 8),
            for (final (to, amount) in pays)
              _TransferRow(
                icon: Icons.north_east_rounded,
                color: AppColors.negative,
                text: isMe ? tr('Tu rembourses {0}', [to]) : tr('Rembourse {0}', [to]),
                amount: money(amount),
              ),
            for (final (from, amount) in receives)
              _TransferRow(
                icon: Icons.south_west_rounded,
                color: AppColors.positive,
                text: isMe ? tr('Tu reçois de {0}', [from]) : tr('Reçoit de {0}', [from]),
                amount: money(amount),
              ),
          ],
        ),
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.icon, required this.color, required this.text, required this.amount});

  final IconData icon;
  final Color color;
  final String text;
  final String amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Text(
            amount,
            style: TextStyle(fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}
