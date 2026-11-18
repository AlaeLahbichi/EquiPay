import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../l10n/i18n.dart';

/// Chargement animé : le logo « respire », trois points s'animent,
/// et le message s'adapte si le chargement dure.
class LogoLoader extends StatefulWidget {
  const LogoLoader({super.key, this.logoSize = 160, this.message, this.showCard = true});

  final double logoSize;
  /// null : « Chargement… ».
  final String? message;

  /// false sur fond blanc (démarrage) pour enchaîner sans couture avec l'écran natif.
  final bool showCard;

  static const slowAfter = Duration(seconds: 6);
  static const verySlowAfter = Duration(seconds: 15);

  @override
  State<LogoLoader> createState() => _LogoLoaderState();
}

class _LogoLoaderState extends State<LogoLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();
  final _timers = <Timer>[];
  int _stage = 0;

  @override
  void initState() {
    super.initState();
    _timers
      ..add(Timer(LogoLoader.slowAfter, () => setState(() => _stage = 1)))
      ..add(Timer(LogoLoader.verySlowAfter, () => setState(() => _stage = 2)));
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _controller.dispose();
    super.dispose();
  }

  String get _message => switch (_stage) {
    0 => widget.message ?? tr('Chargement…'),
    1 => tr('Ça prend un peu plus de temps que prévu…'),
    _ => tr('Connexion lente. Vérifie ton réseau, on continue d\'essayer.'),
  };

  @override
  Widget build(BuildContext context) {
    final size = widget.logoSize;
    return Semantics(
      label: _message,
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (_, child) {
              final wave = math.sin(_controller.value * 2 * math.pi);
              return Transform.scale(scale: 1 + 0.06 * wave, child: child);
            },
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(size * 0.22),
                boxShadow: widget.showCard
                    ? [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.15),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ]
                    : null,
              ),
              padding: EdgeInsets.all(widget.showCard ? size * 0.08 : 0),
              child: Image.asset('assets/branding/logo.png'),
            ),
          ),
          SizedBox(height: size * 0.18),
          _Dots(controller: _controller),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              _message,
              key: ValueKey(_stage),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.controller});

  final AnimationController controller;

  static const _colors = [AppColors.primary, AppColors.accent, AppColors.primary];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Transform.translate(
                offset: Offset(0, -6 * _bounce(i)),
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: _colors[i], shape: BoxShape.circle),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Rebond décalé pour chaque point (0 → 1 → 0).
  double _bounce(int i) {
    final t = (controller.value - i * 0.15) % 1.0;
    return t < 0.5 ? math.sin(t * 2 * math.pi).clamp(0.0, 1.0) : 0.0;
  }
}
