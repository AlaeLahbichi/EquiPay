import 'package:flutter/material.dart';

import '../../models/plan.dart';
import '../../services/account_service.dart';
import '../../services/activity_repository.dart';
import '../../utils/dates.dart';
import '../../l10n/i18n.dart';

/// Ouvre la page des offres.
Future<void> openPlans(BuildContext context, {bool welcome = false}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlansPage(welcome: welcome)));

/// Dégradé d'une offre payante (cartes, bandeaux).
LinearGradient planGradient(Plan plan) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [plan.color, Color.lerp(plan.color, Colors.black, 0.25)!],
);

void _snack(BuildContext context, String message) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)));

/// Confirme puis passe à [plan] (mode démonstration : aucun paiement). Renvoie true si c'est fait.
/// [onConfirmed] : appelé une fois la confirmation donnée, avant l'enregistrement (indicateur de chargement).
Future<bool> upgradeTo(
  BuildContext context,
  Plan plan, {
  AccountService? account,
  bool yearly = false,
  VoidCallback? onConfirmed,
}) async {
  final service = account ?? AccountService.instance;
  if (service.state.value == null) {
    _snack(context, tr('Connecte-toi pour choisir une offre.'));
    return false;
  }
  final price = yearly ? tr('{0} DH / an', [plan.yearlyPrice]) : tr('{0} DH / mois', [plan.monthlyPrice]);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.workspace_premium_rounded, color: plan.color, size: 34),
      title: Text(tr('Passer à {0}', [plan.label])),
      content: Text(
        tr('{0}, sans engagement : tu peux résilier à tout moment depuis Profil > Mon offre.\n\n'
        'Mode démonstration : aucun paiement n\'est demandé. Le paiement par l\'App Store ou Google Play '
        'sera ajouté à la publication de l\'app.', [price]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annuler'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: plan.color),
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr('Confirmer')),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  onConfirmed?.call();
  try {
    await service.choosePlan(plan);
    if (context.mounted) _snack(context, tr('Bienvenue dans l\'offre {0} !', [plan.label]));
    return true;
  } catch (e) {
    if (context.mounted) _snack(context, friendlyError(e));
    return false;
  }
}

/// Résiliation : une confirmation, puis retour immédiat à l'offre Gratuite.
Future<bool> cancelSubscription(BuildContext context, {AccountService? account}) async {
  final service = account ?? AccountService.instance;
  final plan = service.state.value?.plan;
  if (plan == null || !plan.isPaid) return false;
  final colors = Theme.of(context).colorScheme;
  final lost = [
    for (final f in PlanFeature.values)
      if (plan.limit(f) != Plan.free.limit(f)) tr('{0} au lieu de {1}', [f.allowance(Plan.free.limit(f)), plan.limit(f) ?? '∞']),
    tr('Plus de graphiques ni de statistiques'),
  ];
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.cancel_outlined, color: colors.error, size: 34),
      title: Text(tr('Résilier l\'offre {0} ?', [plan.label])),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('Tu reviens à l\'offre Gratuite. Tes activités et tes dépenses sont conservées.')),
          const SizedBox(height: 12),
          for (final line in lost)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.remove_circle_outline_rounded, size: 18, color: colors.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(line, style: const TextStyle(fontSize: 14))),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Garder {0}', [plan.label]))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: colors.error, foregroundColor: colors.onError),
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr('Résilier')),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  try {
    await service.cancelPlan();
    if (context.mounted) _snack(context, tr('Abonnement résilié. Tu es revenu à l\'offre Gratuite.'));
    return true;
  } catch (e) {
    if (context.mounted) _snack(context, friendlyError(e));
    return false;
  }
}

