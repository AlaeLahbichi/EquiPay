import 'package:flutter/material.dart';

/// Une activité du programme d'un voyage ou d'une sortie, avec ses votes.
class TripItem {
  const TripItem({
    required this.id,
    required this.activityId,
    required this.createdBy,
    required this.name,
    this.place,
    this.address,
    this.date,
    this.time,
    this.latitude,
    this.longitude,
    this.done = false,
    this.upVotes = 0,
    this.downVotes = 0,
    this.myVote = 0,
  });

  final String id;
  final String activityId;
  final String createdBy;
  final String name;
  final String? place;
  final String? address;

  /// Jour prévu (sans heure).
  final DateTime? date;
  final TimeOfDay? time;
  final double? latitude;
  final double? longitude;
  final bool done;

  final int upVotes;
  final int downVotes;

  /// Vote de l'utilisateur connecté : 1 pour, -1 contre, 0 aucun.
  final int myVote;

  /// Pour moins contre : sert au tri « les plus votées ».
  int get score => upVotes - downVotes;

  bool get hasPosition => latitude != null && longitude != null;

  TripItem copyWith({bool? done, int? upVotes, int? downVotes, int? myVote, double? latitude, double? longitude}) =>
      TripItem(
        id: id,
        activityId: activityId,
        createdBy: createdBy,
        name: name,
        place: place,
        address: address,
        date: date,
        time: time,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        done: done ?? this.done,
        upVotes: upVotes ?? this.upVotes,
        downVotes: downVotes ?? this.downVotes,
        myVote: myVote ?? this.myVote,
      );

  /// Ligne de trip_items + votes de l'activité (lignes de trip_votes).
  factory TripItem.fromRow(Map<String, dynamic> row, {required List<Map<String, dynamic>> votes, String? userId}) {
    final id = row['id'] as String;
    var up = 0, down = 0, mine = 0;
    for (final v in votes) {
      if (v['item_id'] != id) continue;
      final value = (v['vote'] as num).toInt();
      if (value > 0) up++;
      if (value < 0) down++;
      if (v['user_id'] == userId) mine = value;
    }
    return TripItem(
      id: id,
      activityId: row['activity_id'] as String,
      createdBy: row['created_by'] as String,
      name: row['name'] as String,
      place: row['place'] as String?,
      address: row['address'] as String?,
      date: row['planned_on'] == null ? null : DateTime.parse(row['planned_on'] as String),
      time: _parseTime(row['planned_at'] as String?),
      latitude: (row['latitude'] as num?)?.toDouble(),
      longitude: (row['longitude'] as num?)?.toDouble(),
      done: row['done'] as bool? ?? false,
      upVotes: up,
      downVotes: down,
      myVote: mine,
    );
  }

  static TimeOfDay? _parseTime(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }
}

/// Champs saisis dans le formulaire d'un élément du programme.
class TripItemDraft {
  const TripItemDraft({
    required this.name,
    this.place,
    this.address,
    this.date,
    this.time,
    this.latitude,
    this.longitude,
  });

  final String name;
  final String? place;
  final String? address;
  final DateTime? date;
  final TimeOfDay? time;

  /// Position trouvée à partir du lieu et de l'adresse (null : pas de repère sur la carte).
  final double? latitude;
  final double? longitude;

  TripItemDraft withPosition((double, double)? position) => TripItemDraft(
    name: name,
    place: place,
    address: address,
    date: date,
    time: time,
    latitude: position?.$1,
    longitude: position?.$2,
  );

  Map<String, dynamic> toRow() => {
    'name': name.trim(),
    'place': clean(place),
    'address': clean(address),
    'planned_on': date == null
        ? null
        : '${date!.year.toString().padLeft(4, '0')}-${date!.month.toString().padLeft(2, '0')}-'
              '${date!.day.toString().padLeft(2, '0')}',
    'planned_at': time == null
        ? null
        : '${time!.hour.toString().padLeft(2, '0')}:${time!.minute.toString().padLeft(2, '0')}:00',
    'latitude': latitude,
    'longitude': longitude,
  };

  /// Texte sans espaces autour, null s'il est vide.
  static String? clean(String? v) => v == null || v.trim().isEmpty ? null : v.trim();
}
