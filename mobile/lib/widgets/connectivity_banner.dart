import 'dart:async';

import 'package:flutter/material.dart';

import '../services/network_status.dart';
import '../theme/app_colors.dart';
import '../l10n/i18n.dart';

enum _BannerState { hidden, offline, backOnline }

/// Bandeau en haut de l'écran : « Pas de connexion » puis « Connexion rétablie ».
class ConnectivityBanner extends StatefulWidget {
  const ConnectivityBanner({super.key, required this.network, required this.child});

  final NetworkStatus network;
  final Widget child;

  @override
  State<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends State<ConnectivityBanner> {
  _BannerState _state = _BannerState.hidden;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.network.online.addListener(_onChange);
    if (!widget.network.online.value) _state = _BannerState.offline;
  }

  @override
  void dispose() {
    widget.network.online.removeListener(_onChange);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _onChange() {
    _hideTimer?.cancel();
    if (!widget.network.online.value) {
      setState(() => _state = _BannerState.offline);
    } else if (_state == _BannerState.offline) {
      setState(() => _state = _BannerState.backOnline);
      _hideTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _state = _BannerState.hidden);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _state != _BannerState.hidden;
    final offline = _state == _BannerState.offline;
    return Column(
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: !visible
              ? const SizedBox(width: double.infinity)
              : Material(
                  color: offline ? AppColors.negative : AppColors.positive,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(offline ? Icons.wifi_off_rounded : Icons.wifi_rounded, color: Colors.white, size: 18),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              offline
                                  ? tr('Hors ligne · tes dernières données restent consultables')
                                  : tr('Connexion rétablie'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
        Expanded(
          child: MediaQuery.removePadding(context: context, removeTop: visible, child: widget.child),
        ),
      ],
    );
  }
}
