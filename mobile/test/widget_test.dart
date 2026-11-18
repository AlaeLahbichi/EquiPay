import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException, PostgrestException;

import 'package:mobile_app/main.dart';
import 'package:mobile_app/models/activity.dart';
import 'package:mobile_app/models/activity_overview.dart';
import 'package:mobile_app/models/expense.dart';
import 'package:mobile_app/models/join_request.dart';
import 'package:mobile_app/models/trip_item.dart';
import 'package:mobile_app/models/user_profile.dart';
import 'package:mobile_app/screens/expenses/expense_form_page.dart';
import 'package:mobile_app/screens/expenses/receipt_scan_page.dart';
import 'package:mobile_app/services/activity_repository.dart';
import 'package:mobile_app/services/assistant_service.dart';
import 'package:mobile_app/services/auth_service.dart';
import 'package:mobile_app/services/expense_repository.dart';
import 'package:mobile_app/services/exchange_rates.dart';
import 'package:mobile_app/services/expense_describer.dart';
import 'package:mobile_app/services/network_status.dart';
import 'package:mobile_app/services/place_geocoder.dart';
import 'package:mobile_app/services/receipt_scanner.dart';
import 'package:mobile_app/services/request_repository.dart';
import 'package:mobile_app/services/settings_controller.dart';
import 'package:mobile_app/services/trip_planner.dart';
import 'package:mobile_app/services/trip_repository.dart';
import 'package:mobile_app/widgets/apple_map.dart';
import 'package:mobile_app/widgets/logo_loader.dart';

/// Faux dépôt en mémoire pour tester l'interface sans Supabase.
class FakeActivityRepository implements ActivityRepository {
  final activities = <Activity>[];
  var _nextId = 0;
  Object? readyError;
  Completer<void>? loadGate;

  @override
  Future<void> ensureReady() async {
    if (readyError != null) throw readyError!;
  }

  @override
  Future<List<Activity>> myActivities({bool archived = false}) async {
    await loadGate?.future;
    return [
      for (final a in activities.reversed)
        if (a.archived == archived) a,
    ];
  }

  @override
  Future<void> setArchived(List<String> activityIds, {required bool archived}) async {
    for (var i = 0; i < activities.length; i++) {
      if (activityIds.contains(activities[i].id)) activities[i] = activities[i].copyWith(archived: archived);
    }
  }

  final deletedOrLeft = <String>[];

  @override
  Future<void> deleteOrLeave(Activity activity) async {
    deletedOrLeft.add(activity.id);
    activities.removeWhere((a) => a.id == activity.id);
  }

  @override
  Future<bool> create({
    required String name,
    required ActivityType type,
    required String currency,
    Uint8List? logo,
  }) async {
    activities.add(Activity(id: '${_nextId++}', name: name, type: type, role: MemberRole.owner, currency: currency));
    return true;
  }

  final joinRequests = <String>[];

  @override
  Future<void> join(String code) async {
    if (code != 'ABCDEFGH') throw Exception('Code invalide');
    joinRequests.add(code);
  }

  @override
  Future<String?> joinCode(String activityId) async => 'ABCDEFGH';

  var expenseCount = 3;

  @override
  @override
  Future<ActivityOverview> overview(String activityId) async => ActivityOverview(
    currency: 'EUR',
    total: 1250.5,
    expenseCount: expenseCount,
    members: const [
      MemberSummary(profile: alae, role: MemberRole.owner, totalPaid: 1000, totalOwed: 625.25, balance: 374.75),
      MemberSummary(profile: sara, role: MemberRole.member, totalPaid: 250.5, totalOwed: 625.25, balance: -374.75),
    ],
  );

  @override
  Stream<void> activityChanges(String activityId) => const Stream.empty();

  final roleChanges = <(String, MemberRole)>[];
  final removed = <String>[];
  Object? removeError;

  @override
  Future<Activity> updateActivity(
    Activity activity, {
    required String name,
    required String currency,
    Uint8List? cover,
    bool removeCover = false,
  }) async {
    final updated = activity.copyWith(name: name.trim(), currency: currency);
    final i = activities.indexWhere((a) => a.id == activity.id);
    if (i >= 0) activities[i] = updated;
    return updated;
  }

  @override
  Future<void> setMemberRole(String activityId, String userId, MemberRole role) async {
    roleChanges.add((userId, role));
  }

  @override
  Future<void> removeMember(String activityId, String userId) async {
    if (removeError != null) throw removeError!;
    removed.add(userId);
  }

  @override
  Stream<void> changes() => const Stream.empty();
}

/// Faux dépôt des dépenses et photos, en mémoire.
class FakeExpenseRepository implements ExpenseRepository {
  final items = <Expense>[];
  final drafts = <ExpenseDraft>[];
  final photos = <Photo>[];
  var _next = 0;

  @override
  Future<List<Expense>> expenses(String activityId) async =>
      items.where((e) => e.activityId == activityId).toList().reversed.toList();

  @override
  Future<(Expense, Photo?)?> expense(String expenseId) async {
    final e = items.where((e) => e.id == expenseId).firstOrNull;
    return e == null ? null : (e, photos.where((p) => p.expenseId == expenseId).firstOrNull);
  }

  @override
  Future<String> save(ExpenseDraft d, {String? expenseId}) async {
    drafts.add(d);
    final id = expenseId ?? 'e${_next++}';
    items.removeWhere((e) => e.id == id);
    items.add(
      Expense(
        id: id,
        activityId: d.activityId,
        createdBy: alae.id,
        paidBy: d.paidBy,
        name: d.name,
        amount: d.amount,
        currency: d.currency,
        exchangeRate: d.exchangeRate,
        date: d.date,
        description: d.description,
        shares: [for (final e in d.shares.entries) ExpenseShare(userId: e.key, percentage: e.value)],
      ),
    );
    return id;
  }

  @override
  Future<void> delete(Expense expense) async => items.removeWhere((e) => e.id == expense.id);

  final expensePhotos = <String, Uint8List>{};

  @override
  Future<void> setExpensePhoto(String activityId, String expenseId, Uint8List jpeg) async =>
      expensePhotos[expenseId] = jpeg;

  @override
  Future<void> deletePhoto(Photo photo) async => photos.remove(photo);

  @override
  Future<List<Photo>> activityPhotos(String activityId) async =>
      photos.where((p) => p.activityId == activityId && p.expenseId == null).toList();

  @override
  Future<void> addActivityPhoto(String activityId, Uint8List jpeg) async {}
}

const alae = UserProfile(id: 'u1', email: 'alae@equipay.dev', fullName: 'Alae Lahbichi', username: 'alae');

/// Faux service de connexion : connecté à « alae » par défaut.
class FakeAuthService implements AuthService {
  FakeAuthService({UserProfile? signedInAs = alae}) : user = ValueNotifier(signedInAs);

  @override
  final ValueNotifier<UserProfile?> user;

  @override
  String? get accessToken => user.value == null ? null : 'jwt';

  @override
  Future<void> signInWithEmail({required String email, required String password}) async {
    if (password != 'secret1') {
      throw const AuthException('Invalid login credentials', code: 'invalid_credentials');
    }
    user.value = UserProfile(id: 'u2', email: email, fullName: 'Sara Test');
  }

  @override
  Future<bool> signUpWithEmail({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async => true;

  @override
  Future<void> signInWithGoogle() async => throw GoogleNotEnabledException();

  @override
  Future<void> signOut() async => user.value = null;

  @override
  Future<void> deleteAccount() async => user.value = null;

  @override
  Future<void> updateProfile({required String fullName, required String username}) async {
    if (username == 'pris') throw UsernameTakenException();
    final u = user.value!;
    user.value = UserProfile(id: u.id, email: u.email, fullName: fullName, username: username);
  }

  @override
  Future<void> updateAvatar(Uint8List jpeg) async {}

  String? requestedEmail;

  @override
  Future<void> updateEmail(String email) async => requestedEmail = email;
}

/// Faux dépôt des demandes : [push] simule un changement reçu en temps réel.
class FakeRequestRepository implements RequestRepository {
  final requests = <JoinRequest>[];
  final _changes = StreamController<RequestChange>.broadcast();
  var seenCalls = 0;

  void push(JoinRequest request, {required bool inserted}) {
    requests
      ..removeWhere((r) => r.id == request.id)
      ..insert(0, request);
    _changes.add(
      RequestChange(id: request.id, userId: request.requester.id, status: request.status, inserted: inserted),
    );
  }

  @override
  Future<List<JoinRequest>> myRequests() async => List.of(requests);

  @override
  Future<void> respond(String requestId, {required bool accept}) async {
    final i = requests.indexWhere((r) => r.id == requestId);
    requests[i] = copy(requests[i], accept ? JoinRequestStatus.accepted : JoinRequestStatus.rejected);
  }

  @override
  Future<void> cancel(String requestId) async {
    final i = requests.indexWhere((r) => r.id == requestId);
    requests[i] = copy(requests[i], JoinRequestStatus.cancelled);
  }

  @override
  Future<void> markSeen() async {
    seenCalls++;
    for (var i = 0; i < requests.length; i++) {
      if (!requests[i].seenByRequester) requests[i] = copy(requests[i], requests[i].status);
    }
  }

  @override
  Stream<RequestChange> changes(String userId) => _changes.stream;
}

JoinRequest copy(JoinRequest r, JoinRequestStatus status, {bool seen = true}) => JoinRequest(
  id: r.id,
  activityId: r.activityId,
  activityName: r.activityName,
  requester: r.requester,
  status: status,
  createdAt: r.createdAt,
  decidedAt: DateTime.now(),
  seenByRequester: seen,
);

const sara = UserProfile(id: 'u2', email: 'sara@test.com', fullName: 'Sara Test', username: 'sara');

class FakeAssistant implements AssistantService {
  final questions = <String>[];

  @override
  Future<String> ask(String message) async {
    questions.add(message);
    return 'Réponse à : $message';
  }
}

/// Faux scanner : renvoie la lecture donnée, ou lève l'erreur donnée.
class FakeReceiptScanner implements ReceiptScanner {
  FakeReceiptScanner({this.result, this.error});

  ReceiptScan? result;
  Object? error;
  var calls = 0;

  @override
  Future<ReceiptScan> scan(Uint8List jpeg) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (error case final e?) throw e;
    return result ?? const ReceiptScan(merchant: 'CAFE', amount: 1);
  }
}

Widget app(
  FakeActivityRepository repo, {
  FakeExpenseRepository? expenses,
  NetworkStatus? network,
  FakeAuthService? auth,
  FakeRequestRepository? requests,
  SettingsController? settings,
  AssistantService? assistant,
  ReceiptScanner? receipts,
}) => MyApp(
  repository: repo,
  expenses: expenses ?? FakeExpenseRepository(),
  requests: requests ?? FakeRequestRepository(),
  auth: auth ?? FakeAuthService(),
  settings: settings ?? SettingsController(),
  assistant: assistant ?? FakeAssistant(),
  receipts: receipts ?? FakeReceiptScanner(),
  network: network ?? NetworkStatus.alwaysOnline(),
  startupMinDisplay: const Duration(milliseconds: 500),
);

Future<void> openProfile(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.person_outline_rounded).last);
  await tester.pumpAndSettle();
}

