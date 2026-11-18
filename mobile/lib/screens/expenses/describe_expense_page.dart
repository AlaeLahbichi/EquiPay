import 'package:flutter/material.dart';

import '../../models/plan.dart';
import '../../models/activity.dart';
import '../../models/activity_overview.dart';
import '../../services/expense_describer.dart';
import '../../utils/money.dart';
import '../plans/plans_page.dart';
import '../../l10n/i18n.dart';

/// « Décrire la dépense » : l'utilisateur écrit une phrase, le modèle la comprend.
/// Renvoie la dépense comprise (DescribedExpense) pour pré-remplir le formulaire ; null si annulé.
class DescribeExpensePage extends StatefulWidget {
  const DescribeExpensePage({
    super.key,
    required this.activity,
    required this.members,
    required this.currentUserId,
    this.describer,
  });

  final Activity activity;
  final List<MemberSummary> members;
  final String currentUserId;

  /// null : service partagé de l'app.
  final ExpenseDescriber? describer;

  @override
  State<DescribeExpensePage> createState() => _DescribeExpensePageState();
}

class _DescribeExpensePageState extends State<DescribeExpensePage> with SingleTickerProviderStateMixin {
  final _text = TextEditingController();
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  var _loading = false;
  String? _error;
  var _limited = false;
  var _run = 0;

  /// Les spectateurs ne participent pas aux dépenses : le modèle ne les voit pas.
  late final _eligible = widget.members.where((m) => m.role != MemberRole.viewer).toList();

  /// Un autre participant, pour des exemples avec de vrais prénoms.
  late final String _friend = _eligible
      .where((m) => m.profile.id != widget.currentUserId)
      .map((m) => m.profile.displayName.split(' ').first)
      .firstWhere((_) => true, orElse: () => tr('Sara'));

  late final _examples = [
    tr('Resto avec {0}, j\'ai payé {1} hier, 60/40', [_friend, _amount(45)]),
    tr('Courses {0} pour tout le monde sauf {1}', [_amount(32.5), _friend]),
    tr('{0} a payé le taxi {1} pour nous deux', [_friend, _amount(18)]),
  ];

  String _amount(double v) => formatMoney(v, widget.activity.currency).replaceAll(',00', '');

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final sentence = _text.text.trim();
    if (sentence.isEmpty || _loading) return;
    FocusScope.of(context).unfocus();
    final run = ++_run;
    setState(() {
      _loading = true;
      _error = null;
    });
    _pulse.repeat(reverse: true);
    try {
      final result = await (widget.describer ?? ExpenseDescriber.instance).describe(
        sentence: sentence,
        members: {for (final m in _eligible) m.profile.id: m.profile.displayName},
        currency: widget.activity.currency,
      );
      if (!mounted || run != _run) return;
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted || run != _run) return;
      _pulse.stop();
      setState(() {
        _loading = false;
        _limited = e is PlanLimitException;
        _error = switch (e) {
          DescribeException() => e.message,
          PlanLimitException() => e.message,
          _ => tr('L\'assistant est indisponible. Réessaie.'),
        };
      });
      if (_limited) _upgrade();
    }
  }

  void _cancel() {
    _run++;
    _pulse.stop();
    setState(() => _loading = false);
  }

  /// Quota du mois atteint : propose l'offre supérieure.
  Future<void> _upgrade() => showUpgradeSheet(context, message: _error ?? '', feature: PlanFeature.describe);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final names = [
      for (final m in _eligible) m.profile.id == widget.currentUserId ? 'toi' : m.profile.displayName.split(' ').first,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Décrire la dépense'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.auto_awesome_rounded, color: colors.tertiary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('Raconte la dépense comme à un ami : quoi, combien, qui a payé, pour qui et comment partager. '
                  'L\'assistant remplit le formulaire, tu vérifies avant d\'ajouter.'),
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _text,
            autofocus: true,
            enabled: !_loading,
            minLines: 4,
            maxLines: 7,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: _examples.first,
              border: const OutlineInputBorder(),
              helperText: tr('Une seule dépense par phrase'),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            tr('Membres : {0} · devise {1}', [names.join(', '), widget.activity.currency]),
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          if (_loading)
            _Thinking(animation: _pulse, onCancel: _cancel)
          else ...[
            if (_error != null)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: colors.errorContainer, borderRadius: BorderRadius.circular(14)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, color: colors.onErrorContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_error!, style: TextStyle(color: colors.onErrorContainer)),
                    ),
                  ],
                ),
              ),
            if (_error != null && _limited)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: FilledButton.icon(
                  onPressed: _upgrade,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.workspace_premium_rounded),
                  label: Text(tr('Passer à l\'offre supérieure')),
                ),
              ),
            Text(
              tr('Exemples'),
              style: TextStyle(fontWeight: FontWeight.w700, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            for (final example in _examples)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: colors.tertiary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _text.text = example,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          Icon(Icons.format_quote_rounded, size: 18, color: colors.tertiary),
                          const SizedBox(width: 8),
                          Expanded(child: Text(example)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _loading || _text.text.trim().isEmpty ? null : _submit,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(tr('Remplir la dépense'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}

/// Chargement : étincelles qui pulsent pendant que le modèle lit la phrase.
class _Thinking extends StatelessWidget {
  const _Thinking({required this.animation, required this.onCancel});

  final Animation<double> animation;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const SizedBox(height: 12),
        AnimatedBuilder(
          animation: animation,
          builder: (_, _) => Transform.scale(
            scale: 0.85 + 0.3 * animation.value,
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.tertiary.withValues(alpha: 0.10 + 0.12 * animation.value),
              ),
              child: Icon(Icons.auto_awesome_rounded, size: 36, color: colors.tertiary),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(tr('L\'assistant lit ta phrase…'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(tr('Montant, date, payeur, participants et répartition'), style: TextStyle(color: colors.onSurfaceVariant)),
        const SizedBox(height: 8),
        TextButton(onPressed: onCancel, child: Text(tr('Annuler'))),
      ],
    );
  }
}
