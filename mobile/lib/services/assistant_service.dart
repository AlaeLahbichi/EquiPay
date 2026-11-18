import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/env.dart';
import '../l10n/i18n.dart';

/// Assistant EquiPay (modèle servi par l'API Python). Utilisable sans être connecté.
abstract class AssistantService {
  Future<String> ask(String message);
}

class AssistantException implements Exception {
  const AssistantException(this.message);

  final String message;

  @override
  String toString() => message;
}

class HttpAssistantService implements AssistantService {
  HttpAssistantService({required this.token, http.Client? client}) : _http = client ?? http.Client();

  /// Jeton de l'utilisateur connecté : l'échange est alors gardé dans son historique.
  final String? Function() token;
  final http.Client _http;

  @override
  Future<String> ask(String message) async {
    if (Env.apiUrl.isEmpty) {
      throw AssistantException(tr('Assistant non configuré (API_URL manquant dans env.json).'));
    }
    final jwt = token();
    final http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse('${Env.apiUrl}/chat'),
            headers: {'Content-Type': 'application/json', if (jwt != null) 'Authorization': 'Bearer $jwt'},
            body: jsonEncode({'message': message}),
          )
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw AssistantException(tr('L\'assistant met trop de temps à répondre. Réessaie.'));
    } catch (_) {
      throw AssistantException(tr('Impossible de joindre l\'assistant. Vérifie ta connexion.'));
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) return (body['answer'] as String).trim();
    if (res.statusCode == 401) {
      throw AssistantException(tr('Ta session a expiré. Reconnecte-toi puis réessaie.'));
    }
    throw AssistantException(body['detail'] is String ? body['detail'] as String : tr('L\'assistant est indisponible.'));
  }
}