/// Ouvre le menu ⋮ de l'activité et choisit une action.
Future<void> openMenuItem(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Plus d\'actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  // La langue est globale : chaque test repart en français
  tearDown(() => AppLanguage.current = AppLanguage.fr);
  receiptTests();
  exchangeRateTests();
  activityManagementTests();
  tripProgramTests();
  describeTests();
  keyboardTests();
  testWidgets('Démarrage : logo animé puis accueil vide', (tester) async {
    await tester.pumpWidget(app(FakeActivityRepository()));
    expect(find.byType(LogoLoader), findsOneWidget);
    expect(find.text('Bienvenue !'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byType(LogoLoader), findsNothing);
    expect(find.text('by Alae Lahbichi'), findsOneWidget);
    expect(find.text('Aucune activité'), findsOneWidget);
    for (final label in ['EquiPay', 'Demandes', 'Budget', 'Profil']) {
      expect(find.text(label), findsWidgets);
    }
  });

  testWidgets('Démarrage hors ligne : message puis Réessayer', (tester) async {
    final repo = FakeActivityRepository()..readyError = TimeoutException('lent');
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Réessayer'), findsOneWidget);

    repo.readyError = null;
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(find.text('Aucune activité'), findsOneWidget);
  });

  testWidgets('Chargement long : le message change après quelques secondes', (tester) async {
    final repo = FakeActivityRepository()..loadGate = Completer();
    await tester.pumpWidget(app(repo));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Chargement de tes activités…'), findsOneWidget);

    await tester.pump(LogoLoader.slowAfter);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ça prend un peu plus de temps que prévu…'), findsOneWidget);

    repo.loadGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Aucune activité'), findsOneWidget);
  });

  testWidgets('Perte puis retour de connexion : bandeau', (tester) async {
    final changes = StreamController<bool>();
    await tester.pumpWidget(app(FakeActivityRepository(), network: NetworkStatus(changes.stream)));
    await tester.pumpAndSettle();

    changes.add(false);
    await tester.pumpAndSettle();
    expect(find.text('Hors ligne · tes dernières données restent consultables'), findsOneWidget);

    changes.add(true);
    await tester.pumpAndSettle();
    expect(find.text('Connexion rétablie'), findsOneWidget);
    expect(find.text('Hors ligne · tes dernières données restent consultables'), findsNothing);

    await tester.pump(const Duration(seconds: 3)); // masqué après 2,5 s
    await tester.pumpAndSettle();
    expect(find.text('Connexion rétablie'), findsNothing);
  });

  testWidgets('Créer une activité l\'ajoute à la liste', (tester) async {
    final repo = FakeActivityRepository();
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Créer une activité'));
    await tester.pumpAndSettle();
    expect(find.text('Ajouter un logo (optionnel)'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Marrakech 2026');
    // La devise est obligatoire
    await tester.tap(find.text('Créer'));
    await tester.pumpAndSettle();
    expect(find.text('Choisis la devise des dépenses'), findsOneWidget);
    expect(repo.activities, isEmpty);

    await tester.tap(find.text('Devise'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dirham marocain'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Dirham marocain (MAD · DH)'), findsOneWidget);
    await tester.tap(find.text('Créer'));
    await tester.pumpAndSettle();
    expect(repo.activities.single.currency, 'MAD');

    expect(find.text('Aucune activité'), findsNothing);
    expect(find.text('Marrakech 2026'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('Rejoindre avec un code envoie une demande', (tester) async {
    final repo = FakeActivityRepository();
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rejoindre une activité'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'abcd-efgh');
    await tester.tap(find.text('Envoyer la demande'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Demande envoyée'), findsOneWidget);
    expect(repo.joinRequests, ['ABCDEFGH']);
    expect(find.text('Aucune activité'), findsOneWidget); // pas membre tant que l'owner n'a pas accepté
  });

  testWidgets('Visiteur : accueil invite à se connecter, profil propose Google et email', (tester) async {
    await tester.pumpWidget(app(FakeActivityRepository(), auth: FakeAuthService(signedInAs: null)));
    await tester.pumpAndSettle();
    expect(find.text('Connecte-toi pour commencer'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsNothing);

    await tester.tap(find.text('Se connecter'));
    await tester.pumpAndSettle();
    expect(find.text('Bienvenue sur EquiPay'), findsOneWidget);
    expect(find.text('Continuer avec Google'), findsOneWidget);
    expect(find.text('Continuer avec un email'), findsOneWidget);
    expect(find.text('Se déconnecter'), findsNothing);

    await tester.tap(find.text('Continuer avec Google'));
    await tester.pumpAndSettle();
    expect(find.text('La connexion avec Google n\'est pas encore activée.'), findsOneWidget);
  });

  testWidgets('Connexion par email puis affichage du profil', (tester) async {
    await tester.pumpWidget(app(FakeActivityRepository(), auth: FakeAuthService(signedInAs: null)));
    await tester.pumpAndSettle();
    await openProfile(tester);

    await tester.tap(find.text('Continuer avec un email'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'sara@test.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Mot de passe'), 'faux12');
    await tester.tap(find.widgetWithText(FilledButton, 'Se connecter'));
    await tester.pumpAndSettle();
    expect(find.textContaining('incorrect'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Mot de passe'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Se connecter'));
    await tester.pumpAndSettle();
    expect(find.text('Sara Test'), findsNWidgets(2)); // en-tête + ligne « Nom »
    expect(find.text('sara@test.com'), findsNWidgets(2));
  });

  testWidgets('Profil connecté : infos, puis déconnexion confirmée', (tester) async {
    await tester.pumpWidget(app(FakeActivityRepository()));
    await tester.pumpAndSettle();
    await openProfile(tester);
    expect(find.text('Alae Lahbichi'), findsNWidgets(2));
    expect(find.text('@alae'), findsOneWidget);

    await tester.scrollUntilVisible(find.textContaining('version 1.0.0'), 200);
    await tester.tap(find.text('Se déconnecter'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Se déconnecter'));
    await tester.pumpAndSettle();
    expect(find.text('Tu es déconnecté.'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Bienvenue sur EquiPay'), -200);
    expect(find.text('Bienvenue sur EquiPay'), findsOneWidget);
  });

  testWidgets('Mode sombre et choix de la langue', (tester) async {
    final settings = SettingsController(themeMode: ThemeMode.light);
    await tester.pumpWidget(app(FakeActivityRepository(), settings: settings));
    await tester.pumpAndSettle();
    await openProfile(tester);

    await tester.scrollUntilVisible(find.text('À propos'), 200);
    await tester.tap(find.text('Mode sombre'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
    expect(Theme.of(tester.element(find.text('Mode sombre'))).brightness, Brightness.dark);

    await tester.ensureVisible(find.text('Langue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Langue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(settings.language, AppLanguage.en);
    // Toute l'app passe en anglais, barre de navigation comprise
    expect(find.text('Requests'), findsWidgets);
    expect(find.text('Profile'), findsWidgets);

    // Arabe : écran de droite à gauche
    settings.setLanguage(AppLanguage.ar);
    await tester.pumpAndSettle();
    expect(find.text('الملف الشخصي'), findsWidgets);
    expect(Directionality.of(tester.element(find.text('الملف الشخصي').first)), TextDirection.rtl);
  });

  testWidgets('Support : le chat répond, sans être connecté', (tester) async {
    final assistant = FakeAssistant();
    await tester.pumpWidget(
      app(FakeActivityRepository(), auth: FakeAuthService(signedInAs: null), assistant: assistant),
    );
    await tester.pumpAndSettle();
    await openProfile(tester);

    await tester.tap(find.text('Support'));
    await tester.pumpAndSettle();
    expect(find.text('Assistant EquiPay'), findsOneWidget);

    await tester.tap(find.text('Comment créer une activité ?'));
    await tester.pumpAndSettle();
    expect(find.text('Réponse à : Comment créer une activité ?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Et rejoindre ?');
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    expect(assistant.questions, ['Comment créer une activité ?', 'Et rejoindre ?']);
    expect(find.text('Réponse à : Et rejoindre ?'), findsOneWidget);
  });

  testWidgets('Modifier ses informations : libellés centrés, pseudo déjà pris, enregistrement', (tester) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(app(FakeActivityRepository(), auth: auth));
    await tester.pumpAndSettle();
    await openProfile(tester);
    expect(find.byIcon(Icons.photo_camera_rounded), findsOneWidget);

    await tester.tap(find.text('@alae'));
    await tester.pumpAndSettle();
    expect(find.text('Modifier mes informations'), findsWidgets);

    await tester.enterText(find.widgetWithText(TextFormField, 'Pseudo'), 'pris');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.text('Ce pseudo est déjà pris.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Nom'), 'Alae L.');
    await tester.enterText(find.widgetWithText(TextFormField, 'Pseudo'), 'alae_l');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'nouveau@test.com');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.text('@alae_l'), findsOneWidget);
    expect(find.text('Alae L.'), findsNWidgets(2));
    expect(auth.requestedEmail, 'nouveau@test.com');
  });

  testWidgets('Page À propos : logo et description', (tester) async {
    await tester.pumpWidget(app(FakeActivityRepository()));
    await tester.pumpAndSettle();
    await openProfile(tester);
    await tester.scrollUntilVisible(find.text('À propos'), 200);
    // Sortir la ligne de sous le bouton Support flottant
    await tester.drag(find.text('À propos'), const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('À propos'));
    await tester.pumpAndSettle();
    expect(find.text('Version 1.0.0 · by Alae Lahbichi'), findsOneWidget);
    expect(find.text('Fonctionnalités'), findsOneWidget);
    expect(find.image(const AssetImage('assets/branding/logo.png')), findsOneWidget);
  });

  testWidgets('Owner : demande reçue en direct, pastille, puis acceptation', (tester) async {
    final requests = FakeRequestRepository();
    await tester.pumpWidget(app(FakeActivityRepository(), requests: requests));
    await tester.pumpAndSettle();

    requests.push(
      JoinRequest(
        id: 'r1',
        activityId: 'a1',
        activityName: 'Marrakech 2026',
        requester: sara,
        status: JoinRequestStatus.pending,
        createdAt: DateTime.now(),
      ),
      inserted: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('Sara Test veut rejoindre « Marrakech 2026 »'), findsOneWidget);
    expect(find.text('1'), findsWidgets); // pastille sur l'onglet Requests

    await tester.tap(find.text('Voir'));
    await tester.pumpAndSettle();
    expect(find.text('Accepter'), findsOneWidget);
    expect(find.text('Refuser'), findsOneWidget);

    await tester.tap(find.text('Accepter'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Acceptée'), findsOneWidget);
    expect(find.text('Sara Test a rejoint « Marrakech 2026 »'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Demandeur : prévenu quand sa demande est acceptée', (tester) async {
    final requests = FakeRequestRepository();
    final mine = JoinRequest(
      id: 'r2',
      activityId: 'a2',
      activityName: 'Soirée Agadir',
      requester: alae,
      status: JoinRequestStatus.pending,
      createdAt: DateTime.now(),
    );
    requests.requests.add(mine);
    await tester.pumpWidget(app(FakeActivityRepository(), requests: requests));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mail_outline_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Envoyées'));
    await tester.pumpAndSettle();
    expect(find.text('En attente'), findsOneWidget);
    expect(find.text('Annuler'), findsOneWidget);

    requests.push(copy(mine, JoinRequestStatus.accepted, seen: false), inserted: false);
    await tester.pumpAndSettle();
    expect(find.text('Ta demande pour « Soirée Agadir » a été acceptée 🎉'), findsOneWidget);
    expect(find.textContaining('Acceptée'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3)); // l'onglet est ouvert : la réponse est marquée vue
    expect(requests.seenCalls, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('Détail : membres et dépenses, code discret pour l\'owner', (tester) async {
    final repo = FakeActivityRepository()
      ..activities.add(const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();

    expect(find.text('Membres (2)'), findsOneWidget);
    await tester.tap(find.text('Membres (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Alae Lahbichi (toi)'), findsOneWidget);
    expect(find.text('Sara Test'), findsOneWidget);
    expect(find.text('Créateur'), findsOneWidget);
    expect(find.text('3 dépenses'), findsOneWidget);
    expect(find.text('1\u202F250,50 €'), findsOneWidget);
    expect(find.text('+374,75 €'), findsOneWidget);
    expect(find.text('−374,75 €'), findsOneWidget);

    // Code masqué par défaut, révélé puis copié
    expect(find.text('••••-••••'), findsOneWidget);
    await tester.tap(find.byTooltip('Afficher le code'));
    await tester.pump();
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    await tester.tap(find.byTooltip('Copier le code'));
    await tester.pump();
    expect(find.textContaining('Code copié'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('Détail : un membre ne voit pas le code', (tester) async {
    final repo = FakeActivityRepository()
      ..activities.add(const Activity(id: 'a2', name: 'Soirée', type: ActivityType.sortie, role: MemberRole.member));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Soirée'));
    await tester.pumpAndSettle();
    expect(find.text('Membres (2)'), findsOneWidget);
    expect(find.text('••••-••••'), findsNothing);
    expect(find.byTooltip('Copier le code'), findsNothing);
  });

  testWidgets('Owner : modifier le titre de l\'activité', (tester) async {
    final repo = FakeActivityRepository()
      ..activities.add(const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();

    await openMenuItem(tester, 'Modifier');
    await tester.pumpAndSettle();
    expect(find.text('Changer la photo'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Titre'), 'Marrakech 2026');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(find.text('Activité mise à jour'), findsOneWidget);
    expect(find.text('Marrakech 2026'), findsWidgets);
    expect(repo.activities.single.name, 'Marrakech 2026');

    // De retour à l'accueil, la liste affiche le nouveau titre
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Marrakech 2026'), findsOneWidget);
  });

  testWidgets('Owner : passer un participant en spectateur puis le retirer', (tester) async {
    final repo = FakeActivityRepository()
      ..activities.add(const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Membres (2)'));
    await tester.pumpAndSettle();
    // L'owner lui-même n'est pas gérable
    await tester.ensureVisible(find.text('Alae Lahbichi (toi)'));
    await tester.tap(find.text('Alae Lahbichi (toi)'));
    await tester.pumpAndSettle();
    expect(find.text('Spectateur'), findsNothing);

    await tester.ensureVisible(find.text('Sara Test'));
    await tester.tap(find.text('Sara Test'));
    await tester.pumpAndSettle();
    expect(find.text('Membre (participant)'), findsOneWidget);
    await tester.tap(find.text('Spectateur'));
    await tester.pumpAndSettle();
    expect(repo.roleChanges, [('u2', MemberRole.viewer)]);
    expect(find.text('Sara Test est maintenant spectateur'), findsOneWidget);

    // Retrait refusé (dépenses) puis réussi
    repo.removeError = const PostgrestException(
      message: 'Ce membre a des dépenses : passez-le en spectateur plutôt que de le retirer',
    );
    await tester.tap(find.text('Sara Test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retirer de l\'activité'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Retirer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ce membre a des dépenses'), findsOneWidget);

    repo.removeError = null;
    await tester.tap(find.text('Retirer de l\'activité'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Retirer'));
    await tester.pumpAndSettle();
    expect(repo.removed, ['u2']);
    expect(find.text('Sara Test a été retiré de l\'activité'), findsOneWidget);
  });

  testWidgets('Membre : ni modification de l\'activité ni gestion des participants', (tester) async {
    final repo = FakeActivityRepository()
      ..activities.add(const Activity(id: 'a2', name: 'Soirée', type: ActivityType.sortie, role: MemberRole.member));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Soirée'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Plus d\'actions'));
    await tester.pumpAndSettle();
    expect(find.text('Modifier'), findsNothing);
    expect(find.text('Quitter l\'activité'), findsOneWidget);
    await tester.tapAt(const Offset(10, 300)); // ferme le menu
    await tester.pumpAndSettle();
    await tester.tap(find.text('Membres (2)'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sara Test'));
    await tester.tap(find.text('Sara Test'));
    await tester.pumpAndSettle();
    expect(find.text('Retirer de l\'activité'), findsNothing);
  });

  testWidgets('Owner : devise modifiable sans dépenses, verrouillée sinon', (tester) async {
    final repo = FakeActivityRepository()
      ..expenseCount = 0
      ..activities.add(const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();

    await openMenuItem(tester, 'Modifier');
    await tester.pumpAndSettle();
    expect(find.textContaining('Euro (EUR · €)'), findsOneWidget);
    await tester.tap(find.text('Devise'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Franc suisse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Franc suisse'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Franc suisse (CHF · CHF)'), findsOneWidget);
    await tester.ensureVisible(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(repo.activities.single.currency, 'CHF');

    // Avec des dépenses : champ verrouillé
    repo.expenseCount = 3;
    await tester.drag(find.byType(ListView).first, const Offset(0, 300));
    await tester.pumpAndSettle();
    await openMenuItem(tester, 'Modifier');
    await tester.pumpAndSettle();
    expect(find.textContaining('sa devise ne peut plus changer'), findsOneWidget);
    await tester.tap(find.text('Devise'));
    await tester.pumpAndSettle();
    expect(find.text('Devise de l\'activité'), findsNothing);
  });

  Future<void> openActivity(WidgetTester tester, FakeActivityRepository repo, FakeExpenseRepository expenses) async {
    // Écran haut, comme un téléphone : la carte « Programme » des voyages descend les onglets
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(repo, expenses: expenses));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();
  }

  FakeActivityRepository marrakech({MemberRole role = MemberRole.owner}) =>
      FakeActivityRepository()
        ..activities.add(Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: role));

  testWidgets('Ajouter une dépense : 3 méthodes, toutes actives', (tester) async {
    await openActivity(tester, marrakech(), FakeExpenseRepository());
    expect(find.text('Aucune dépense pour le moment.'), findsOneWidget);

    await tester.tap(find.byTooltip('Ajouter une dépense'));
    await tester.pumpAndSettle();
    expect(find.text('Saisie manuelle'), findsOneWidget);
    expect(find.text('Scanner un reçu'), findsOneWidget);
    expect(find.text('Décrire la dépense'), findsOneWidget);
    expect(find.text('Bientôt'), findsNothing);
  });

  testWidgets('Saisie manuelle : parts égales par défaut, modifiables, total contrôlé', (tester) async {
    final expenses = FakeExpenseRepository();
    await openActivity(tester, marrakech(), expenses);
    await tester.tap(find.byTooltip('Ajouter une dépense'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saisie manuelle'));
    await tester.pumpAndSettle();

    expect(find.text('Nouvelle dépense'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Titre'), 'Dîner au riad');
    await tester.enterText(find.widgetWithText(TextField, 'Montant'), '90');
    await tester.pump();

    // Alae (owner) et Sara (membre) : 50 % chacun par défaut
    await tester.scrollUntilVisible(find.text('Total : 100 %'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.widgetWithText(TextField, '50'), findsNWidgets(2));
    expect(find.text('45,00 €'), findsNWidgets(2));

    // Modification à la main : le total n'est plus bon
    await tester.enterText(find.widgetWithText(TextField, '50').last, '30');
    await tester.pump();
    expect(find.text('Total : 80 % (il manque 20 %)'), findsOneWidget);
    await tester.tap(find.text('Ajouter la dépense'));
    await tester.pumpAndSettle();
    expect(find.text('La somme des pourcentages doit faire 100 %'), findsOneWidget);
    expect(expenses.drafts, isEmpty);

    // 70 / 30 → valide
    await tester.enterText(find.widgetWithText(TextField, '50'), '70');
    await tester.pump();
    expect(find.text('Total : 100 %'), findsOneWidget);
    await tester.tap(find.text('Ajouter la dépense'));
    await tester.pumpAndSettle();

    final draft = expenses.drafts.single;
    expect(draft.name, 'Dîner au riad');
    expect(draft.amount, 90);
    expect(draft.currency, 'EUR');
    expect(draft.paidBy, alae.id);
    expect(draft.shares, {alae.id: 70, sara.id: 30});
    expect(find.text('Dépense ajoutée'), findsOneWidget);
    expect(find.text('Dîner au riad'), findsOneWidget);
    expect(find.text('Dépenses (1)'), findsOneWidget);
  });

  testWidgets('Détail d\'une dépense : répartition avec pourcentages et montants', (tester) async {
    final expenses = FakeExpenseRepository();
    await expenses.save(
      ExpenseDraft(
        activityId: 'a1',
        name: 'Taxi aéroport',
        amount: 40,
        currency: 'EUR',
        date: DateTime(2026, 10, 9),
        paidBy: sara.id,
        shares: {alae.id: 50, sara.id: 50},
        city: 'Marrakech',
      ),
    );
    await openActivity(tester, marrakech(), expenses);
    expect(find.text('Taxi aéroport'), findsOneWidget);
    expect(find.textContaining('Payé par Sara Test'), findsOneWidget);

    await tester.tap(find.text('Taxi aéroport'));
    await tester.pumpAndSettle();
    expect(find.text('Répartition (2)'), findsOneWidget);
    expect(find.text('50 %'), findsNWidgets(2));
    expect(find.text('20,00 €'), findsNWidgets(2));
    expect(find.text('9 oct. 2026'), findsWidgets);
    // Créée par Alae : modifiable et supprimable
    expect(find.byTooltip('Modifier la dépense'), findsOneWidget);
    expect(find.byTooltip('Supprimer la dépense'), findsOneWidget);
  });

  testWidgets('Onglet Photos : un membre peut ajouter des photos', (tester) async {
    final expenses = FakeExpenseRepository();
    await openActivity(tester, marrakech(), expenses);
    await tester.tap(find.text('Photos (0)'));
    await tester.pumpAndSettle();
    expect(find.text('Ajouter'), findsOneWidget);
  });

  testWidgets('Spectateur : pas d\'ajout de dépense, mais peut ajouter des photos', (tester) async {
    await openActivity(tester, marrakech(role: MemberRole.viewer), FakeExpenseRepository());
    expect(find.byTooltip('Ajouter une dépense'), findsNothing);
    await tester.tap(find.text('Photos (0)'));
    await tester.pumpAndSettle();
    expect(find.text('Ajouter'), findsOneWidget);
  });

  testWidgets('Photos de l\'activité : un membre peut supprimer la photo d\'un autre', (tester) async {
    final expenses = FakeExpenseRepository()
      ..photos.add(
        Photo(
          id: 'p1',
          activityId: 'a1',
          uploadedBy: 'u2',
          storagePath: 'a1/photos/1.jpg',
          url: 'https://example.com/1.jpg',
        ),
      );
    await openActivity(tester, marrakech(), expenses);
    await tester.tap(find.text('Photos (1)'));
    await tester.pumpAndSettle();
    final photo = find.byWidgetPredicate((w) => w is Hero && w.tag == 'activity-photo-p1');
    await tester.ensureVisible(photo);
    await tester.pumpAndSettle();
    await tester.tap(photo);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Supprimer la photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(expenses.photos, isEmpty);
  });

  testWidgets('Photo de profil : affichée en grand, avec « Changer la photo »', (tester) async {
    await tester.pumpWidget(app(FakeActivityRepository()));
    await tester.pumpAndSettle();
    await openProfile(tester);
    await tester.tap(find.bySemanticsLabel('Voir la photo de profil'));
    await tester.pumpAndSettle();
    expect(find.text('Changer la photo'), findsOneWidget);
    await tester.tap(find.byTooltip('Fermer'));
    await tester.pumpAndSettle();
    expect(find.text('Changer la photo'), findsNothing);
  });
}

// ------------------------------------------------------------------ scan de reçu

final _ticket = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]); // image PNG de 1 × 1 pixel

const _members = [
  MemberSummary(profile: alae, role: MemberRole.owner, totalPaid: 0, totalOwed: 0, balance: 0),
  MemberSummary(profile: sara, role: MemberRole.member, totalPaid: 0, totalOwed: 0, balance: 0),
];

/// Ouvre la page de scan depuis un bouton, et garde ce qu'elle renvoie.
Future<List<ReceiptScan?>> pumpScanPage(WidgetTester tester, FakeReceiptScanner scanner) async {
  final results = <ReceiptScan?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => results.add(
            await Navigator.of(context).push<ReceiptScan>(
              MaterialPageRoute(
                builder: (_) => ReceiptScanPage(image: _ticket, scanner: scanner),
              ),
            ),
          ),
          child: const Text('ouvrir'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ouvrir'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return results;
}

/// Faux taux de change : 1 MAD = 0,0897 EUR, ou erreur.
class FakeExchangeRates implements ExchangeRates {
  FakeExchangeRates({this.fail = false});

  bool fail;
  final asked = <(String, String, DateTime)>[];

  @override
  Future<ExchangeRate> rate({required String from, required String to, required DateTime date}) async {
    asked.add((from, to, date));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (fail) throw const ExchangeRateException('Taux de change indisponible (hors ligne ?). Saisis-le à la main.');
    return ExchangeRate(rate: from == 'MAD' ? 0.089687 : 1.1, date: date);
  }
}

Future<void> pumpPrefilledForm(
  WidgetTester tester,
  FakeExpenseRepository expenses,
  ReceiptScan scan, {
  ExchangeRates? rates,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ExpenseFormPage(
        activity: const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner),
        members: _members,
        currentUserId: alae.id,
        repository: expenses,
        prefill: scan,
        initialPhoto: _ticket,
        rates: rates ?? FakeExchangeRates(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void receiptTests() {
  testWidgets('Scan : animation de lecture puis renvoie la lecture du ticket', (tester) async {
    final scanner = FakeReceiptScanner(result: const ReceiptScan(merchant: 'CAFE DE LA GARE', amount: 11.5));
    final results = await pumpScanPage(tester, scanner);
    // Pendant la lecture (le faux scanner répond en 50 ms) : on vérifie l'écran tout de suite
    expect(scanner.calls, 1);
    await tester.pumpAndSettle();
    expect(results.single?.merchant, 'CAFE DE LA GARE');
  });

  testWidgets('Scan : écran de chargement visible pendant la lecture', (tester) async {
    final scanner = FakeReceiptScanner();
    await tester.pumpWidget(
      MaterialApp(
        home: ReceiptScanPage(image: _ticket, scanner: scanner),
      ),
    );
    await tester.pump();
    expect(find.text('Lecture du ticket…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('Scan : en cas d\'échec, réessayer ou saisir à la main avec la photo', (tester) async {
    final scanner = FakeReceiptScanner(error: const ReceiptScanException('Impossible de joindre le scanner.'));
    final results = await pumpScanPage(tester, scanner);
    await tester.pumpAndSettle();
    expect(find.text('Impossible de joindre le scanner.'), findsOneWidget);

    scanner.error = null;
    scanner.result = const ReceiptScan(amount: 9);
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(scanner.calls, 2);
    expect(results.single?.amount, 9);

    final failing = FakeReceiptScanner(error: const ReceiptScanException('Le scanner est indisponible.'));
    final results2 = await pumpScanPage(tester, failing);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saisir à la main avec cette photo'));
    await tester.pumpAndSettle();
    expect(identical(results2.single, ReceiptScanPage.manual), isTrue);
  });

  testWidgets('Formulaire pré-rempli par le scan : champs, avertissements, photo jointe', (tester) async {
    final expenses = FakeExpenseRepository();
    await pumpPrefilledForm(
      tester,
      expenses,
      ReceiptScan(
        merchant: 'CAFE DE LA GARE',
        address: '12 rue de Lyon, Paris',
        date: DateTime(2026, 10, 9),
        amount: 11.5,
        amountText: '11,50 €',
        currency: 'EUR',
        items: const [
          ReceiptItem(label: 'Cafe creme', qty: 2, price: 7),
          ReceiptItem(label: 'Croissant', price: 4.5),
        ],
      ),
    );
    expect(find.text('Rempli à partir du ticket'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'CAFE DE LA GARE'), findsOneWidget);
    expect(find.widgetWithText(TextField, '11,5'), findsOneWidget);
    expect(find.text('Lu sur le ticket : « 11,50 € »'), findsOneWidget);
    expect(find.text('9 oct. 2026'), findsOneWidget);
    // L'utilisateur corrige le titre, vérifie la photo jointe puis valide
    await tester.enterText(find.widgetWithText(TextField, 'CAFE DE LA GARE'), 'Petit-déjeuner');
    await tester.scrollUntilVisible(find.text('Retirer'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Retirer'), findsOneWidget); // photo du ticket déjà jointe
    await tester.tap(find.text('Ajouter la dépense'));
    await tester.pumpAndSettle();
    final draft = expenses.drafts.single;
    expect(draft.name, 'Petit-déjeuner');
    expect(draft.amount, 11.5);
    expect(draft.currency, 'EUR');
    expect(draft.date, DateTime(2026, 10, 9));
    expect(draft.address, '12 rue de Lyon, Paris');
    expect(draft.description, '2 × Cafe creme — 7\nCroissant — 4,5');
    expect(draft.shares, {'u1': 50.0, 'u2': 50.0});
    expect(expenses.expensePhotos.values.single, _ticket);
  });

  testWidgets('Formulaire pré-rempli : champs absents signalés, devise inconnue', (tester) async {
    await pumpPrefilledForm(
      tester,
      FakeExpenseRepository(),
      const ReceiptScan(
        merchant: 'MARJANE',
        amount: 125.5,
        amountText: '12550',
        currency: 'XYZ',
        amountMatchesText: false,
      ),
    );
    expect(find.textContaining('Date non trouvée sur le ticket'), findsWidgets);
    expect(find.textContaining('ne correspond pas exactement au total imprimé'), findsOneWidget);
    expect(find.textContaining('Devise XYZ non proposée'), findsOneWidget);
    expect(find.text('Devise lue : XYZ (non proposée) — choisis la bonne'), findsOneWidget);
  });
}

void exchangeRateTests() {
  testWidgets('Devise étrangère : taux automatique au jour de la dépense, puis corrigé à la main', (tester) async {
    final expenses = FakeExpenseRepository();
    final rates = FakeExchangeRates();
    await pumpPrefilledForm(
      tester,
      expenses,
      ReceiptScan(
        merchant: 'CAFE CLOCK',
        amount: 125.5,
        amountText: '125.50',
        currency: 'MAD',
        date: DateTime(2026, 10, 9),
      ),
      rates: rates,
    );
    // Taux cherché automatiquement : MAD → EUR (devise de l'activité), au jour du ticket
    expect(rates.asked.single, ('MAD', 'EUR', DateTime(2026, 10, 9)));
    expect(find.widgetWithText(TextField, '0,089687'), findsOneWidget);
    expect(find.textContaining('Taux automatique du 9 oct. 2026'), findsOneWidget);
    expect(find.textContaining('11,26 € dans les totaux'), findsOneWidget);

    // L'utilisateur corrige le taux : il n'est plus écrasé
    await tester.enterText(find.widgetWithText(TextField, '0,089687'), '0,09');
    await tester.pump();
    expect(find.textContaining('Taux saisi à la main'), findsOneWidget);
    await tester.tap(find.text('Ajouter la dépense'));
    await tester.pumpAndSettle();
    expect(expenses.drafts.single.exchangeRate, 0.09);
    expect(expenses.drafts.single.currency, 'MAD');
  });

  testWidgets('Taux automatique : bouton pour revenir au taux du jour', (tester) async {
    final rates = FakeExchangeRates();
    await pumpPrefilledForm(
      tester,
      FakeExpenseRepository(),
      const ReceiptScan(amount: 10, currency: 'MAD'),
      rates: rates,
    );
    await tester.enterText(find.widgetWithText(TextField, '0,089687'), '0,5');
    await tester.pump();
    await tester.ensureVisible(find.byTooltip('Taux automatique'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Taux automatique'));
    await tester.pumpAndSettle();
    expect(rates.asked, hasLength(2));
    expect(find.widgetWithText(TextField, '0,089687'), findsOneWidget);
    expect(find.textContaining('Taux automatique du'), findsOneWidget);
  });

  testWidgets('Taux introuvable (hors ligne) : message et saisie à la main obligatoire', (tester) async {
    final expenses = FakeExpenseRepository();
    await pumpPrefilledForm(
      tester,
      expenses,
      const ReceiptScan(merchant: 'Taxi', amount: 30, currency: 'MAD'),
      rates: FakeExchangeRates(fail: true),
    );
    expect(find.textContaining('Taux de change indisponible'), findsOneWidget);
    await tester.tap(find.text('Ajouter la dépense'));
    await tester.pumpAndSettle();
    expect(find.text('Indique le taux de change'), findsOneWidget);
    expect(expenses.drafts, isEmpty);
  });

  test('Service de taux : jour demandé, serveur de secours, même devise, erreur', () async {
    final urls = <String>[];
    final client = MockClient((req) async {
      urls.add(req.url.toString());
      if (req.url.host == 'cdn.jsdelivr.net') return http.Response('panne', 503); // serveur principal en panne
      return http.Response('{"date": "2026-10-09", "mad": {"eur": 0.089686978}}', 200);
    });
    final service = HttpExchangeRates(client: client);
    final r = await service.rate(from: 'MAD', to: 'EUR', date: DateTime(2026, 10, 9));
    expect(r.rate, closeTo(0.089687, 1e-6));
    expect(r.date, DateTime(2026, 10, 9));
    expect(urls, hasLength(2));
    expect(urls.last, 'https://2026-10-09.currency-api.pages.dev/v1/currencies/mad.json');

    await service.rate(from: 'MAD', to: 'EUR', date: DateTime(2026, 10, 9));
    expect(urls, hasLength(2)); // gardé en mémoire

    expect((await service.rate(from: 'EUR', to: 'EUR', date: DateTime(2026))).rate, 1);
    await expectLater(
      service.rate(from: 'MAD', to: 'XYZ', date: DateTime(2026, 10, 9)),
      throwsA(isA<ExchangeRateException>()),
    );

    final offline = HttpExchangeRates(client: MockClient((_) async => throw Exception('hors ligne')));
    await expectLater(
      offline.rate(from: 'MAD', to: 'EUR', date: DateTime(2026, 10, 9)),
      throwsA(isA<ExchangeRateException>()),
    );
  });
}

FakeActivityRepository threeActivities() => FakeActivityRepository()
  ..activities.addAll(const [
    Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner),
    Activity(id: 'a2', name: 'Soirée', type: ActivityType.sortie, role: MemberRole.member),
    Activity(id: 'a3', name: 'Coloc', type: ActivityType.quotidien, role: MemberRole.owner),
  ]);

/// Overview avec des soldes variés pour tester les tris et les graphiques.
class SortableActivityRepository extends FakeActivityRepository {
  static const zoe = UserProfile(id: 'u3', email: 'zoe@test.com', fullName: 'Zoé Martin', username: 'zoe');
  static const eli = UserProfile(id: 'u4', email: 'eli@test.com', fullName: 'Élodie Bernard', username: 'eli');

  @override
  Future<ActivityOverview> overview(String activityId) async => const ActivityOverview(
    currency: 'EUR',
    total: 300,
    expenseCount: 2,
    members: [
      MemberSummary(profile: alae, role: MemberRole.owner, totalPaid: 200, totalOwed: 75, balance: 125),
      MemberSummary(profile: zoe, role: MemberRole.member, totalPaid: 100, totalOwed: 75, balance: 25),
      MemberSummary(profile: sara, role: MemberRole.member, totalPaid: 0, totalOwed: 75, balance: -75),
      MemberSummary(profile: eli, role: MemberRole.member, totalPaid: 0, totalOwed: 75, balance: -75.5),
    ],
  );
}

List<String> memberOrder(WidgetTester tester) {
  const names = ['Alae Lahbichi (toi)', 'Zoé Martin', 'Sara Test', 'Élodie Bernard'];
  final positions = {for (final n in names) n: tester.getTopLeft(find.text(n)).dy};
  return names.toList()..sort((a, b) => positions[a]!.compareTo(positions[b]!));
}

void activityManagementTests() {
  testWidgets('Participants : tri alphabétique et par solde', (tester) async {
    final repo = SortableActivityRepository()
      ..activities.add(const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner));
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Membres (4)'));
    await tester.pumpAndSettle();

    expect(memberOrder(tester), ['Alae Lahbichi (toi)', 'Zoé Martin', 'Sara Test', 'Élodie Bernard']);
    await tester.tap(find.text('A → Z'));
    await tester.pumpAndSettle();
    expect(memberOrder(tester), ['Alae Lahbichi (toi)', 'Élodie Bernard', 'Sara Test', 'Zoé Martin']);
    await tester.tap(find.text('Solde ↑'));
    await tester.pumpAndSettle();
    expect(memberOrder(tester), ['Élodie Bernard', 'Sara Test', 'Zoé Martin', 'Alae Lahbichi (toi)']);
    await tester.tap(find.text('Solde ↓'));
    await tester.pumpAndSettle();
    expect(memberOrder(tester), ['Alae Lahbichi (toi)', 'Zoé Martin', 'Sara Test', 'Élodie Bernard']);
  });

  testWidgets('Menu ⋮ : actions de l\'owner, archiver renvoie à l\'accueil', (tester) async {
    final repo = threeActivities();
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Plus d\'actions'));
    await tester.pumpAndSettle();
    for (final label in ['Modifier', 'Archiver', 'Résumé', 'Graphique des dépenses', 'Insights', 'Supprimer']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Archiver'));
    await tester.pumpAndSettle();

    expect(find.text('Activité archivée'), findsOneWidget);
    expect(find.text('Mes activités'), findsOneWidget);
    expect(find.text('Marrakech'), findsNothing);
    expect(repo.activities.firstWhere((a) => a.id == 'a1').archived, isTrue);
  });

  testWidgets('Menu ⋮ : supprimer après confirmation', (tester) async {
    final repo = threeActivities();
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coloc'));
    await tester.pumpAndSettle();
    await openMenuItem(tester, 'Supprimer');
    expect(find.text('Supprimer « Coloc » ?'), findsOneWidget);
    expect(find.textContaining('irréversible'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(repo.deletedOrLeft, ['a3']);
    expect(find.text('Activité supprimée'), findsOneWidget);
    expect(find.text('Coloc'), findsNothing);
  });

  testWidgets('Graphique et insights des dépenses par participant', (tester) async {
    final repo = SortableActivityRepository()
      ..activities.add(const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner));
    final expenses = FakeExpenseRepository()
      ..items.addAll([
        Expense(
          id: 'e1',
          activityId: 'a1',
          createdBy: 'u1',
          paidBy: 'u1',
          name: 'Riad',
          amount: 200,
          currency: 'EUR',
          date: DateTime(2026, 10, 5),
          shares: const [],
        ),
        Expense(
          id: 'e2',
          activityId: 'a1',
          createdBy: 'u3',
          paidBy: 'u3',
          name: 'Dîner',
          amount: 100,
          currency: 'EUR',
          date: DateTime(2026, 10, 6),
          shares: const [],
        ),
      ]);
    await tester.pumpWidget(app(repo, expenses: expenses));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();

    await openMenuItem(tester, 'Graphique des dépenses');
    expect(find.text('Dépenses par participant'), findsOneWidget);
    expect(find.text('67 %'), findsOneWidget); // Toi : 200 / 300
    await tester.tap(find.text('Solde'));
    await tester.pumpAndSettle();
    expect(find.text('+125,00 €'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await openMenuItem(tester, 'Insights');
    expect(find.text('150,00 €'), findsWidgets); // moyenne par dépense et par jour
    await tester.scrollUntilVisible(find.text('Ta situation'), 200);
    expect(find.text('On te doit'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Pour équilibrer les comptes'), 200);
    await tester.drag(find.text('Pour équilibrer les comptes'), const Offset(0, -250));
    await tester.pumpAndSettle();
    // Élodie doit 75,50 et Sara 75 : 3 virements suffisent (Élodie → toi, Sara → toi, Sara → Zoé)
    expect(find.textContaining('3 virements suffisent'), findsOneWidget);
  });

  testWidgets('Résumé : qui rembourse qui, pour chaque personne', (tester) async {
    final repo = SortableActivityRepository()
      ..activities.add(const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner));
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();

    await openMenuItem(tester, 'Résumé');
    expect(find.text('3 remboursements pour tout équilibrer'), findsOneWidget);
    // Toi en premier, puis Zoé (à recevoir), Sara puis Élodie (à rembourser)
    final order = ['Toi', 'Zoé Martin', 'Sara Test', 'Élodie Bernard'];
    final ys = [for (final n in order) tester.getTopLeft(find.text(n).first).dy];
    expect(ys, [...ys]..sort());
    expect(find.text('Doit recevoir 125,00 €'), findsOneWidget);
    expect(find.text('Tu reçois de Élodie Bernard'), findsOneWidget);
    expect(find.text('Rembourse Toi'), findsNWidgets(2));
    expect(find.text('Rembourse Zoé Martin'), findsOneWidget);
    expect(find.text('Reçoit de Sara Test'), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.byTooltip('Copier le résumé'));
    await tester.pumpAndSettle();
    expect(find.text('Résumé copié'), findsOneWidget);
    expect(copied, contains('Élodie Bernard doit 75,50 € à Alae Lahbichi'));
  });

  testWidgets('Accueil : sélection multiple puis archivage', (tester) async {
    final repo = threeActivities();
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Marrakech'));
    await tester.pumpAndSettle();
    expect(find.text('1 sélectionnée'), findsOneWidget);
    await tester.tap(find.text('Coloc'));
    await tester.pumpAndSettle();
    expect(find.text('2 sélectionnées'), findsOneWidget);
    await tester.tap(find.text('Archiver'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 activités archivées'), findsOneWidget);
    expect(find.text('Mes activités'), findsOneWidget);
    expect(find.text('Marrakech'), findsNothing);
    expect(find.text('Coloc'), findsNothing);
    expect(find.text('Soirée'), findsOneWidget);
  });

  testWidgets('Accueil : tout sélectionner puis supprimer (créées) ou quitter (rejointes)', (tester) async {
    final repo = threeActivities();
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sélectionner'));
    await tester.pumpAndSettle();
    expect(find.text('Sélectionne des activités'), findsOneWidget);
    await tester.tap(find.text('Tout sélectionner'));
    await tester.pumpAndSettle();
    expect(find.text('3 sélectionnées'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(find.text('Supprimer 3 activités ?'), findsOneWidget);
    expect(find.textContaining('Tu quitteras l\'activité'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Supprimer').last);
    await tester.pumpAndSettle();

    expect(repo.deletedOrLeft.toSet(), {'a1', 'a2', 'a3'});
    expect(find.text('2 activités supprimées, activité quittée'), findsOneWidget);
    expect(find.text('Aucune activité'), findsOneWidget);
  });

  testWidgets('Profil : activités archivées, consulter, désarchiver et supprimer', (tester) async {
    final repo = threeActivities();
    await repo.setArchived(['a1', 'a3'], archived: true);
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Marrakech'), findsNothing);

    await openProfile(tester);
    await tester.scrollUntilVisible(find.text('Activités archivées'), 200);
    // En haut de l'écran : pas sous le bouton Support flottant
    await tester.ensureVisible(find.text('Activités archivées'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activités archivées'));
    await tester.pumpAndSettle();
    expect(find.text('Marrakech'), findsOneWidget);
    expect(find.text('Coloc'), findsOneWidget);

    // Consulter : le menu propose de désarchiver
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();
    expect(find.text('Membres (2)'), findsOneWidget);
    await tester.tap(find.byTooltip('Plus d\'actions'));
    await tester.pumpAndSettle();
    expect(find.text('Désarchiver'), findsOneWidget);
    await tester.tapAt(const Offset(10, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Désarchiver').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Activité désarchivée'), findsOneWidget);
    expect(repo.activities.firstWhere((a) => a.id == 'a3').archived, isFalse);

    await tester.tap(find.byTooltip('Supprimer'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(repo.deletedOrLeft, ['a1']);
    expect(find.text('Aucune activité archivée'), findsOneWidget);
  });
}

/// Faux assistant « Décrire la dépense » : renvoie la dépense donnée, ou lève l'erreur donnée.
class FakeExpenseDescriber implements ExpenseDescriber {
  FakeExpenseDescriber({this.result, this.error});

  DescribedExpense? result;
  Object? error;
  final calls = <(String, Map<String, String>, String)>[];

  @override
  Future<DescribedExpense> describe({
    required String sentence,
    required Map<String, String> members,
    required String currency,
    DateTime? today,
  }) async {
    calls.add((sentence, members, currency));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (error case final e?) throw e;
    return result ?? DescribedExpense(sentence: sentence);
  }
}

Future<void> openDescribe(WidgetTester tester, FakeExpenseRepository expenses, FakeExpenseDescriber describer) async {
  ExpenseDescriber.instance = describer;
  // Écran haut : tout le formulaire est construit sans défilement
  await tester.binding.setSurfaceSize(const Size(800, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => ExpenseDescriber.instance = HttpExpenseDescriber(token: () => null));
  final repo = FakeActivityRepository()
    ..activities.add(const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner));
  await tester.pumpWidget(app(repo, expenses: expenses));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Marrakech'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Ajouter une dépense'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Décrire la dépense'));
  await tester.pumpAndSettle();
}

void describeTests() {
  testWidgets('Décrire la dépense : phrase comprise puis formulaire pré-rempli (payeur, 60/40)', (tester) async {
    final expenses = FakeExpenseRepository();
    final describer = FakeExpenseDescriber(
      result: DescribedExpense(
        sentence: 'Resto Nomad avec Sara 60/40, Sara a payé 50 € hier',
        title: 'Restaurant',
        merchant: 'Nomad',
        amount: 50,
        currency: 'EUR',
        date: DateTime(2026, 10, 11),
        paidBy: 'u2',
        participants: const ['u1', 'u2'],
        splitType: 'percent',
        shares: const {'u1': 60, 'u2': 40},
      ),
    );
    await openDescribe(tester, expenses, describer);

    expect(find.text('Exemples'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Remplir la dépense'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Resto Nomad avec Sara 60/40, Sara a payé 50 € hier');
    await tester.pump();
    await tester.tap(find.text('Remplir la dépense'));
    await tester.pump();
    expect(find.text('L\'assistant lit ta phrase…'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(describer.calls.single.$2, {'u1': 'Alae Lahbichi', 'u2': 'Sara Test'});
    expect(describer.calls.single.$3, 'EUR');
    expect(find.text('Rempli à partir de ta phrase'), findsOneWidget);
    expect(find.text('Restaurant · Nomad'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
    expect(find.text('Sara Test'), findsWidgets); // payeur

    await tester.tap(find.text('Ajouter la dépense'));
    await tester.pumpAndSettle();
    final draft = expenses.drafts.single;
    expect(draft.name, 'Restaurant · Nomad');
    expect(draft.amount, 50);
    expect(draft.paidBy, 'u2');
    expect(draft.date, DateTime(2026, 10, 11));
    expect(draft.shares, {'u1': 60.0, 'u2': 40.0});
  });

  testWidgets('Décrire la dépense : champs absents signalés, montant à compléter', (tester) async {
    final expenses = FakeExpenseRepository();
    final describer = FakeExpenseDescriber(
      result: const DescribedExpense(
        sentence: 'taxi avec Sara',
        title: 'Taxi',
        participants: ['u1', 'u2'],
        warnings: ['Montant non indiqué'],
      ),
    );
    await openDescribe(tester, expenses, describer);
    await tester.enterText(find.byType(TextField), 'taxi avec Sara');
    await tester.pump();
    await tester.tap(find.text('Remplir la dépense'));
    await tester.pumpAndSettle();

    expect(find.text('Montant absent de ta phrase : saisis-le.'), findsOneWidget);
    expect(find.text('Pas dans ta phrase : à compléter'), findsOneWidget); // montant
    expect(find.text('Pas de payeur dans ta phrase : toi par défaut'), findsOneWidget);
    await tester.tap(find.text('Ajouter la dépense'));
    await tester.pumpAndSettle();
    expect(expenses.drafts, isEmpty);
    expect(find.text('Indique un montant positif'), findsOneWidget);
  });

  testWidgets('Décrire la dépense : phrase incomprise, message et nouvelle tentative', (tester) async {
    final describer = FakeExpenseDescriber(
      error: const DescribeException('Ça ne ressemble pas à une dépense. Indique au moins ce qui a été payé.'),
    );
    await openDescribe(tester, FakeExpenseRepository(), describer);
    await tester.enterText(find.byType(TextField), 'envoie le récap à Sara');
    await tester.pump();
    await tester.tap(find.text('Remplir la dépense'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ça ne ressemble pas à une dépense'), findsOneWidget);
    expect(find.text('Décrire la dépense'), findsOneWidget); // on reste sur la page

    // Un exemple remplit le champ
    await tester.tap(find.textContaining('a payé le taxi'));
    await tester.pump();
    expect(find.textContaining('a payé le taxi'), findsWidgets);
  });
}

void keyboardTests() {
  testWidgets('Clavier : toucher un endroit vide retire le focus, toucher un champ le garde', (tester) async {
    ExpenseDescriber.instance = FakeExpenseDescriber();
    addTearDown(() => ExpenseDescriber.instance = HttpExpenseDescriber(token: () => null));
    final repo = FakeActivityRepository()
      ..activities.add(const Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: MemberRole.owner));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ajouter une dépense'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saisie manuelle'));
    await tester.pumpAndSettle();

    final title = find.widgetWithText(TextField, 'Titre');
    await tester.tap(title);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>(), isNotNull);

    // Toucher le même champ : le clavier reste
    await tester.tap(title);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    // Toucher un espace vide (zone de l'en-tête de la page, sans bouton) : le clavier se ferme
    await tester.tapAt(tester.getCenter(find.text('Nouvelle dépense')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });
}

void tripProgramTests() {
  /// Programme en mémoire, branché à la place de Supabase pour le test.
  MemoryTripRepository useMemoryTrips() {
    final trips = MemoryTripRepository();
    TripRepository.instance = trips;
    addTearDown(() => TripRepository.instance = MemoryTripRepository());
    return trips;
  }

  Future<void> openProgram(WidgetTester tester, {MemberRole role = MemberRole.owner}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = FakeActivityRepository()
      ..activities.add(Activity(id: 'a1', name: 'Marrakech', type: ActivityType.voyage, role: role));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Programme'));
    await tester.pumpAndSettle();
  }

  /// La carte se cadre sur les lieux au premier dessin ; les repères suivent à l'image d'après.
  Future<void> mapFrames(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Programme : ajout d\'une activité puis vote pour / contre', (tester) async {
    final trips = useMemoryTrips();
    await openProgram(tester);
    expect(find.textContaining('Rien de prévu'), findsOneWidget);

    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Nom'), 'Visite du Jardin Majorelle');
    await tester.enterText(find.widgetWithText(TextFormField, 'Lieu'), 'Jardin Majorelle');
    await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
    await tester.pumpAndSettle();
    expect(find.text('Visite du Jardin Majorelle'), findsOneWidget);
    expect(find.text('Sans date'), findsOneWidget);
    // Pas de géocodage dans les tests : le lieu n'est pas trouvé
    expect(find.textContaining('Lieu introuvable'), findsOneWidget);

    // Sara vote contre, moi pour, puis je retire mon vote
    trips.addVote('t1', 'u2', -1);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pour'));
    await tester.pumpAndSettle();
    expect((await trips.items('a1')).single.upVotes, 1);
    expect((await trips.items('a1')).single.downVotes, 1);
    await tester.tap(find.byTooltip('Pour'));
    await tester.pumpAndSettle();
    expect((await trips.items('a1')).single.myVote, 0);
  });

  testWidgets('Programme : tri par votes et carte sans lieu', (tester) async {
    final trips = useMemoryTrips();
    await trips.add('a1', const TripItemDraft(name: 'Souk'));
    await trips.add('a1', const TripItemDraft(name: 'Désert d\'Agafay'));
    trips.addVote('t2', 'u2', 1);
    await openProgram(tester);

    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('Souk'), lessThan(y('Désert d\'Agafay')));
    await tester.tap(find.text('Les plus votées'));
    await tester.pumpAndSettle();
    expect(y('Désert d\'Agafay'), lessThan(y('Souk')));

    await tester.tap(find.text('Carte'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Aucun lieu à afficher'), findsOneWidget);
  });

  testWidgets('Programme : la carte affiche un repère numéroté par lieu', (tester) async {
    final trips = useMemoryTrips();
    await trips.add('a1', const TripItemDraft(name: 'Jardin Majorelle', latitude: 31.6417, longitude: -8.0035));
    await trips.add('a1', const TripItemDraft(name: 'Souk'));
    await openProgram(tester);
    await tester.tap(find.text('Carte'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('1 élément sans lieu trouvé n\'est pas affiché'), findsOneWidget);
    await tester.tap(find.text('1'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Jardin Majorelle'), findsOneWidget);
  });

  testWidgets('Programme : le lieu choisi dans les suggestions est placé sur la carte', (tester) async {
    final trips = useMemoryTrips();
    PlaceGeocoder.instance = FakePlaces();
    addTearDown(() => PlaceGeocoder.instance = const NoGeocoder());
    await openProgram(tester);
    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Lieu'), 'Emsi');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emsi Agdal 2'));
    await tester.pumpAndSettle();
    expect(find.text('Rue Assouhaili 3, Rabat'), findsOneWidget); // adresse remplie
    await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
    await tester.pumpAndSettle();
    final item = (await trips.items('a1')).single;
    expect(item.name, 'Emsi Agdal 2'); // nom repris du lieu, le champ était vide
    expect(item.latitude, 34.006);
  });

  testWidgets('Programme : un élément sans position est placé automatiquement', (tester) async {
    final trips = useMemoryTrips();
    await trips.add('a1', const TripItemDraft(name: 'Emsi', place: 'Emsi Agdal 2'));
    PlaceGeocoder.instance = FakePlaces();
    addTearDown(() => PlaceGeocoder.instance = const NoGeocoder());
    await openProgram(tester);
    await tester.pumpAndSettle();
    expect(find.text('1 lieu placé sur la carte'), findsOneWidget);
    expect((await trips.items('a1')).single.hasPosition, isTrue);
  });

  testWidgets('Programme : calendrier par jour et par heure, carte filtrée par date', (tester) async {
    final trips = useMemoryTrips();
    final day1 = DateTime(2026, 10, 20), day2 = DateTime(2026, 10, 21);
    await trips.add(
      'a1',
      TripItemDraft(name: 'Dîner place Jemaa', date: day1, time: const TimeOfDay(hour: 20, minute: 0)),
    );
    await trips.add(
      'a1',
      TripItemDraft(name: 'Jardin Majorelle', date: day1, time: const TimeOfDay(hour: 9, minute: 30)),
    );
    await trips.add('a1', TripItemDraft(name: 'Désert d\'Agafay', date: day2, latitude: 31.4, longitude: -8.2));
    await trips.add(
      'a1',
      TripItemDraft(
        name: 'Musée YSL',
        date: day1,
        time: const TimeOfDay(hour: 11, minute: 0),
        latitude: 31.64,
        longitude: -8.0,
      ),
    );
    await openProgram(tester);

    await tester.tap(find.text('Calendrier'));
    await tester.pumpAndSettle();
    // Premier jour prévu, activités dans l'ordre des heures
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('09h30'), lessThan(y('11h00')));
    expect(y('Jardin Majorelle'), lessThan(y('Musée YSL')));
    expect(y('Musée YSL'), lessThan(y('Dîner place Jemaa')));
    expect(find.text('Désert d\'Agafay'), findsNothing);
    await tester.tap(find.text('mer. 21 oct. · 1'));
    await tester.pumpAndSettle();
    expect(find.text('Désert d\'Agafay'), findsOneWidget);
    expect(find.text('Jardin Majorelle'), findsNothing);

    await tester.tap(find.text('Carte'));
    await mapFrames(tester);
    expect(find.text('Tous · 4'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // Musée YSL (le 20) puis Agafay (le 21) : ordre chronologique
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.text('mer. 21 oct. · 1'));
    await mapFrames(tester);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsNothing);
    await tester.tap(find.text('mar. 20 oct. · 3'));
    await mapFrames(tester);
    expect(find.text('2 éléments sans lieu trouvé ne sont pas affichés'), findsOneWidget);
  });

  testWidgets('Programme : sur iPhone, carte Apple Plans avec les repères dans l\'ordre', (tester) async {
    final trips = useMemoryTrips();
    final day = DateTime(2026, 10, 20);
    await trips.add(
      'a1',
      TripItemDraft(
        name: 'Kasbah des Oudayas',
        date: day,
        time: const TimeOfDay(hour: 15, minute: 0),
        latitude: 34.03,
        longitude: -6.84,
      ),
    );
    await trips.add(
      'a1',
      TripItemDraft(
        name: 'Tour Hassan',
        date: day,
        time: const TimeOfDay(hour: 10, minute: 0),
        latitude: 34.02,
        longitude: -6.82,
      ),
    );
    // La vue native n'existe pas dans les tests : on simule sa création
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, (_) async => null);
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await openProgram(tester);
    await tester.tap(find.text('Carte'));
    await tester.pumpAndSettle();
    final map = tester.widget<AppleMap>(find.byType(AppleMap));
    expect([for (final p in map.pins) '${p.label} ${p.title}'], ['1 Tour Hassan', '2 Kasbah des Oudayas']);
    map.onTap(map.pins.last.id);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Pour'), findsOneWidget); // fiche ouverte, on peut voter
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Organiser le trajet : options, trajet proposé puis « Appliquer »', (tester) async {
    final trips = useMemoryTrips();
    await trips.add('a1', const TripItemDraft(name: 'Kasbah des Oudayas', latitude: 34.03, longitude: -6.84));
    await trips.add('a1', const TripItemDraft(name: 'Tour Hassan', latitude: 34.02, longitude: -6.82));
    final planner = FakePlanner();
    TripPlanner.instance = planner;
    addTearDown(() => TripPlanner.instance = HttpTripPlanner(token: () => null));
    await openProgram(tester);

    await tester.tap(find.text('Organiser le trajet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voiture'));
    await tester.tap(find.text('3 max'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Organiser'));
    await tester.pumpAndSettle();
    expect(planner.mode, TravelMode.driving);
    expect(planner.maxPerDay, 3);

    expect(find.text('25 min gagnées'), findsOneWidget);
    expect(find.text('20 min de trajet en voiture au lieu de 45 min'), findsOneWidget);
    expect(find.text('12 min · 3,4 km'), findsOneWidget);
    expect(find.text('Commencez par la Tour Hassan, tôt le matin.'), findsOneWidget);

    await tester.tap(find.text('Appliquer ce programme'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Appliquer'));
    await tester.pumpAndSettle();
    expect(find.text('Programme mis à jour'), findsOneWidget);
    final items = await trips.items('a1');
    final hassan = items.firstWhere((i) => i.name == 'Tour Hassan');
    expect(hassan.time, const TimeOfDay(hour: 9, minute: 0));
    expect(hassan.date, DateTime(2026, 10, 20)); // jour proposé appliqué
  });

  testWidgets('Trajet proposé : « Ouvrir dans Plans » envoie les étapes dans l\'ordre', (tester) async {
    final trips = useMemoryTrips();
    await trips.add('a1', const TripItemDraft(name: 'Kasbah des Oudayas', latitude: 34.03, longitude: -6.84));
    await trips.add('a1', const TripItemDraft(name: 'Tour Hassan', latitude: 34.02, longitude: -6.82));
    TripPlanner.instance = FakePlanner();
    addTearDown(() => TripPlanner.instance = HttpTripPlanner(token: () => null));
    MethodCall? opened;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('equipay/places'), (call) async {
      opened = call;
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      messenger.setMockMethodCallHandler(const MethodChannel('equipay/places'), null);
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await openProgram(tester);
    await tester.tap(find.text('Organiser le trajet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Organiser'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ouvrir l\'itinéraire dans Plans'));
    await tester.pumpAndSettle();
    expect(opened?.method, 'openDirections');
    final args = opened!.arguments as Map;
    expect(args['mode'], 'walking');
    expect([for (final s in args['stops'] as List) (s as List)[2]], ['Tour Hassan', 'Kasbah des Oudayas']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Programme : un spectateur voit sans ajouter ni voter', (tester) async {
    final trips = useMemoryTrips();
    await trips.add('a1', const TripItemDraft(name: 'Souk'));
    await openProgram(tester, role: MemberRole.viewer);
    expect(find.text('Souk'), findsOneWidget);
    expect(find.text('Ajouter'), findsNothing);
    final up = tester.widget<OutlinedButton>(
      find.descendant(of: find.byTooltip('Pour'), matching: find.byWidgetPredicate((w) => w is OutlinedButton)),
    );
    expect(up.onPressed, isNull);
  });

  testWidgets('Programme : seulement pour les voyages et les sorties', (tester) async {
    useMemoryTrips();
    final repo = FakeActivityRepository()
      ..activities.add(const Activity(id: 'a1', name: 'Coloc', type: ActivityType.quotidien, role: MemberRole.owner));
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coloc'));
    await tester.pumpAndSettle();
    expect(find.text('Programme'), findsNothing);
  });
}

/// Faux service de lieux : connaît seulement « Emsi Agdal 2 ».
class FakePlaces implements PlaceGeocoder {
  static const emsi = PlaceSuggestion(
    name: 'Emsi Agdal 2',
    address: 'Rue Assouhaili 3, Rabat',
    latitude: 34.006,
    longitude: -6.846,
  );

  @override
  Future<List<PlaceSuggestion>> search(String query) async => query.toLowerCase().contains('emsi') ? [emsi] : [];

  @override
  Future<(double, double)?> locate({String? place, String? address}) async =>
      (place ?? '').toLowerCase().contains('emsi') ? (emsi.latitude, emsi.longitude) : null;
}

/// Faux planificateur : renvoie toujours Tour Hassan puis Kasbah des Oudayas, le 20 octobre.
class FakePlanner implements TripPlanner {
  TravelMode? mode;
  int? maxPerDay;

  @override
  Future<TripPlan> optimize(List<TripItem> items, {required TravelMode mode, int? maxPerDay, String? notes}) async {
    this.mode = mode;
    this.maxPerDay = maxPerDay;
    final ids = {for (final i in items) i.name: i.id};
    return TripPlan.fromJson({
      'mode': mode.name,
      'estimated': false,
      'total_seconds': 1200,
      'current_seconds': 2700,
      'saved_seconds': 1500,
      'days': [
        {
          'date': '2026-10-20',
          'travel_seconds': 720,
          'stops': [
            {
              'id': ids['Tour Hassan'],
              'name': 'Tour Hassan',
              'time': '09:00',
              'date_assigned': true,
              'next_seconds': 720,
              'next_meters': 3400,
            },
            {'id': ids['Kasbah des Oudayas'], 'name': 'Kasbah des Oudayas', 'time': '10:45', 'date_assigned': true},
          ],
        },
      ],
      'excluded': [],
      'summary': 'Commencez par la Tour Hassan, tôt le matin.',
      'model_version': 'Qwen3-4B-Instruct-2507-4bit',
    });
  }
}
