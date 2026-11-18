import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/activity.dart';
import '../../models/activity_overview.dart';
import '../../models/expense.dart';
import '../../theme/app_colors.dart';
import '../../utils/dates.dart';
import '../../utils/money.dart';
import '../../utils/settlement.dart';
import '../../l10n/i18n.dart';


/// Insights de l'activité : chiffres clés, situation personnelle, évolution et remboursements.
class ActivityInsightsPage extends StatelessWidget {
  const ActivityInsightsPage({
    super.key,
    required this.activity,
    required this.overview,
    required this.expenses,
    this.currentUserId,
  });

  final Activity activity;
  final ActivityOverview overview;
  final List<Expense> expenses;
  final String? currentUserId;

  String _name(MemberSummary m) => m.profile.id == currentUserId ? tr('Toi') : m.profile.displayName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final currency = overview.currency;
    final total = overview.total;
    final count = expenses.length;
    final names = {for (final m in overview.members) m.profile.id: _name(m)};
    String money(double v) => formatMoney(v, currency);

    if (count == 0) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('Insights'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.insights_rounded, size: 52, color: colors.onSurfaceVariant),
                const SizedBox(height: 10),
                Text(
                  tr('Pas encore d\'insights : ajoute une première dépense pour voir les tendances de l\'activité.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final dates = expenses.map((e) => DateUtils.dateOnly(e.date)).toList()..sort();
    final days = dates.last.difference(dates.first).inDays + 1;
    final biggest = expenses.reduce((a, b) => a.convertedAmount >= b.convertedAmount ? a : b);
    final topPayer = overview.members.reduce((a, b) => a.totalPaid >= b.totalPaid ? a : b);
    final me = overview.members.where((m) => m.profile.id == currentUserId).firstOrNull;
    final settlements = settleUp(overview.members);

    // Total par mois, du plus ancien au plus récent
    final byMonth = <DateTime, double>{};
    for (final e in expenses) {
      final key = DateTime(e.date.year, e.date.month);
      byMonth[key] = (byMonth[key] ?? 0) + e.convertedAmount;
    }
    final months = byMonth.keys.toList()..sort();

    // Total par jour de la semaine (lundi = 0)
    final byWeekday = List<double>.filled(7, 0);
    for (final e in expenses) {
      byWeekday[e.date.weekday - 1] += e.convertedAmount;
    }
    final weekdays = weekdayNames();
    final busiestDay = byWeekday.indexOf(byWeekday.reduce(math.max));

    final otherCurrencies = {for (final e in expenses) e.currency}..remove(currency);
    final participants = overview.members.where((m) => m.totalOwed > 0).length;

    return Scaffold(
      appBar: AppBar(title: Text(tr('Insights'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _KpiGrid(
            children: [
              _Kpi(icon: Icons.account_balance_wallet_rounded, label: tr('Total'), value: money(total)),
              _Kpi(icon: Icons.receipt_long_rounded, label: tr('Dépenses'), value: '$count'),
              _Kpi(icon: Icons.functions_rounded, label: tr('Moyenne par dépense'), value: money(total / count)),
              _Kpi(
                icon: Icons.calendar_today_rounded,
                label: days == 1 ? tr('Sur 1 jour') : tr('Par jour ({0} jours)', [days]),
                value: money(total / days),
              ),
              if (participants > 0)
                _Kpi(icon: Icons.group_rounded, label: tr('Par participant'), value: money(total / participants)),
              _Kpi(icon: Icons.event_rounded, label: tr('Jour le plus dépensier'), value: weekdays[busiestDay]),
            ],
          ),
          if (me != null) ...[
            _Title(tr('Ta situation')),
            _Card(
              child: Column(
                children: [
                  _Line(label: tr('Tu as payé'), value: money(me.totalPaid)),
                  _Line(label: tr('Ta part'), value: money(me.totalOwed)),
                  const Divider(height: 20),
                  _Line(
                    label: me.balance > 0.005
                        ? tr('On te doit')
                        : me.balance < -0.005
                        ? tr('Tu dois')
                        : tr('Tu es à jour'),
                    value: me.balance.abs() < 0.005 ? '✓' : money(me.balance.abs()),
                    color: me.balance > 0.005
                        ? AppColors.positive
                        : me.balance < -0.005
                        ? AppColors.negative
                        : null,
                    bold: true,
                  ),
                  if (total > 0) ...[
                    const SizedBox(height: 12),
                    Text(
                      tr('Tu as avancé {0} % des dépenses '
                      'et ta part représente {1} % du total.', [(me.totalPaid / total * 100).round(), (me.totalOwed / total * 100).round()]),
                      style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
          _Title(tr('Pour équilibrer les comptes')),
          _Card(
            child: settlements.isEmpty
                ? Row(
                    children: [
                      const Icon(Icons.check_circle_rounded, color: AppColors.positive),
                      const SizedBox(width: 10),
                      Expanded(child: Text(tr('Tout le monde est à jour, aucun remboursement à faire.'))),
                    ],
                  )
                : Column(
                    children: [
                      for (final s in settlements)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: _name(s.from),
                                        style: const TextStyle(fontWeight: FontWeight.w700),
                                      ),
                                      TextSpan(text: s.from.profile.id == currentUserId ? tr(' donnes à ') : tr(' donne à ')),
                                      TextSpan(
                                        text: _name(s.to),
                                        style: const TextStyle(fontWeight: FontWeight.w700),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Text(
                                money(s.amount),
                                style: TextStyle(fontWeight: FontWeight.w800, color: colors.primary),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        tr('{0} virement{1} suffi'
                        '{2} à remettre tous les soldes à zéro.', [settlements.length, settlements.length > 1 ? 's' : '', settlements.length > 1 ? 'sent' : 't']),
                        style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
          ),
          _Title(tr('Faits marquants')),
          _Card(
            child: Column(
              children: [
                _Highlight(
                  icon: Icons.local_fire_department_rounded,
                  title: tr('Plus grosse dépense'),
                  text:
                      tr('{0} · {1}\n'
                      'Payée par {2}, {3}', [biggest.name, money(biggest.convertedAmount), names[biggest.paidBy] ?? tr('un ancien membre'), formatDate(biggest.date)]),
                ),
                const Divider(height: 22),
                _Highlight(
                  icon: Icons.emoji_events_rounded,
                  title: tr('Plus gros payeur'),
                  text:
                      '${_name(topPayer)} · ${money(topPayer.totalPaid)}'
                      '${total > 0 ? ' (${(topPayer.totalPaid / total * 100).round()} % du total)' : ''}',
                ),
                if (otherCurrencies.isNotEmpty) ...[
                  const Divider(height: 22),
                  _Highlight(
                    icon: Icons.currency_exchange_rounded,
                    title: tr('Devises utilisées'),
                    text:
                        tr('{0} · '
                        '{1} dépense(s) converties en {2}', [[currency, ...otherCurrencies].join(', '), expenses.where((e) => e.currency != currency).length, currency]),
                  ),
                ],
              ],
            ),
          ),
          if (months.length > 1) ...[
            _Title(tr('Dépenses par mois')),
            _Card(
              child: _Columns(
                labels: [
                  for (final m in months)
                    '${DateFormat.MMM(AppLanguage.current.name).format(m)}${m.year != DateTime.now().year ? ' ${m.year % 100}' : ''}',
                ],
                values: [for (final m in months) byMonth[m]!],
                format: money,
              ),
            ),
          ],
          _Title(tr('Par jour de la semaine')),
          _Card(
            child: _Columns(labels: weekdays, values: byWeekday, format: money, highlight: busiestDay),
          ),
        ],
      ),
    );
  }
}

/// Chiffres clés sur deux colonnes (sans défilement propre, dans la liste de la page).
class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = (box.maxWidth - 10) / 2;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [for (final child in children) SizedBox(width: width, height: width / 1.55, child: child)],
      );
    },
  );
}

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
    child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: colors.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, size: 20, color: colors.primary),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, this.color, this.bold = false});

  final String label;
  final String value;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null)),
        ),
        Text(
          value,
          style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color),
        ),
      ],
    ),
  );
}

class _Highlight extends StatelessWidget {
  const _Highlight({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.accent.withValues(alpha: 0.15),
          child: Icon(icon, size: 20, color: AppColors.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Histogramme vertical simple ; toucher une colonne affiche son montant.
class _Columns extends StatefulWidget {
  const _Columns({required this.labels, required this.values, required this.format, this.highlight});

  final List<String> labels;
  final List<double> values;
  final String Function(double) format;
  final int? highlight;

  @override
  State<_Columns> createState() => _ColumnsState();
}

class _ColumnsState extends State<_Columns> {
  late int? _selected = widget.highlight ?? widget.values.length - 1;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final values = widget.values;
    final maxValue = values.fold<double>(0, math.max);
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          selected == null ? ' ' : '${widget.labels[selected]} · ${widget.format(values[selected])}',
          style: TextStyle(fontWeight: FontWeight.w700, color: colors.primary),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < values.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _selected = i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: maxValue == 0 ? 0 : values[i] / maxValue),
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOutCubic,
                          builder: (_, t, _) => Container(
                            height: math.max(110 * t, values[i] > 0 ? 3 : 0),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: i == selected ? colors.primary : colors.primary.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.labels[i],
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
