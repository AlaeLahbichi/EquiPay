import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/i18n.dart';
import '../services/account_service.dart';
import '../services/activity_repository.dart';
import '../services/expense_repository.dart';
import '../services/assistant_service.dart';
import '../services/receipt_scanner.dart';
import '../services/auth_service.dart';
import '../services/network_status.dart';
import '../services/notification_service.dart';
import '../services/request_repository.dart';
import '../services/requests_controller.dart';
import '../services/settings_controller.dart';
import 'budget/budget_page.dart';
import 'home/home_page.dart';
import 'onboarding/onboarding_page.dart';
import 'profile/profile_page.dart';
import 'requests/requests_page.dart';

/// Structure principale : les 4 onglets et la barre de navigation du bas.
class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.repository,
    required this.expenses,
    required this.receipts,
    required this.requests,
    required this.auth,
    required this.settings,
    required this.assistant,
    required this.network,
  });

  final ActivityRepository repository;
  final ExpenseRepository expenses;
  final ReceiptScanner receipts;
  final RequestRepository requests;
  final AuthService auth;
  final SettingsController settings;
  final AssistantService assistant;
  final NetworkStatus network;

  static const homeTab = 0;
  static const requestsTab = 1;
  static const budgetTab = 2;
  static const profileTab = 3;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  late final _requests = RequestsController(repository: widget.requests, auth: widget.auth);
  StreamSubscription<RequestNotice>? _notices;
  StreamSubscription<String>? _opened;
  StreamSubscription<void>? _answered;

  var _onboarding = false;

  @override
  void initState() {
    super.initState();
    _notices = _requests.notices.listen(_showNotice);
    // Notification touchée : on ouvre l'onglet concerné ; réponse depuis la notification : on recharge
    _opened = NotificationService.instance.opened.stream.listen((payload) {
      if (!mounted) return;
      _select(switch (payload) {
        'requests' => MainShell.requestsTab,
        'budget' => MainShell.budgetTab,
        _ => MainShell.homeTab,
      });
    });
    _answered = NotificationService.instance.answered.stream.listen((_) => _requests.refresh());
    AccountService.instance.state.addListener(_checkOnboarding);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOnboarding());
  }

  @override
  void dispose() {
    AccountService.instance.state.removeListener(_checkOnboarding);
    _notices?.cancel();
    _opened?.cancel();
    _answered?.cancel();
    _requests.dispose();
    super.dispose();
  }

  /// Nouveau compte : le formulaire de bienvenue s'ouvre une fois, par-dessus l'app.
  Future<void> _checkOnboarding() async {
    final state = AccountService.instance.state.value;
    final user = widget.auth.user.value;
    if (!mounted || _onboarding || state == null || state.onboarded || user == null) return;
    _onboarding = true;
    await Navigator.of(context)
        .push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => OnboardingPage(user: user)));
    _onboarding = false;
  }

  void _select(int index) {
    setState(() => _index = index);
    if (index == MainShell.requestsTab) _markSeenSoon();
  }

  // Laisse le temps de voir les réponses mises en avant avant d'effacer la pastille
  void _markSeenSoon() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _index == MainShell.requestsTab) _requests.markSeen();
    });
  }

  // Le destinataire est prévenu à chaque action (nouvelle demande, réponse, annulation)
  void _showNotice(RequestNotice notice) {
    if (!mounted) return;
    // Notification sur le téléphone aussi (avec Accepter / Refuser pour une nouvelle demande)
    NotificationService.instance.checkNow?.call();
    if (_index == MainShell.requestsTab) _markSeenSoon();
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          content: Row(
            children: [
              Icon(
                notice.incoming ? Icons.person_add_alt_1_rounded : Icons.notifications_active_rounded,
                color: Colors.white,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(notice.message)),
            ],
          ),
          action: _index == MainShell.requestsTab
              ? null
              : SnackBarAction(label: tr('Voir'), onPressed: () => _select(MainShell.requestsTab)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomePage(
            repository: widget.repository,
            expenses: widget.expenses,
            receipts: widget.receipts,
            auth: widget.auth,
            network: widget.network,
            onSignInRequested: () => _select(MainShell.profileTab),
          ),
          RequestsPage(controller: _requests, onSignInRequested: () => _select(MainShell.profileTab)),
          BudgetPage(auth: widget.auth, onSignInRequested: () => _select(MainShell.profileTab)),
          ProfilePage(
            auth: widget.auth,
            settings: widget.settings,
            assistant: widget.assistant,
            activities: widget.repository,
            expenses: widget.expenses,
            receipts: widget.receipts,
          ),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: _requests,
        builder: (_, _) => _NavBar(index: _index, onSelect: _select, badge: _requests.badge),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.index, required this.onSelect, required this.badge});

  final int index;
  final ValueChanged<int> onSelect;

  /// Nombre affiché sur l'onglet Requests (0 : pas de pastille).
  final int badge;

  @override
  Widget build(BuildContext context) {
    Widget withBadge(Widget icon) => Badge(isLabelVisible: badge > 0, label: Text('$badge'), child: icon);
    return NavigationBar(
      selectedIndex: index,
      onDestinationSelected: onSelect,
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: tr('EquiPay'),
        ),
        NavigationDestination(
          icon: withBadge(const Icon(Icons.mail_outline_rounded)),
          selectedIcon: withBadge(const Icon(Icons.mail_rounded)),
          label: tr('Demandes'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.account_balance_wallet_outlined),
          selectedIcon: const Icon(Icons.account_balance_wallet_rounded),
          label: tr('Budget'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.person_outline_rounded),
          selectedIcon: const Icon(Icons.person_rounded),
          label: tr('Profil'),
        ),
      ],
    );
  }
}
