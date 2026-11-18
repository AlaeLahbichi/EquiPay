import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/activity.dart';
import '../../models/activity_overview.dart';
import '../../theme/app_colors.dart';
import '../../utils/money.dart';
import '../../widgets/user_avatar.dart';
import '../../l10n/i18n.dart';

/// Couleurs des participants dans les graphiques (dans l'ordre de la liste).
const chartPalette = [
  Color(0xFF0EA5A4),
  Color(0xFF6366F1),
  Color(0xFFF59E0B),
  Color(0xFFEC4899),
  Color(0xFF22C55E),
  Color(0xFF3B82F6),
  Color(0xFFEF4444),
  Color(0xFF8B5CF6),
  Color(0xFF14B8A6),
  Color(0xFFF97316),
];

Color chartColor(int index) => chartPalette[index % chartPalette.length];

/// Représentation graphique des dépenses selon les participants.
class ActivityChartPage extends StatefulWidget {
  const ActivityChartPage({super.key, required this.activity, required this.overview, this.currentUserId});

  final Activity activity;
  final ActivityOverview overview;
  final String? currentUserId;

  @override
  State<ActivityChartPage> createState() => _ActivityChartPageState();
}

enum _Measure {
  paid('Payé', 'Qui a avancé l\'argent'),
  owed('Part', 'Ce que chacun a consommé'),
  balance('Solde', 'Payé − part : + on lui doit, − il doit');

  const _Measure(this._label, this._hint);

  final String _label;

  String get label => _label.tr;
  final String _hint;
  String get hint => _hint.tr;
}

class _ActivityChartPageState extends State<ActivityChartPage> {
  var _measure = _Measure.paid;

  String _name(MemberSummary m) => m.profile.id == widget.currentUserId ? tr('Toi') : m.profile.displayName;

