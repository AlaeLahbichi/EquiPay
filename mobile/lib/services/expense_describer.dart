import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/env.dart';
import '../models/plan.dart';
import 'receipt_scanner.dart';
import '../l10n/i18n.dart';

/// Ce que le modèle a compris d'une phrase (« resto avec Sara 60/40, j'ai payé 50 € hier »).
/// Les membres sont désignés par leur identifiant ; tous les champs peuvent manquer.
class DescribedExpense {
  const DescribedExpense({
    required this.sentence,
    this.title,
    this.merchant,
    this.amount,
    this.currency,
    this.date,
    this.paidBy,
    this.participants,
    this.splitType,
    this.shares,
    this.items = const [],
    this.warnings = const [],
    this.modelVersion,
  });

  /// La phrase écrite par l'utilisateur.
  final String sentence;
  final String? title;
  final String? merchant;
  final double? amount;
  final String? currency;
  final DateTime? date;
  final String? paidBy;

  /// null : non précisé (tout le monde par défaut).
  final List<String>? participants;

  /// equal, percent, amounts ou shares (null : non précisée, parts égales).
  final String? splitType;

  /// Pourcentage par membre (somme 100), quand la répartition n'est pas égale.
  final Map<String, double>? shares;
  final List<ReceiptItem> items;
  final List<String> warnings;
  final String? modelVersion;

  /// Titre du formulaire : « Restaurant · Nomad », ou l'un des deux.
  String? get name => switch ((title, merchant)) {
    (final t?, final m?) when t.toLowerCase() != m.toLowerCase() => '$t · $m',
    (final t?, _) => t,
    (_, final m?) => m,
    _ => null,
  };

  factory DescribedExpense.fromJson(String sentence, Map<String, dynamic> json) {
    double? num_(Object? v) => v is num ? v.toDouble() : null;
    return DescribedExpense(
      sentence: sentence,
      title: json['title'] as String?,
      merchant: json['merchant'] as String?,
      amount: num_(json['amount']),
      currency: json['currency'] as String?,
      date: json['date'] is String ? DateTime.tryParse(json['date'] as String) : null,
      paidBy: json['paid_by'] as String?,
      participants: (json['participants'] as List?)?.cast<String>(),
      splitType: json['split_type'] as String?,
      shares: (json['shares'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, (v as num).toDouble())),
      items: [
        for (final it in (json['items'] as List? ?? const []).cast<Map<String, dynamic>>())
          ReceiptItem(label: it['label'] as String, qty: num_(it['qty']), price: num_(it['price']) ?? 0),
      ],
      warnings: (json['warnings'] as List? ?? const []).cast<String>(),
      modelVersion: json['model_version'] as String?,
    );
  }
}

class DescribeException implements Exception {
  const DescribeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Phrase → dépense, par le modèle equipay-describe (servi par l'API Python).
abstract class ExpenseDescriber {
  /// [members] : identifiant → nom affiché, pour les membres de l'activité (utilisateur compris).
  Future<DescribedExpense> describe({
    required String sentence,
    required Map<String, String> members,
    required String currency,
    DateTime? today,
  });

  /// Service de l'app (remplacé dans les tests).
  static ExpenseDescriber instance = HttpExpenseDescriber(token: () => null);
}

class HttpExpenseDescriber implements ExpenseDescriber {
  HttpExpenseDescriber({required this.token, http.Client? client}) : _http = client ?? http.Client();

  final String? Function() token;
  final http.Client _http;

  @override
  Future<DescribedExpense> describe({
    required String sentence,
    required Map<String, String> members,
    required String currency,
    DateTime? today,
  }) async {
    if (Env.apiUrl.isEmpty) {
      throw DescribeException(tr('Assistant non configuré (API_URL manquant dans env.json).'));
    }
    final jwt = token();
    if (jwt == null) throw DescribeException(tr('Connecte-toi pour décrire une dépense.'));
    final day = today ?? DateTime.now();
    final http.Response res;
    try {
      // La première phrase peut prendre ~15 s (chargement du modèle)
      res = await _http
          .post(
            Uri.parse('${Env.apiUrl}/expenses/describe'),
            headers: {'Authorization': 'Bearer $jwt', 'Content-Type': 'application/json'},
            body: jsonEncode({
              'sentence': sentence,
              'members': [
                for (final e in members.entries) {'id': e.key, 'name': e.value},
              ],
              'currency': currency,
              'today':
                  '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-'
                  '${day.day.toString().padLeft(2, '0')}',
            }),
          )
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw DescribeException(tr('L\'assistant met trop de temps à répondre. Réessaie.'));
    } catch (_) {
      throw DescribeException(tr('Impossible de joindre l\'assistant. Vérifie ta connexion.'));
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw DescribeException(tr('Réponse inattendue de l\'assistant.'));
    }
    if (res.statusCode == 200 && body is Map<String, dynamic>) {
      if (body['unreadable'] == true) {
        throw DescribeException(tr('Je n\'ai pas compris cette phrase. Reformule-la ou ajoute des détails.'));
      }
      if (body['is_expense'] != true) {
        throw DescribeException(
          tr('Ça ne ressemble pas à une dépense. Indique au moins ce qui a été payé, par exemple « taxi 20 € ».'),
        );
      }
      return DescribedExpense.fromJson(sentence, body);
    }
    final limited = PlanLimitException.fromBody(res.statusCode, body);
    if (limited != null) throw limited;
    if (res.statusCode == 401) throw DescribeException(tr('Ta session a expiré. Reconnecte-toi puis réessaie.'));
    final detail = body is Map<String, dynamic> ? body['detail'] : null;
    throw DescribeException(detail is String ? detail : tr('L\'assistant est indisponible.'));
  }
}
