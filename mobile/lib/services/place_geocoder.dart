import 'dart:async';

import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';

/// Un lieu trouvé : nom, adresse complète et position.
class PlaceSuggestion {
  const PlaceSuggestion({required this.name, required this.address, required this.latitude, required this.longitude});

  final String name;
  final String address;
  final double latitude;
  final double longitude;
}

/// Trouve la position (latitude, longitude) d'un lieu à partir de son nom et de son adresse.
abstract class PlaceGeocoder {
  /// Service utilisé par l'app (Apple Plans + géocodage du téléphone, branché dans main.dart).
  static PlaceGeocoder instance = const NoGeocoder();

  /// Lieux correspondant à un texte (« Emsi Agdal », « Jardin Majorelle »…), pour les suggestions.
  Future<List<PlaceSuggestion>> search(String query);

  /// null si le lieu est introuvable ou sans réseau : l'élément reste dans la liste, sans repère sur la carte.
  Future<(double, double)?> locate({String? place, String? address});

  /// Texte envoyé au géocodeur : « Jardin Majorelle, Rue Yves St Laurent, Marrakech ».
  static String? query({String? place, String? address}) {
    final parts = [place, address].whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    // « Emsi Agdal 2, Emsi agdal 2 » : inutile de répéter le même texte
    final unique = <String>[];
    for (final p in parts) {
      if (!unique.any((u) => u.toLowerCase() == p.toLowerCase())) unique.add(p);
    }
    return unique.isEmpty ? null : unique.join(', ');
  }
}

/// Aucun géocodage (tests, ou avant le branchement dans main.dart).
class NoGeocoder implements PlaceGeocoder {
  const NoGeocoder();

  @override
  Future<List<PlaceSuggestion>> search(String query) async => const [];

  @override
  Future<(double, double)?> locate({String? place, String? address}) async => null;
}

/// Recherche de lieux d'Apple Plans (établissements, monuments, adresses), puis géocodage d'adresse
/// du téléphone en secours. Gratuit et sans clé.
class NativeGeocoder implements PlaceGeocoder {
  NativeGeocoder() : _geocoding = Geocoding();

  static const _channel = MethodChannel('equipay/places');
  static const _timeout = Duration(seconds: 10);

  final Geocoding _geocoding;

  @override
  Future<List<PlaceSuggestion>> search(String query) async {
    if (query.trim().length < 2) return const [];
    try {
      final rows = await _channel.invokeListMethod<Map<Object?, Object?>>('search', {'query': query}).timeout(_timeout);
      return [
        for (final r in rows ?? const <Map<Object?, Object?>>[])
          PlaceSuggestion(
            name: r['name'] as String? ?? '',
            address: r['address'] as String? ?? '',
            latitude: (r['latitude'] as num).toDouble(),
            longitude: (r['longitude'] as num).toDouble(),
          ),
      ];
    } catch (_) {
      return const []; // hors ligne, ou pas d'Apple Plans (Android)
    }
  }

  @override
  Future<(double, double)?> locate({String? place, String? address}) async {
    final full = PlaceGeocoder.query(place: place, address: address);
    if (full == null) return null;
    // 1. Apple Plans connaît les établissements (« Emsi Agdal 2 ») et les adresses
    final found = await search(full);
    if (found.isNotEmpty) return (found.first.latitude, found.first.longitude);
    // 2. Secours : géocodage d'adresse postale (adresse seule, puis lieu + adresse)
    for (final q in {PlaceGeocoder.query(address: address), full}) {
      if (q == null) continue;
      try {
        final points = await _geocoding.locationFromAddress(q).timeout(_timeout);
        if (points.isNotEmpty) return (points.first.latitude, points.first.longitude);
      } catch (_) {
        // Introuvable ou hors ligne : on essaie la requête suivante
      }
    }
    return null;
  }
}