/// Limite atteinte : explique ce que débloque l'offre supérieure et propose d'y passer tout de suite.
/// [feature] null : graphiques et statistiques.
Future<void> showUpgradeSheet(BuildContext context, {required String message, String? title, PlanFeature? feature}) {
  final current = AccountService.instance.state.value?.plan ?? Plan.free;
  final next = current.upgradeFor(feature) ?? current.next;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final colors = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: (next ?? Plan.pro).color.withValues(alpha: 0.14),
                child: Icon(Icons.rocket_launch_rounded, color: (next ?? Plan.pro).color, size: 32),
              ),
              const SizedBox(height: 14),
              Text(
                title ?? tr('Limite de ton offre atteinte'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              if (next != null) ...[
                const SizedBox(height: 18),
                _UpgradeCompare(current: current, next: next, feature: feature),
                const SizedBox(height: 18),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: next.color,
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  onPressed: () async {
                    if (await upgradeTo(sheetContext, next) && sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                  icon: const Icon(Icons.workspace_premium_rounded),
                  label: Text(tr('Passer à {0} · {1} DH/mois', [next.label, next.monthlyPrice])),
                ),
              ],
              const SizedBox(height: 6),
              TextButton(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  openPlans(context);
                },
                child: Text(tr('Comparer toutes les offres')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: Text(tr('Plus tard'), style: TextStyle(color: colors.onSurfaceVariant)),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// « Gratuit : 5 scans → Plus : 30 scans ».
class _UpgradeCompare extends StatelessWidget {
  const _UpgradeCompare({required this.current, required this.next, required this.feature});

  final Plan current;
  final Plan next;
  final PlanFeature? feature;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final f = feature;
    final now = f == null ? tr('Sans graphiques') : f.allowance(current.limit(f));
    final then = f == null ? tr('Graphiques et statistiques') : f.allowance(next.limit(f));
    Widget side(Plan plan, String text, {required bool highlight}) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: highlight ? planGradient(plan) : null,
          color: highlight ? null : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text(
              plan.label,
              style: TextStyle(fontWeight: FontWeight.w800, color: highlight ? Colors.white : colors.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: highlight ? Colors.white : colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          side(current, now, highlight: false),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.arrow_forward_rounded, color: next.color),
          ),
          side(next, then, highlight: true),
        ],
      ),
    );
  }
}

/// Les quatre offres, l'abonnement en cours (avec la résiliation) et la consommation du mois.
class PlansPage extends StatefulWidget {
  const PlansPage({super.key, this.welcome = false, this.account});

  /// Affichée juste après le formulaire de bienvenue : propose de commencer gratuitement.
  final bool welcome;
  final AccountService? account;

  @override
  State<PlansPage> createState() => _PlansPageState();
}

class _PlansPageState extends State<PlansPage> {
  AccountService get _account => widget.account ?? AccountService.instance;
  var _yearly = false;
  PlanUsage? _usage;
  Plan? _busy;

  @override
  void initState() {
    super.initState();
    _loadUsage();
  }

  Future<void> _loadUsage() async {
    if (_account.state.value == null) return;
    try {
      final usage = await _account.usage();
      if (mounted) setState(() => _usage = usage);
    } catch (_) {
      // Consommation indisponible (hors ligne) : les offres restent affichées
    }
  }

  Future<void> _choose(Plan plan) async {
    final done = await upgradeTo(
      context,
      plan,
      account: _account,
      yearly: _yearly,
      onConfirmed: () => setState(() => _busy = plan),
    );
    if (!mounted) return;
    setState(() => _busy = null);
    if (!done) return;
    await _loadUsage();
    if (mounted && widget.welcome) Navigator.pop(context);
  }

  Future<void> _cancel() async {
    if (await cancelSubscription(context, account: _account)) await _loadUsage();
  }

  String _price(Plan plan) {
    if (!plan.isPaid) return tr('0 DH');
    return _yearly ? tr('{0} DH / an', [plan.yearlyPrice]) : tr('{0} DH / mois', [plan.monthlyPrice]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.welcome ? tr('Choisis ton offre') : tr('Nos offres'))),
      body: ValueListenableBuilder<AccountState?>(
        valueListenable: _account.state,
        builder: (context, state, _) {
          final current = state?.plan;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              if (state != null && state.plan.isPaid)
                _SubscriptionCard(state: state, onCancel: _cancel)
              else
                _Hero(welcome: widget.welcome),
              const SizedBox(height: 18),
              Center(
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: Text(tr('Mensuel'))),
                    ButtonSegment(value: true, label: Text(tr('Annuel · 2 mois offerts'))),
                  ],
                  selected: {_yearly},
                  onSelectionChanged: (s) => setState(() => _yearly = s.first),
                ),
              ),
              const SizedBox(height: 16),
              // Abonnés : l'offre Gratuite n'est pas proposée ici, on y revient en résiliant
              for (final plan in Plan.values)
                if (plan.isPaid || current == null || current == Plan.free)
                  _PlanCard(
                    plan: plan,
                    price: _price(plan),
                    current: plan == current,
                    popular: plan == Plan.pro,
                    busy: _busy == plan,
                    onChoose: _busy == null && plan != current ? () => _choose(plan) : null,
                  ),
              if (_usage != null) ...[const SizedBox(height: 4), _UsageCard(usage: _usage!)],
              if (widget.welcome) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('Commencer gratuitement')),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                tr('Prix en dirhams, sans engagement : résiliable à tout moment depuis Profil > Mon offre. '
                'L\'assistant d\'aide reste illimité dans toutes les offres.'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// En-tête pour les utilisateurs de l'offre Gratuite.
class _Hero extends StatelessWidget {
  const _Hero({required this.welcome});

  final bool welcome;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Plan.plus.color, Plan.pro.color, Plan.premium.color],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 30),
          const SizedBox(height: 10),
          Text(
            welcome ? tr('Bienvenue ! Choisis ton offre') : tr('Débloque tout EquiPay'),
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            welcome
                ? tr('Commence gratuitement, et passe à une offre supérieure quand tu en as besoin.')
                : tr('Plus d\'activités en cours, plus de scans et de trajets organisés par l\'IA, '
                      'et des statistiques détaillées.'),
            style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.35),
          ),
        ],
      ),
    );
  }
}

