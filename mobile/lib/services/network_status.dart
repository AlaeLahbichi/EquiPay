import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Indique en continu si l'appareil a une connexion réseau.
class NetworkStatus {
  NetworkStatus(Stream<bool> changes, {bool initial = true}) : online = ValueNotifier(initial) {
    _subscription = changes.listen((value) => online.value = value);
  }

  /// Statut réel de l'appareil (Wi-Fi, données mobiles…).
  factory NetworkStatus.device() {
    final connectivity = Connectivity();
    final controller = StreamController<bool>();
    connectivity.checkConnectivity().then((r) => controller.add(_isOnline(r)));
    connectivity.onConnectivityChanged.listen((r) => controller.add(_isOnline(r)));
    return NetworkStatus(controller.stream);
  }

  /// Toujours en ligne (tests).
  factory NetworkStatus.alwaysOnline() => NetworkStatus(const Stream.empty());

  final ValueNotifier<bool> online;
  late final StreamSubscription<bool> _subscription;

  static bool _isOnline(List<ConnectivityResult> results) => results.any((r) => r != ConnectivityResult.none);

  void dispose() {
    _subscription.cancel();
    online.dispose();
  }
}
