import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Un repère sur la carte : texte dans la bulle (numéro), couleur, titre et sous-titre.
@immutable
class MapPin {
  const MapPin({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.label,
    required this.color,
    required this.title,
    this.subtitle,
    this.faded = false,
  });

  final String id;
  final double latitude;
  final double longitude;
  final String label;
  final Color color;
  final String title;
  final String? subtitle;
  final bool faded;

  Map<String, Object?> toMap() => {
    'id': id,
    'latitude': latitude,
    'longitude': longitude,
    'label': label,
    'color': color.toARGB32(),
    'title': title,
    'subtitle': subtitle,
    'faded': faded,
  };

  @override
  bool operator ==(Object other) => other is MapPin && mapEquals(toMap(), other.toMap());

  @override
  int get hashCode => Object.hashAll(toMap().values);
}

/// La carte Apple Plans (MapKit) native n'existe que sur iPhone et iPad.
bool get appleMapsAvailable => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Carte Apple Plans native : relief, bâtiments, lieux d'intérêt, mode sombre automatique.
/// Les repères sont les bulles de l'app Plans ; la carte se cadre sur eux à chaque changement.
class AppleMap extends StatefulWidget {
  const AppleMap({
    super.key,
    required this.pins,
    required this.onTap,
    this.route = const [],
    this.routeMode = 'walking',
  });

  final List<MapPin> pins;
  final ValueChanged<String> onTap;

  /// Étapes de l'itinéraire à tracer dans les rues, dans l'ordre (latitude, longitude). Vide : pas de tracé.
  final List<(double, double)> route;

  /// « walking », « cycling » ou « driving ».
  final String routeMode;

  @override
  State<AppleMap> createState() => _AppleMapState();
}

class _AppleMapState extends State<AppleMap> {
  MethodChannel? _channel;

  void _created(int id) {
    final channel = MethodChannel('equipay/apple-map/$id');
    channel.setMethodCallHandler((call) async {
      if (call.method == 'tap') widget.onTap(call.arguments as String);
    });
    _channel = channel;
  }

  Map<String, Object?> get _args => {
    'pins': [for (final p in widget.pins) p.toMap()],
    'route': {
      'mode': widget.routeMode,
      'points': [
        for (final (lat, lng) in widget.route) [lat, lng],
      ],
    },
  };

  @override
  void didUpdateWidget(AppleMap old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.pins, widget.pins) ||
        !listEquals(old.route, widget.route) ||
        old.routeMode != widget.routeMode) {
      _channel?.invokeMethod('setPins', _args);
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UiKitView(
      viewType: 'equipay/apple-map',
      creationParams: _args,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _created,
      // La carte reçoit directement les gestes (déplacer, zoomer, pivoter)
      gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
    );
  }
}

/// Ouvre l'app Plans avec l'itinéraire : départ au premier lieu, étapes dans l'ordre, arrivée au dernier.
/// [stops] : (latitude, longitude, nom). [mode] : « walking », « cycling » ou « driving ».
/// Renvoie false si Plans n'a pas pu s'ouvrir.
Future<bool> openInAppleMaps(List<(double, double, String)> stops, {required String mode}) async {
  if (stops.isEmpty) return false;
  try {
    final opened = await const MethodChannel('equipay/places').invokeMethod<bool>('openDirections', {
      'stops': [
        for (final (lat, lng, name) in stops) [lat, lng, name],
      ],
      'mode': mode,
    });
    return opened ?? false;
  } catch (_) {
    return false;
  }
}
