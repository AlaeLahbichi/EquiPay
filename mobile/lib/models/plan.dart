import 'package:flutter/material.dart';
import '../l10n/i18n.dart';

/// Ce qui est limité selon l'offre. Les quotas d'IA sont mensuels.
enum PlanFeature {
  activities('Activités en cours', Icons.luggage_rounded),
  scan('Scans de tickets', Icons.document_scanner_rounded),
  describe('Dépenses décrites en une phrase', Icons.auto_awesome_rounded),
  trip('Trajets organisés par l\'IA', Icons.route_rounded);

  const PlanFeature(this._label, this.icon);

  final String _label;
  String get label => _label.tr;
  final IconData icon;

  /// Quota remis à zéro chaque mois (les activités : nombre d'activités en cours, non archivées).
  bool get monthly => this != PlanFeature.activities;

  /// Ce que permet une limite, ex. « 30 scans de tickets par mois ».
  String allowance(int? limit) {
    if (limit == null) {
      return switch (this) {
        PlanFeature.activities => tr('Activités en cours illimitées'),
        PlanFeature.scan => tr('Scans de tickets illimités'),
        PlanFeature.describe => tr('Dépenses en une phrase illimitées'),
        PlanFeature.trip => tr('Trajets organisés illimités'),
      };
    }
    return switch (this) {
      PlanFeature.activities => tr('{0} activités en cours', [limit]),
      PlanFeature.scan => tr('{0} scans de tickets par mois', [limit]),
      PlanFeature.describe => tr('{0} dépenses en une phrase par mois', [limit]),
      PlanFeature.trip => tr('{0} trajets organisés par mois', [limit]),
    };
  }
}

/// Offres d'EquiPay : une gratuite et trois payantes.
/// Les limites sont les mêmes que la fonction plan_limit de Supabase, qui les applique.
enum Plan {
  free('Gratuit', 0, 'Pour essayer avec quelques amis', Color(0xFF64748B), {
    PlanFeature.activities: 3,
    PlanFeature.scan: 5,
    PlanFeature.describe: 10,
    PlanFeature.trip: 2,
  }),
  plus('Plus', 19, 'Pour les sorties et les week-ends', Color(0xFF0D9488), {
    PlanFeature.activities: 10,
    PlanFeature.scan: 30,
    PlanFeature.describe: 60,
    PlanFeature.trip: 10,
  }),
  pro('Pro', 39, 'Pour ceux qui voyagent souvent', Color(0xFF8B5CF6), {
    PlanFeature.activities: null,
    PlanFeature.scan: 100,
    PlanFeature.describe: 200,
    PlanFeature.trip: 40,
  }),
  premium('Premium', 69, 'Tout illimité, sans compter', Color(0xFFF97316), {
    PlanFeature.activities: null,
    PlanFeature.scan: null,
    PlanFeature.describe: null,
    PlanFeature.trip: null,
  });

  const Plan(this._label, this.monthlyPrice, this._tagline, this.color, this.limits);

  final String _label;

  String get label => _label.tr;

  /// Prix mensuel en dirhams (0 : gratuit).
  final int monthlyPrice;
  final String _tagline;
  String get tagline => _tagline.tr;
  final Color color;

  /// null : illimité.
  final Map<PlanFeature, int?> limits;

  /// Prix annuel : deux mois offerts.
  int get yearlyPrice => monthlyPrice * 10;

  bool get isPaid => this != Plan.free;

  /// Graphiques et statistiques des dépenses : à partir de Plus.
  bool get hasInsights => this != Plan.free;

  /// Budget : budgets par catégorie et objectifs d'épargne, à partir de Plus.
  bool get hasBudgetTools => this != Plan.free;

  /// Mois consultables dans l'historique du budget (null : illimité).
  int? get budgetHistoryMonths => this == Plan.free ? 3 : null;

  int? limit(PlanFeature feature) => limits[feature];

  /// Offre conseillée pour aller plus loin (null pour Premium).
  Plan? get next => index + 1 < Plan.values.length ? Plan.values[index + 1] : null;

