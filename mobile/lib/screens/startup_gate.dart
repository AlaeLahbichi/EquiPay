import 'package:flutter/material.dart';

import '../services/activity_repository.dart';
import '../services/network_status.dart';
import '../theme/app_colors.dart';
import '../widgets/logo_loader.dart';
import '../l10n/i18n.dart';

/// Affiche le logo animé pendant le démarrage (connexion…), puis l'app.
/// En cas d'échec : message + bouton Réessayer, et nouvel essai automatique
/// dès que la connexion revient.
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.init,
    required this.network,
    required this.child,
    this.minDisplay = const Duration(milliseconds: 1200),
  });

  final Future<void> Function() init;
  final NetworkStatus network;
  final Widget child;

  /// Durée minimale d'affichage, pour que l'animation ne « clignote » pas.
  final Duration minDisplay;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.network.online.addListener(_onNetworkChange);
    _start();
  }

  @override
  void dispose() {
    widget.network.online.removeListener(_onNetworkChange);
    super.dispose();
  }

  void _onNetworkChange() {
    if (widget.network.online.value && _error != null) _start();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      await Future.wait([widget.init(), Future<void>.delayed(widget.minDisplay)]);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: _ready
          ? widget.child
          : Scaffold(
              key: ValueKey(_error),
              backgroundColor: Colors.white,
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: _error == null
                      ? LogoLoader(logoSize: 160, message: tr('Bienvenue !'))
                      : _StartupError(message: _error!, onRetry: _start),
                ),
              ),
            ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset('assets/branding/logo.png', width: 140),
        const SizedBox(height: 24),
        const Icon(Icons.wifi_off_rounded, color: AppColors.textSecondary, size: 32),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.text, fontSize: 16),
        ),
        const SizedBox(height: 4),
        Text(
          tr('On réessaiera automatiquement dès que la connexion revient.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 20),
        FilledButton(onPressed: onRetry, child: Text(tr('Réessayer'))),
      ],
    );
  }
}
