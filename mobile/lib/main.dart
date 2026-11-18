import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/env.dart';
import 'screens/main_shell.dart';
import 'screens/startup_gate.dart';
import 'services/account_service.dart';
import 'services/activity_repository.dart';
import 'services/assistant_service.dart';
import 'services/receipt_scanner.dart';
import 'services/auth_service.dart';
import 'services/budget_repository.dart';
import 'services/expense_describer.dart';
import 'services/place_geocoder.dart';
import 'services/expense_repository.dart';
import 'services/network_status.dart';
import 'services/notification_service.dart';
import 'services/offline_store.dart';
import 'services/pending_expenses.dart';
import 'services/request_repository.dart';
import 'services/settings_controller.dart';
import 'services/trip_planner.dart';
import 'services/trip_repository.dart';
import 'theme/app_theme.dart';
import 'widgets/connectivity_banner.dart';
import 'widgets/dismiss_keyboard.dart';
import 'l10n/i18n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Env.isConfigured) {
    runApp(const _MissingConfigApp());
    return;
  }
  // Ne fait pas d'appel réseau : fonctionne aussi hors ligne
  await Supabase.initialize(url: Env.supabaseUrl, publishableKey: Env.supabasePublishableKey);
  final client = Supabase.instance.client;
  // Hors ligne : dernières données chargées gardées sur le téléphone
  final network = NetworkStatus.device();
  OfflineStore.instance = await OfflineStore.load()
    ..online = network.online;
  final auth = SupabaseAuthService(client);
  final expenses = SupabaseExpenseRepository(client);
  // Dépenses ajoutées sans réseau : envoyées au démarrage et dès que la connexion revient
  Future<void> syncPending() async {
    final result = await expenses.syncPending();
    if (result.sent == 0 && result.rejected == 0) return;
    final sent = result.sent == 1 ? tr('1 dépense hors ligne envoyée') : tr('{0} dépenses hors ligne envoyées', [result.sent]);
    appMessenger.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          result.rejected == 0 ? sent : tr('{0} · {1} refusée(s) par le serveur, à ressaisir', [sent, result.rejected]),
        ),
      ),
    );
  }

  network.online.addListener(() {
    if (network.online.value) syncPending();
  });
  auth.user.addListener(() {
    if (auth.user.value != null && network.online.value) syncPending();
  });
  ExpenseDescriber.instance = HttpExpenseDescriber(token: () => auth.accessToken);
  TripRepository.instance = SupabaseTripRepository(client);
  PlaceGeocoder.instance = NativeGeocoder();
  TripPlanner.instance = HttpTripPlanner(token: () => auth.accessToken);
  AccountService.instance = SupabaseAccountService(client, auth);
  BudgetRepository.instance = SupabaseBudgetRepository(client);
  final settings = await SettingsController.load();
  _setUpNotifications(client, auth, settings);
  runApp(
    MyApp(
      repository: SupabaseActivityRepository(client),
      expenses: expenses,
      requests: SupabaseRequestRepository(client),
      auth: auth,
      settings: settings,
      assistant: HttpAssistantService(token: () => auth.accessToken),
      receipts: HttpReceiptScanner(token: () => auth.accessToken),
      network: network,
    ),
  );
}

/// Notifications : autorisation demandée une fois après la connexion, vérification des nouveautés
/// à l'ouverture, toutes les minutes quand l'app est ouverte, et en arrière-plan (Android).
void _setUpNotifications(SupabaseClient client, AuthService auth, SettingsController settings) {
  final service = NotificationService.instance..enabled = settings.notifications;
  service.init();
  Timer? timer;
  Future<void> check() async {
    if (!service.enabled || client.auth.currentUser == null) return;
    try {
      await NotificationService.checkForNews(client);
    } catch (_) {
      // Hors ligne : on réessaiera
    }
  }

  Future<void> onUser() async {
    timer?.cancel();
    if (auth.user.value == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (settings.notifications && !(prefs.getBool('notif_asked') ?? false)) {
      await prefs.setBool('notif_asked', true);
      final granted = await service.requestPermission();
      if (!granted) settings.setNotifications(false);
    }
    await service.setEnabled(settings.notifications);
    await check();
    timer = Timer.periodic(const Duration(minutes: 1), (_) => check());
  }

  service.checkNow = check;
  auth.user.addListener(onUser);
  onUser();
  settings.addListener(() {
    if (service.enabled != settings.notifications) service.setEnabled(settings.notifications);
  });
  AppLifecycleListener(onResume: check);
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.repository,
    required this.expenses,
    required this.requests,
    required this.auth,
    required this.settings,
    required this.assistant,
    required this.receipts,
    required this.network,
    this.startupMinDisplay = const Duration(milliseconds: 1200),
  });

  final ActivityRepository repository;
  final ExpenseRepository expenses;
  final RequestRepository requests;
  final AuthService auth;
  final SettingsController settings;
  final AssistantService assistant;
  final ReceiptScanner receipts;
  final NetworkStatus network;
  final Duration startupMinDisplay;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (_, _) => MaterialApp(
        title: tr('EquiPay'),
        scaffoldMessengerKey: appMessenger,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: settings.themeMode,
        // Langue choisie dans Profil (calendrier et boutons système compris ; l'arabe de droite à gauche)
        locale: settings.language.locale,
        supportedLocales: [for (final l in AppLanguage.values) l.locale],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        // Toucher un endroit vide ferme le clavier, sur tous les écrans.
        // Changer de langue reconstruit l'app pour que tous les textes soient traduits.
        builder: (_, child) => KeyedSubtree(
          key: ValueKey(settings.language),
          child: DismissKeyboard(
            child: ConnectivityBanner(network: network, child: child!),
          ),
        ),
        home: StartupGate(
          init: repository.ensureReady,
          network: network,
          minDisplay: startupMinDisplay,
          child: MainShell(
            repository: repository,
            expenses: expenses,
            requests: requests,
            auth: auth,
            settings: settings,
            assistant: assistant,
            receipts: receipts,
            network: network,
          ),
        ),
      ),
    );
  }
}

class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              tr('Configuration manquante.\nLance l\'app avec :\nflutter run --dart-define-from-file=env.json'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
