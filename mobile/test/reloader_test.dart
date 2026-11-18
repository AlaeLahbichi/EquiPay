import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/utils/reloader.dart';

void main() {
  // testWidgets : l'horloge est simulée, tester.pump fait avancer les minuteurs
  testWidgets('Reloader : 5 événements rapprochés → un seul chargement', (tester) async {
    var runs = 0;
    final reloader = Reloader(() async => runs++);
    for (var i = 0; i < 5; i++) {
      reloader.schedule();
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(runs, 0);
    await tester.pump(const Duration(milliseconds: 400));
    expect(runs, 1);
  });

  test('Reloader : un changement pendant un chargement en relance un seul autre', () async {
    var runs = 0;
    final gate = Completer<void>();
    final reloader = Reloader(() async {
      runs++;
      if (runs == 1) await gate.future;
    });
    final first = reloader.now();
    reloader.now();
    reloader.now();
    gate.complete();
    await first;
    expect(runs, 2);
  });
}