  double _value(MemberSummary m) => switch (_measure) {
    _Measure.paid => m.totalPaid,
    _Measure.owed => m.totalOwed,
    _Measure.balance => m.balance,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final overview = widget.overview;
    final currency = overview.currency;
    final members = overview.members;
    final total = overview.total;
    final values = [for (final m in members) _value(m)];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Dépenses par participant'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SegmentedButton<_Measure>(
            showSelectedIcon: false,
            segments: [for (final m in _Measure.values) ButtonSegment(value: m, label: Text(m.label))],
            selected: {_measure},
            onSelectionChanged: (s) => setState(() => _measure = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            _measure.hint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (total == 0)
            _ChartCard(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    Icon(Icons.pie_chart_outline_rounded, size: 48, color: colors.onSurfaceVariant),
                    const SizedBox(height: 8),
                    Text(
                      tr('Aucune dépense pour le moment :\nles graphiques apparaîtront dès la première.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            _ChartCard(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _measure == _Measure.balance
                    ? _BalanceBars(
                        key: const ValueKey('balance'),
                        names: [for (final m in members) _name(m)],
                        values: values,
                        currency: currency,
                      )
                    : _DonutWithLegend(
                        key: ValueKey(_measure),
                        names: [for (final m in members) _name(m)],
                        values: values,
                        currency: currency,
                        centerLabel: _measure == _Measure.paid ? tr('payé au total') : tr('consommé au total'),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            _ChartCard(
              title: tr('Payé et part de chacun'),
              child: _PaidVsOwed(members: members, currency: currency, nameOf: _name),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.child, this.title});

  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Text(title!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// Anneau de répartition, avec le total au centre et la légende dessous.
class _DonutWithLegend extends StatelessWidget {
  const _DonutWithLegend({
    super.key,
    required this.names,
    required this.values,
    required this.currency,
    required this.centerLabel,
  });

  final List<String> names;
  final List<double> values;
  final String currency;
  final String centerLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final total = values.fold<double>(0, (a, b) => a + math.max(b, 0));
    return Column(
      children: [
        SizedBox(
          height: 200,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (context, t, _) => CustomPaint(
              painter: DonutPainter(values: values, progress: t, track: colors.surfaceContainerHighest),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatMoney(total, currency),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                    Text(centerLabel, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        for (var i = 0; i < names.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(color: chartColor(i), borderRadius: BorderRadius.circular(4)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(names[i], overflow: TextOverflow.ellipsis)),
                Text(formatMoney(values[i], currency), style: const TextStyle(fontWeight: FontWeight.w700)),
                SizedBox(
                  width: 52,
                  child: Text(
                    total == 0 ? '—' : '${(math.max(values[i], 0) / total * 100).round()} %',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Anneau de répartition : un arc par valeur positive, dans les couleurs de [chartPalette].
class DonutPainter extends CustomPainter {
  DonutPainter({required this.values, required this.track, this.progress = 1});

  final List<double> values;
  final Color track;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = math.min(size.width, size.height) * 0.14;
    final radius = math.min(size.width, size.height) / 2 - stroke / 2;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = track);
    final total = values.fold<double>(0, (a, b) => a + math.max(b, 0));
    if (total == 0) return;
    // Petit espace entre les arcs quand il y en a plusieurs
    final positive = values.where((v) => v > 0).length;
    final gap = positive > 1 ? 0.03 : 0.0;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final sweep = values[i] / total * 2 * math.pi * progress;
      canvas.drawArc(rect, start + gap / 2, math.max(sweep - gap, 0.001), false, paint..color = chartColor(i));
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(DonutPainter old) => old.values != values || old.progress != progress || old.track != track;
}

/// Soldes en barres de part et d'autre de zéro : vert, on lui doit ; rouge, il doit.
class _BalanceBars extends StatelessWidget {
  const _BalanceBars({super.key, required this.names, required this.values, required this.currency});

  final List<String> names;
  final List<double> values;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final maxAbs = values.fold<double>(0, (a, b) => math.max(a, b.abs()));
    return Column(
      children: [
        for (var i = 0; i < names.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(names[i], overflow: TextOverflow.ellipsis)),
                    Text(
                      '${values[i] > 0 ? '+' : ''}${formatMoney(values[i], currency)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: values[i] > 0
                            ? AppColors.positive
                            : values[i] < 0
                            ? AppColors.negative
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 12,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final half = box.maxWidth / 2;
                      final width = maxAbs == 0 ? 0.0 : values[i].abs() / maxAbs * half;
                      return Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                          Positioned(
                            left: values[i] >= 0 ? half : half - width,
                            width: width,
                            top: 0,
                            bottom: 0,
                            child: TweenAnimationBuilder<double>(
                              tween: Tween(begin: 0, end: 1),
                              duration: const Duration(milliseconds: 500),
                              builder: (_, t, _) => FractionallySizedBox(
                                alignment: values[i] >= 0 ? Alignment.centerLeft : Alignment.centerRight,
                                widthFactor: t,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: values[i] >= 0 ? AppColors.positive : AppColors.negative,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: half - 1,
                            width: 2,
                            top: 0,
                            bottom: 0,
                            child: ColoredBox(color: colors.outline),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Pour chaque participant : barre « payé » et barre « part », à la même échelle.
class _PaidVsOwed extends StatelessWidget {
  const _PaidVsOwed({required this.members, required this.currency, required this.nameOf});

  final List<MemberSummary> members;
  final String currency;
  final String Function(MemberSummary) nameOf;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final maxValue = members.fold<double>(0, (a, m) => math.max(a, math.max(m.totalPaid, m.totalOwed)));
    Widget bar(double value, Color color, String label) => Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(label, style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: maxValue == 0 ? 0 : value / maxValue),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              builder: (_, t, _) =>
                  LinearProgressIndicator(value: t, minHeight: 10, color: color, backgroundColor: Colors.transparent),
            ),
          ),
        ),
        SizedBox(
          width: 96,
          child: Text(
            formatMoney(value, currency),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    return Column(
      children: [
        for (var i = 0; i < members.length; i++) ...[
          if (i > 0) const Divider(height: 22),
          Row(
            children: [
              UserAvatar(user: members[i].profile, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  nameOf(members[i]),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          bar(members[i].totalPaid, chartColor(i), tr('Payé')),
          const SizedBox(height: 4),
          bar(members[i].totalOwed, chartColor(i).withValues(alpha: 0.45), tr('Part')),
        ],
      ],
    );
  }
}
