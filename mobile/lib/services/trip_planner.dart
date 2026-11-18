import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/env.dart';
import '../models/plan.dart';
import '../models/trip_item.dart';
import '../l10n/i18n.dart';

/// Façon de se déplacer entre les lieux.
enum TravelMode {
  walking('À pied', Icons.directions_walk_rounded, 'à pied'),
  cycling('Vélo', Icons.directions_bike_rounded, 'à vélo'),
  driving('Voiture', Icons.directions_car_rounded, 'en voiture');

  const TravelMode(this._label, this.icon, this._inSentence);

  final String _label;

  String get label => _label.tr;
  final IconData icon;
  final String _inSentence;
  String get inSentence => _inSentence.tr;
}

/// Une étape du trajet proposé.
class PlannedStop {
  const PlannedStop({
    required this.id,
    required this.name,
    required this.time,
    required this.timeFixed,
    required this.dateAssigned,
    this.nextSeconds,
    this.nextMeters,
  });

  final String id;
  final String name;

  /// Heure fixée par le groupe, ou proposée par l'algorithme.
  final TimeOfDay time;
  final bool timeFixed;

  /// Lieu sans date, placé sur ce jour par l'algorithme.
  final bool dateAssigned;

  /// Trajet vers l'étape suivante (null pour la dernière).
  final int? nextSeconds;
  final int? nextMeters;

  factory PlannedStop.fromJson(Map<String, dynamic> j) {
    final parts = (j['time'] as String).split(':');
    return PlannedStop(
      id: j['id'] as String,
      name: j['name'] as String,
      time: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
      timeFixed: j['time_fixed'] as bool? ?? false,
      dateAssigned: j['date_assigned'] as bool? ?? false,
      nextSeconds: (j['next_seconds'] as num?)?.toInt(),
      nextMeters: (j['next_meters'] as num?)?.toInt(),
    );
  }
}

/// Une journée du trajet proposé (date null : lieux sans jour disponible).
class PlannedDay {
  const PlannedDay({required this.date, required this.travelSeconds, required this.stops});

  final DateTime? date;
  final int travelSeconds;
  final List<PlannedStop> stops;

  factory PlannedDay.fromJson(Map<String, dynamic> j) => PlannedDay(
    date: j['date'] == null ? null : DateTime.parse(j['date'] as String),
    travelSeconds: (j['travel_seconds'] as num).toInt(),
    stops: [for (final s in j['stops'] as List) PlannedStop.fromJson(s as Map<String, dynamic>)],
  );
}

/// Trajet proposé : ordre jour par jour, temps gagné et texte de l'IA.
class TripPlan {
  const TripPlan({
    required this.mode,
    required this.estimated,
    required this.totalSeconds,
    required this.currentSeconds,
    required this.savedSeconds,
    required this.days,
    required this.excluded,
    this.summary,
    this.modelVersion,
  });

  final TravelMode mode;

  /// Temps estimés à vol d'oiseau (service d'itinéraire injoignable).
  final bool estimated;
  final int totalSeconds;
  final int currentSeconds;
  final int savedSeconds;
  final List<PlannedDay> days;

  /// Lieux écartés (plus de contre que de pour) : (id, nom).
  final List<(String, String)> excluded;
  final String? summary;
  final String? modelVersion;

  factory TripPlan.fromJson(Map<String, dynamic> j) => TripPlan(
    mode: TravelMode.values.byName(j['mode'] as String),
    estimated: j['estimated'] as bool? ?? false,
    totalSeconds: (j['total_seconds'] as num).toInt(),
    currentSeconds: (j['current_seconds'] as num).toInt(),
    savedSeconds: (j['saved_seconds'] as num).toInt(),
    days: [for (final d in j['days'] as List) PlannedDay.fromJson(d as Map<String, dynamic>)],
    excluded: [for (final e in j['excluded'] as List? ?? const []) ((e as Map)['id'] as String, e['name'] as String)],
    summary: j['summary'] as String?,
    modelVersion: j['model_version'] as String?,
  );
}

class TripPlanException implements Exception {
  const TripPlanException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Organise le trajet : appelle le backend (OSRM + algorithme + Qwen3-4B). Ne modifie rien.
abstract class TripPlanner {
  /// Service de l'app (remplacé dans main.dart et dans les tests).
  static TripPlanner instance = HttpTripPlanner(token: () => null);

  Future<TripPlan> optimize(List<TripItem> items, {required TravelMode mode, int? maxPerDay, String? notes});
}

class HttpTripPlanner implements TripPlanner {
  HttpTripPlanner({required this.token, http.Client? client}) : _http = client ?? http.Client();

  final String? Function() token;
  final http.Client _http;

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Future<TripPlan> optimize(List<TripItem> items, {required TravelMode mode, int? maxPerDay, String? notes}) async {
    if (Env.apiUrl.isEmpty) throw TripPlanException(tr('Serveur non configuré (API_URL manquant dans env.json).'));
    final jwt = token();
    if (jwt == null) throw TripPlanException(tr('Connecte-toi pour organiser le trajet.'));
    final http.Response res;
    try {
      // Premier appel : ~10 s de chargement du modèle, plus le calcul des itinéraires
      res = await _http
          .post(
            Uri.parse('${Env.apiUrl}/trips/optimize'),
            headers: {'Authorization': 'Bearer $jwt', 'Content-Type': 'application/json'},
            body: jsonEncode({
              'mode': mode.name,
              'max_per_day': maxPerDay,
              'notes': (notes ?? '').trim().isEmpty ? null : notes!.trim(),
              'stops': [
                for (final i in items)
                  if (i.hasPosition && !i.done)
                    {
                      'id': i.id,
                      'name': i.name,
                      'place': i.place,
                      'latitude': i.latitude,
                      'longitude': i.longitude,
                      'date': i.date == null ? null : '${i.date!.year}-${_two(i.date!.month)}-${_two(i.date!.day)}',
                      'time': i.time == null ? null : '${_two(i.time!.hour)}:${_two(i.time!.minute)}:00',
                      'up': i.upVotes,
                      'down': i.downVotes,
                    },
              ],
            }),
          )
          .timeout(const Duration(seconds: 120));
    } on TimeoutException {
      throw TripPlanException(tr('L\'organisation prend trop de temps. Réessaie dans un instant.'));
    } catch (_) {
      throw TripPlanException(tr('Impossible de joindre le serveur. Vérifie ta connexion.'));
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw TripPlanException(tr('Réponse inattendue du serveur.'));
    }
    if (res.statusCode == 200 && body is Map<String, dynamic>) return TripPlan.fromJson(body);
    final limited = PlanLimitException.fromBody(res.statusCode, body);
    if (limited != null) throw limited;
    if (res.statusCode == 401) throw TripPlanException(tr('Ta session a expiré. Reconnecte-toi puis réessaie.'));
    final detail = body is Map<String, dynamic> ? body['detail'] : null;
    throw TripPlanException(detail is String ? detail : tr('L\'organisation du trajet est indisponible.'));
  }
}

/// « 12 min », « 1 h 05 ».
String formatTravel(int seconds) {
  final minutes = (seconds / 60).round().clamp(1, 100000);
  return minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h ${_pad(minutes % 60)}';
}

String _pad(int v) => v.toString().padLeft(2, '0');

/// « 850 m », « 3,4 km ».
String formatDistance(int meters) =>
    meters < 1000 ? '${(meters / 10).round() * 10} m' : '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
