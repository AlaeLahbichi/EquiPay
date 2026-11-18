import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/models/plan.dart';
import 'package:mobile_app/models/user_profile.dart';
import 'package:mobile_app/screens/onboarding/onboarding_page.dart';
import 'package:mobile_app/screens/plans/plans_page.dart';
import 'package:mobile_app/services/account_service.dart';

Widget _app(Widget home) => MaterialApp(home: Scaffold(body: home));

void main() {
  setUp(() => AccountService.instance = MemoryAccountService());

  test('offre supérieure conseillée selon la limite atteinte', () {
    expect(Plan.free.upgradeFor(PlanFeature.scan), Plan.plus);
    expect(Plan.plus.upgradeFor(PlanFeature.activities), Plan.pro); // Pro : activités illimitées
    expect(Plan.pro.upgradeFor(PlanFeature.activities), isNull);
    expect(Plan.free.upgradeFor(null), Plan.plus); // graphiques
    expect(PlanFeature.activities.allowance(3), '3 activités en cours');
    expect(PlanFeature.scan.allowance(null), 'Scans de tickets illimités');
  });

  test('limites des offres : Gratuit limité, Premium illimité', () {
    expect(Plan.free.limit(PlanFeature.scan), 5);
    expect(Plan.plus.limit(PlanFeature.activities), 10);
    expect(Plan.premium.limits.values.every((l) => l == null), isTrue);
    expect(Plan.free.hasInsights, isFalse);
    expect(Plan.plus.hasInsights, isTrue);
    expect(Plan.pro.yearlyPrice, 390);
    expect(Plan.free.next, Plan.plus);
    expect(Plan.premium.next, isNull);
  });

  test('réponse 402 du backend → PlanLimitException', () {
    final e = PlanLimitException.fromBody(402, {
      'detail': {'message': 'Tu as utilisé tes 5 scans de tickets du mois.', 'feature': 'scan'},
    });
    expect(e?.message, 'Tu as utilisé tes 5 scans de tickets du mois.');
    expect(e?.feature, PlanFeature.scan);
    expect(PlanLimitException.fromBody(500, {'detail': 'x'}), isNull);
  });

  testWidgets('formulaire de bienvenue puis choix de l\'offre', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final account = MemoryAccountService(plan: Plan.free, onboarded: false);
    AccountService.instance = account;
    const user = UserProfile(id: 'u1', email: 'sara@exemple.ma', fullName: 'Sara Alami', username: 'sara');
    await tester.pumpWidget(_app(const OnboardingPage(user: user)));

    expect(find.text('Bienvenue sur EquiPay'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Pseudo'), 'Sara !');
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();
    expect(find.text('3 à 30 caractères : lettres minuscules, chiffres ou _'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Pseudo'), 'sara_a');
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();
    expect(find.text('Ta devise et ton pays'), findsOneWidget);
    await tester.tap(find.text('France'));
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Voyages'));
    await tester.tap(find.text('Un ami'));
    await tester.tap(find.text('Terminer'));
    await tester.pumpAndSettle();

    expect(account.lastAnswers?.username, 'sara_a');
    expect(account.lastAnswers?.country, 'France');
    expect(account.lastAnswers?.currency, 'MAD');
    expect(account.lastAnswers?.usages, ['voyages']);
    expect(account.lastAnswers?.referral, 'ami');
    expect(account.state.value?.onboarded, isTrue);
    // Après le formulaire : les offres, avec « Commencer gratuitement »
    expect(find.text('Choisis ton offre'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Commencer gratuitement'), 400);
    expect(find.text('Commencer gratuitement'), findsOneWidget);
  });

  testWidgets('choisir une offre payante (mode démonstration)', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final account = MemoryAccountService(plan: Plan.free, used: {PlanFeature.scan: 5});
    AccountService.instance = account;
    await tester.pumpWidget(_app(const PlansPage()));
    await tester.pumpAndSettle();

    expect(find.text('Débloque tout EquiPay'), findsOneWidget);
    await tester.tap(find.text('Annuel · 2 mois offerts'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('190 DH / an'), 300);
    await tester.scrollUntilVisible(find.text('5 / 5'), 400); // quota de scans atteint
    await tester.scrollUntilVisible(find.text('Choisir Pro'), -400);

    await tester.ensureVisible(find.text('Choisir Pro'));
    await tester.tap(find.text('Choisir Pro'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mode démonstration'), findsOneWidget);
    await tester.tap(find.text('Confirmer'));
    await tester.pumpAndSettle();

    expect(account.state.value?.plan, Plan.pro);
    expect(find.text('Bienvenue dans l\'offre Pro !'), findsOneWidget);
  });

  testWidgets('limite atteinte : la feuille propose de passer à l\'offre supérieure', (tester) async {
    final account = MemoryAccountService(plan: Plan.free);
    AccountService.instance = account;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showUpgradeSheet(
              context,
              message: 'Ton offre Gratuit permet 3 activités en cours.',
              feature: PlanFeature.activities,
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    expect(find.text('Limite de ton offre atteinte'), findsOneWidget);
    expect(find.text('3 activités en cours'), findsOneWidget);
    expect(find.text('10 activités en cours'), findsOneWidget);
    await tester.tap(find.text('Passer à Plus · 19 DH/mois'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmer'));
    await tester.pumpAndSettle();
    expect(account.state.value?.plan, Plan.plus);
    expect(find.text('Limite de ton offre atteinte'), findsNothing);
  });

  testWidgets('résilier l\'abonnement en trois touches', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final account = MemoryAccountService(plan: Plan.pro);
    AccountService.instance = account;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(onPressed: () => openPlans(context), child: const Text('Offre Pro')),
        ),
      ),
    );
    await tester.tap(find.text('Offre Pro')); // 1 : Profil > Mon offre
    await tester.pumpAndSettle();
    expect(find.text('Mon abonnement Pro'), findsOneWidget);
    await tester.tap(find.text('Résilier l\'abonnement')); // 2
    await tester.pumpAndSettle();
    expect(find.text('Résilier l\'offre Pro ?'), findsOneWidget);
    await tester.tap(find.text('Résilier')); // 3
    await tester.pumpAndSettle();
    expect(account.state.value?.plan, Plan.free);
    expect(find.text('Débloque tout EquiPay'), findsOneWidget);
  });
}