  /// Première offre supérieure qui donne plus pour [feature] (null : graphiques, ou aucune).
  Plan? upgradeFor(PlanFeature? feature) {
    for (final p in Plan.values.skip(index + 1)) {
      if (feature == null) return p.hasInsights ? p : null;
      final mine = limit(feature);
      final theirs = p.limit(feature);
      if (mine != null && (theirs == null || theirs > mine)) return p;
    }
    return null;
  }

  /// Message quand la limite de [feature] est atteinte, dans la langue de l'app.
  String limitMessage(PlanFeature feature) {
    final n = limit(feature);
    final upgrade = upgradeFor(feature);
    final head = feature == PlanFeature.activities
        ? tr('Ton offre {0} permet {1} activités en cours.', [label, n])
        : tr('Tu as utilisé tout ton quota du mois avec l\'offre {0} : {1}.', [label, feature.allowance(n)]);
    if (upgrade == null) {
      return feature == PlanFeature.activities
          ? '$head ${tr('Archive une activité terminée pour en créer une nouvelle.')}'
          : head;
    }
    final tail = feature == PlanFeature.activities
        ? tr('Passe à l\'offre {0} ({1}), ou archive une activité terminée.', [
            upgrade.label,
            feature.allowance(upgrade.limit(feature)),
          ])
        : tr('Passe à l\'offre {0} ({1}) pour continuer.', [upgrade.label, feature.allowance(upgrade.limit(feature))]);
    return '$head $tail';
  }

  static Plan fromName(String? name) => Plan.values.firstWhere((p) => p.name == name, orElse: () => Plan.free);
}

/// Consommation d'une fonction pendant la période.
class FeatureUsage {
  const FeatureUsage({required this.used, this.limit});

  final int used;

  /// null : illimité.
  final int? limit;

  bool get reached => limit != null && used >= limit!;

  /// Part utilisée, entre 0 et 1 (0 si illimité).
  double get ratio => limit == null || limit == 0 ? 0 : (used / limit!).clamp(0, 1).toDouble();
}

/// Offre de l'utilisateur et consommation du mois.
class PlanUsage {
  const PlanUsage({required this.plan, required this.features, this.since});

  final Plan plan;
  final DateTime? since;
  final Map<PlanFeature, FeatureUsage> features;

  factory PlanUsage.fromJson(Map<String, dynamic> j) {
    final plan = Plan.fromName(j['plan'] as String?);
    final raw = (j['features'] as Map?) ?? const {};
    return PlanUsage(
      plan: plan,
      since: j['plan_since'] == null ? null : DateTime.parse(j['plan_since'] as String),
      features: {
        for (final f in PlanFeature.values)
          f: FeatureUsage(
            used: ((raw[f.name] as Map?)?['used'] as num?)?.toInt() ?? 0,
            limit: ((raw[f.name] as Map?)?['limit'] as num?)?.toInt(),
          ),
      },
    );
  }
}

/// Une fonction d'IA a atteint la limite de l'offre (réponse 402 du backend).
class PlanLimitException implements Exception {
  const PlanLimitException(this.message, {this.feature});

  final String message;
  final PlanFeature? feature;

  /// Lit la réponse 402 du backend : { detail: { message, feature } }.
  static PlanLimitException? fromBody(int status, Object? body) {
    if (status != 402) return null;
    final detail = body is Map ? body['detail'] : null;
    if (detail is Map) {
      final feature = PlanFeature.values.where((f) => f.name == detail['feature']).firstOrNull;
      final plan = Plan.values.where((p) => p.name == detail['plan']).firstOrNull;
      // Message reconstruit dans la langue de l'app (celui du serveur est en français)
      final message = feature != null && plan != null
          ? plan.limitMessage(feature)
          : detail['message'] as String? ?? tr('Limite de ton offre atteinte.');
      return PlanLimitException(message, feature: feature);
    }
    return PlanLimitException(detail is String ? detail : tr('Limite de ton offre atteinte.'));
  }

  @override
  String toString() => message;
}
