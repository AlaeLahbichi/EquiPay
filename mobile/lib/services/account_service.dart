import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/plan.dart';
import 'auth_service.dart';
import 'offline_store.dart';

/// Ce que l'app sait du compte au-delà du profil : offre et formulaire de bienvenue.
class AccountState {
  const AccountState({required this.plan, required this.onboarded, this.defaultCurrency, this.planSince});

  final Plan plan;

  /// Début de l'abonnement payant en cours.
  final DateTime? planSince;

  /// false : le formulaire de bienvenue n'a pas encore été rempli.
  final bool onboarded;

  /// Devise proposée par défaut à la création d'une activité.
  final String? defaultCurrency;
}

/// Réponses du formulaire de bienvenue.
class OnboardingAnswers {
  const OnboardingAnswers({
    required this.fullName,
    required this.username,
    required this.currency,
    this.country,
    this.usages = const [],
    this.referral,
  });

  final String fullName;
  final String username;
  final String currency;
  final String? country;
  final List<String> usages;
  final String? referral;
}

abstract class AccountService {
  /// Service de l'app (remplacé dans main.dart). Par défaut : compte de démonstration
  /// déjà accueilli, avec l'offre Premium, pour que rien ne soit bloqué dans les tests.
  static AccountService instance = MemoryAccountService();

  /// null : visiteur, ou compte pas encore chargé.
  ValueListenable<AccountState?> get state;

  Future<void> refresh();

  /// Offre et consommation du mois.
  Future<PlanUsage> usage();

  /// Mode démonstration : aucun paiement n'est encaissé.
  Future<void> choosePlan(Plan plan);

  /// Résilie l'abonnement : retour immédiat à l'offre Gratuite.
  Future<void> cancelPlan();

  Future<void> completeOnboarding(OnboardingAnswers answers);
}

class SupabaseAccountService implements AccountService {
  SupabaseAccountService(this._client, AuthService auth) {
    auth.user.addListener(() => refresh());
    refresh();
  }

  final SupabaseClient _client;
  final _state = ValueNotifier<AccountState?>(null);

  static const _timeout = Duration(seconds: 20);

  @override
  ValueListenable<AccountState?> get state => _state;

  @override
  Future<void> refresh() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      _state.value = null;
      return;
    }
    try {
      // Hors ligne : la dernière offre connue (les limites sont de toute façon vérifiées par le serveur)
      final row = await OfflineStore.instance.fetch(
        'account:${user.id}',
        () => _client
            .from('profiles')
            .select('plan, plan_since, onboarded_at, default_currency')
            .eq('id', user.id)
            .maybeSingle()
            .timeout(_timeout),
        (json) => json == null ? null : Map<String, dynamic>.from(json as Map),
      );
      if (row == null || _client.auth.currentUser?.id != user.id) return;
      _state.value = AccountState(
        plan: Plan.fromName(row['plan'] as String?),
        planSince: DateTime.tryParse(row['plan_since'] as String? ?? ''),
        onboarded: row['onboarded_at'] != null,
        defaultCurrency: row['default_currency'] as String?,
      );
    } catch (_) {
      // Hors ligne sans copie ou colonnes absentes : on garde l'état connu (le formulaire n'est pas imposé)
    }
  }

  @override
  Future<PlanUsage> usage() async {
    final res = await _client.rpc('my_plan_usage').timeout(_timeout);
    return PlanUsage.fromJson(Map<String, dynamic>.from(res as Map));
  }

  @override
  Future<void> choosePlan(Plan plan) async {
    await _client.rpc('choose_plan', params: {'p_plan': plan.name}).timeout(_timeout);
    await refresh();
  }

  @override
  Future<void> cancelPlan() async {
    await _client.rpc('cancel_plan').timeout(_timeout);
    await refresh();
  }

  @override
  Future<void> completeOnboarding(OnboardingAnswers a) async {
    final uid = _client.auth.currentUser!.id;
    try {
      await _client
          .from('profiles')
          .update({
            'full_name': a.fullName.trim(),
            'username': a.username.trim().toLowerCase(),
            'default_currency': a.currency,
            'country': (a.country ?? '').trim().isEmpty ? null : a.country!.trim(),
            'usages': a.usages,
            'referral': a.referral,
            'onboarded_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', uid)
          .timeout(_timeout);
    } on PostgrestException catch (e) {
      if (e.code == '23505') throw UsernameTakenException();
      rethrow;
    }
    await refresh();
  }
}

/// Compte gardé en mémoire (tests, aperçu).
class MemoryAccountService implements AccountService {
  MemoryAccountService({Plan plan = Plan.premium, bool onboarded = true, Map<PlanFeature, int>? used})
    : _used = {...?used},
      _state = ValueNotifier(AccountState(plan: plan, onboarded: onboarded));

  final ValueNotifier<AccountState?> _state;
  final Map<PlanFeature, int> _used;
  OnboardingAnswers? lastAnswers;

  @override
  ValueListenable<AccountState?> get state => _state;

  Plan get _plan => _state.value?.plan ?? Plan.free;

  @override
  Future<void> refresh() async {}

  @override
  Future<PlanUsage> usage() async => PlanUsage(
    plan: _plan,
    features: {for (final f in PlanFeature.values) f: FeatureUsage(used: _used[f] ?? 0, limit: _plan.limit(f))},
  );

  @override
  Future<void> choosePlan(Plan plan) async {
    final s = _state.value;
    _state.value = AccountState(
      plan: plan,
      planSince: plan.isPaid ? DateTime.now() : null,
      onboarded: s?.onboarded ?? true,
      defaultCurrency: s?.defaultCurrency,
    );
  }

  @override
  Future<void> cancelPlan() => choosePlan(Plan.free);

  @override
  Future<void> completeOnboarding(OnboardingAnswers answers) async {
    lastAnswers = answers;
    _state.value = AccountState(plan: _plan, onboarded: true, defaultCurrency: answers.currency);
  }
}
