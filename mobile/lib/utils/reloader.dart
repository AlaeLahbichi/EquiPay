import 'dart:async';

/// Regroupe les rechargements d'une page.
///
/// Le temps réel envoie un événement par ligne modifiée (5 photos envoyées = 5 événements) :
/// [schedule] attend un court instant pour les regrouper, et un seul chargement tourne à la fois.
/// Un changement reçu pendant un chargement en relance un seul autre, à la fin.
class Reloader {
  Reloader(this._run, {this.delay = const Duration(milliseconds: 300)});

  final Future<void> Function() _run;
  final Duration delay;

  Timer? _timer;
  Future<void>? _running;
  var _again = false;

  /// Rechargement après un événement temps réel.
  void schedule() {
    _timer?.cancel();
    _timer = Timer(delay, now);
  }

  /// Rechargement immédiat (ouverture de la page, tirer pour actualiser…).
  Future<void> now() {
    _timer?.cancel();
    if (_running case final running?) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _run();
    } while (_again);
  }

  void dispose() => _timer?.cancel();
}