/// Abonnement payant en cours, avec la résiliation.
class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.state, required this.onCancel});

  final AccountState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final plan = state.plan;
    final since = state.planSince;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), gradient: planGradient(plan)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('Mon abonnement {0}', [plan.label]),
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            [
              tr('{0} DH / mois', [plan.monthlyPrice]),
              if (since != null) tr('actif depuis le {0}', [formatDate(since.toLocal())]),
              tr('sans engagement'),
            ].join(' · '),
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: onCancel,
              icon: const Icon(Icons.cancel_outlined, size: 20),
              label: Text(tr('Résilier l\'abonnement'), style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.price,
    required this.current,
    required this.popular,
    required this.busy,
    required this.onChoose,
  });

  final Plan plan;
  final String price;
  final bool current;
  final bool popular;
  final bool busy;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final paid = plan.isPaid;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: paid || current ? plan.color : colors.outlineVariant,
          width: popular || current ? 2.5 : 1.2,
        ),
        boxShadow: popular
            ? [BoxShadow(color: plan.color.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 6))]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // En-tête coloré : nom, accroche et prix
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            decoration: BoxDecoration(gradient: paid ? planGradient(plan) : null),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      paid ? Icons.workspace_premium_rounded : Icons.person_outline_rounded,
                      color: paid ? Colors.white : plan.color,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        plan.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: paid ? Colors.white : plan.color,
                        ),
                      ),
                    ),
                    if (current)
                      _Badge(text: tr('Ton offre'), paid: paid, color: plan.color)
                    else if (popular)
                      _Badge(text: tr('★ Le plus populaire'), paid: paid, color: plan.color),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  plan.tagline,
                  style: TextStyle(color: paid ? Colors.white.withValues(alpha: 0.9) : colors.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Text(
                  price,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: paid ? Colors.white : null),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final f in PlanFeature.values)
                  _Check(text: f.allowance(plan.limit(f)), ok: true, color: plan.color),
                _Check(text: tr('Graphiques et statistiques'), ok: plan.hasInsights, color: plan.color),
                _Check(text: tr('Programme de voyage, votes et carte'), ok: true, color: plan.color),
                if (paid) ...[
                  const SizedBox(height: 12),
                  current
                      ? OutlinedButton(onPressed: null, child: Text(tr('Offre actuelle')))
                      : FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: plan.color,
                            minimumSize: const Size.fromHeight(50),
                            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                          onPressed: onChoose,
                          child: busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                                )
                              : Text(tr('Choisir {0}', [plan.label])),
                        ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.paid, required this.color});

  final String text;
  final bool paid;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: paid ? Colors.white : color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12),
    ),
  );
}

class _Check extends StatelessWidget {
  const _Check({required this.text, required this.ok, required this.color});

  final String text;
  final bool ok;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.remove_circle_outline_rounded,
            size: 19,
            color: ok ? color : colors.outline,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: ok ? null : colors.outline, decoration: ok ? null : TextDecoration.lineThrough),
            ),
          ),
        ],
      ),
    );
  }
}

/// Consommation de l'utilisateur.
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.usage});

  final PlanUsage usage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Ta consommation'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(
              tr('Activités en cours, et utilisations de l\'IA ce mois-ci'),
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final f in PlanFeature.values) ...[
              Row(
                children: [
                  Icon(f.icon, size: 18, color: colors.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f.label)),
                  Text(
                    usage.features[f]!.limit == null
                        ? tr('{0} · illimité', [usage.features[f]!.used])
                        : '${usage.features[f]!.used} / ${usage.features[f]!.limit}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: usage.features[f]!.reached ? colors.error : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: usage.features[f]!.limit == null ? 0 : usage.features[f]!.ratio,
                  minHeight: 6,
                  color: usage.features[f]!.reached ? colors.error : usage.plan.color,
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}
