import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/env.dart';
import '../models/plan.dart';
import '../l10n/i18n.dart';

/// Article lu sur le ticket.
class ReceiptItem {
  const ReceiptItem({required this.label, required this.price, this.qty});

  final String label;
  final double? qty;
  final double price;
}

/// Ce que le modèle a lu sur le ticket. Tous les champs peuvent manquer.
class ReceiptScan {
  const ReceiptScan({
    this.merchant,
    this.address,
    this.date,
    this.amount,
    this.amountText,
    this.currency,
    this.items = const [],
    this.amountMatchesText = true,
    this.itemsMatchTotal = false,
    this.modelVersion,
  });

  final String? merchant;
  final String? address;
  final DateTime? date;
  final double? amount;

  /// Total tel qu'il est imprimé (« 11,50 € »).
  final String? amountText;
  final String? currency;
  final List<ReceiptItem> items;

  /// false : le montant converti ne correspond pas au texte imprimé (à vérifier).
  final bool amountMatchesText;
  final bool itemsMatchTotal;
  final String? modelVersion;

  bool get isEmpty => merchant == null && amount == null && date == null && items.isEmpty;

  factory ReceiptScan.fromJson(Map<String, dynamic> json) {
    double? num_(Object? v) => v is num ? v.toDouble() : null;
    final checks = (json['checks'] as Map<String, dynamic>?) ?? const {};
    return ReceiptScan(
      merchant: json['merchant'] as String?,
      address: json['address'] as String?,
      date: json['date'] is String ? DateTime.tryParse(json['date'] as String) : null,
      amount: num_(json['amount']),
      amountText: json['amount_text'] as String?,
      currency: json['currency'] as String?,
      items: [
        for (final it in (json['items'] as List? ?? const []).cast<Map<String, dynamic>>())
          ReceiptItem(label: it['label'] as String, qty: num_(it['qty']), price: num_(it['price']) ?? 0),
      ],
      amountMatchesText: checks['amount_matches_text'] as bool? ?? true,
      itemsMatchTotal: checks['items_match_total'] as bool? ?? false,
      modelVersion: json['model_version'] as String?,
    );
  }
}

class ReceiptScanException implements Exception {
  const ReceiptScanException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Lecture d'un ticket par le modèle equipay-receipt (servi par l'API Python).
abstract class ReceiptScanner {
  Future<ReceiptScan> scan(Uint8List jpeg);
}

class HttpReceiptScanner implements ReceiptScanner {
  HttpReceiptScanner({required this.token, http.Client? client}) : _http = client ?? http.Client();

  final String? Function() token;
  final http.Client _http;

  @override
  Future<ReceiptScan> scan(Uint8List jpeg) async {
    if (Env.apiUrl.isEmpty) {
      throw ReceiptScanException(tr('Scanner non configuré (API_URL manquant dans env.json).'));
    }
    final jwt = token();
    if (jwt == null) throw ReceiptScanException(tr('Connecte-toi pour scanner un reçu.'));
    final request = http.MultipartRequest('POST', Uri.parse('${Env.apiUrl}/receipts/scan'))
      ..headers['Authorization'] = 'Bearer $jwt'
      ..files.add(http.MultipartFile.fromBytes('file', jpeg, filename: 'recu.jpg'));
    final http.Response res;
    try {
      // La première lecture peut prendre ~30 s (préparation du modèle)
      res = await http.Response.fromStream(await _http.send(request).timeout(const Duration(seconds: 120)));
    } on TimeoutException {
      throw ReceiptScanException(tr('La lecture du ticket prend trop de temps. Réessaie.'));
    } catch (_) {
      throw ReceiptScanException(tr('Impossible de joindre le scanner. Vérifie ta connexion.'));
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw ReceiptScanException(tr('Réponse inattendue du scanner.'));
    }
    if (res.statusCode == 200 && body is Map<String, dynamic>) {
      if (body['ok'] != true) {
        throw ReceiptScanException(tr('Le ticket n\'a pas pu être lu. Essaie avec une photo plus nette.'));
      }
      return ReceiptScan.fromJson(body);
    }
    final limited = PlanLimitException.fromBody(res.statusCode, body);
    if (limited != null) throw limited;
    if (res.statusCode == 401) throw ReceiptScanException(tr('Ta session a expiré. Reconnecte-toi puis réessaie.'));
    final detail = body is Map<String, dynamic> ? body['detail'] : null;
    throw ReceiptScanException(detail is String ? detail : tr('Le scanner est indisponible.'));
  }
}
