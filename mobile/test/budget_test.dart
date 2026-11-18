import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/l10n/i18n.dart';
import 'package:mobile_app/models/budget.dart';
import 'package:mobile_app/models/plan.dart';
import 'package:mobile_app/screens/budget/budget_page.dart';
import 'package:mobile_app/services/account_service.dart';
import 'package:mobile_app/services/budget_repository.dart';

import 'widget_test.dart' show FakeAuthService;

BudgetRecurring _rec(String id, BudgetKind kind, double amount, int day, BudgetCategory c) =>
    BudgetRecurring(id: id, kind: kind, name: c.name, amount: amount, category: c, day: day);

void main() {
  tearDown(() => AppLanguage.current = AppLanguage.fr);

  test('reste à vivre : revenus reçus et à venir moins dépenses et charges à payer', () {
    final month = DateTime(2026, 10);
    final data = BudgetMonth(
      month: month,
      recurring: [
        _rec('sal', BudgetKind.income, 10000, 28, BudgetCategory.salaire),
        _rec('loyer', BudgetKind.expense, 3000, 5, BudgetCategory.logement),
        _rec('net', BudgetKind.expense, 300, 31, BudgetCategory.factures),
      ],
      entries: [
        BudgetEntry(
          id: 'e1',
          kind: BudgetKind.expense,
          name: 'Loyer',
          amount: 3000,
          category: BudgetCategory.logement,
          date: DateTime(2026, 10, 5),
          recurringId: 'loyer',
        ),
        BudgetEntry(
          id: 'e2',
          kind: BudgetKind.expense,
          name: 'Courses',
          amount: 700,
          category: BudgetCategory.courses,
          date: DateTime(2026, 10, 10),
        ),
      ],
      limits: {BudgetCategory.courses: 1000},
    );
    expect(data.spent, 3700);
    expect(data.incomeToCome, 10000); // salaire pas encore reçu
    expect(data.billsToPay, 300); // internet pas encore payé
    expect(data.leftToLive, 10000 - 3700 - 300);
    expect(data.planned.firstWhere((p) => p.recurring.id == 'loyer').done, isTrue);
    expect(data.daysLeft(DateTime(2026, 10, 20)), 12);
    expect(data.spentIn(BudgetCategory.courses), 700);
    // Le 31 devient le 30 en novembre
    expect(_rec('x', BudgetKind.expense, 1, 31, BudgetCategory.autre).dateIn(DateTime(2026, 11)).day, 30);
  });

  test('objectif d\'épargne : progression et somme mensuelle', () {
    final goal = BudgetGoal(id: 'g', name: 'Vacances', target: 6000, saved: 1500, deadline: DateTime(2027, 4, 1));
    expect(goal.progress, 0.25);
    expect(goal.monthlyNeeded(DateTime(2026, 10, 29)), 4500 / 6);
  });

  test('traductions : valeurs insérées et texte inconnu laissé en français', () {
    AppLanguage.current = AppLanguage.en;
    expect(tr('Payé par {0} · {1}', ['Sara', 'hier']), 'Paid by Sara · hier');
    expect('Texte sans traduction'.tr, 'Texte sans traduction');
    AppLanguage.current = AppLanguage.ar;
    expect(BudgetCategory.salaire.label, 'الراتب');
    expect(AppLanguage.ar.rtl, isTrue);
    for (final l in AppLanguage.values.skip(1)) {
      expect(l.translations.length, greaterThan(700), reason: l.name);
    }
  });

  testWidgets('créer son budget, puis marquer le loyer comme payé', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = MemoryBudgetRepository();
    BudgetRepository.instance = repo;
    AccountService.instance = MemoryAccountService(plan: Plan.free);
    await tester.pumpWidget(
      MaterialApp(
        home: BudgetPage(auth: FakeAuthService(), onSignInRequested: () {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Gère ton salaire chaque mois'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Salaire net mensuel'), '9000');
    await tester.tap(find.text('Créer mon budget'));
    await tester.pumpAndSettle();
    expect(find.text('Reste à vivre'), findsOneWidget);
    expect((await repo.recurring()).single.amount, 9000);

    await repo.saveRecurring(_rec('', BudgetKind.expense, 2500, 5, BudgetCategory.logement));
    await tester.tap(find.byIcon(Icons.event_repeat_rounded));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Marquer payé'));
    await tester.pumpAndSettle();
    final entries = await repo.entries(DateTime.now());
    expect(entries.single.amount, 2500);
    expect(entries.single.recurringId, isNotNull);

    // Budget par catégorie : réservé à Plus, la feuille d'upgrade s'ouvre
    await tester.scrollUntilVisible(find.text('Logement'), 200);
    await tester.tap(find.text('Logement'));
    await tester.pumpAndSettle();
    expect(find.text('Budget par catégorie'), findsWidgets);
  });
}
