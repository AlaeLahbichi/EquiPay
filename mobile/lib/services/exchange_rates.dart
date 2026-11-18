import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import '../l10n/i18n.dart';

/// Taux de change trouvé automatiquement.
class ExchangeRate {
  const ExchangeRate({required this.rate, required this.date});

  /// 1 unité de la devise de départ = [rate] unités de la devise d'arrivée.
  final double rate;

  /// Jour du taux (peut différer du jour demandé : week-end, date trop ancienne ou future).
  final DateTime date;
}

class ExchangeRateException implements Exception {
  const ExchangeRateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Taux de change entre deux devises, à une date donnée.
abstract class ExchangeRates {
  Future<ExchangeRate> rate({required String from, required String to, required DateTime date});

  /// Service partagé par l'app (taux gardés en mémoire pendant la session).
  static final ExchangeRates instance = HttpExchangeRates();
}

/// Taux quotidiens publics et gratuits (currency-api, sans clé), avec un serveur de secours.
/// Historique disponible depuis mars 2024 ; au-delà, on prend le dernier taux connu.
class HttpExchangeRates implements ExchangeRates {
  HttpExchangeRates({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;
  final _cache = <String, Future<Map<String, dynamic>>>{};

  static final _firstDay = DateTime(2024, 3, 2);

  @override
  Future<ExchangeRate> rate({required String from, required String to, required DateTime date}) async {
    from = from.toLowerCase();
    to = to.toLowerCase();
    if (from == to) return ExchangeRate(rate: 1, date: date);
    final today = DateTime.now();
    final day = DateTime(date.year, date.month, date.day);
    // Date future ou antérieure à l'historique : dernier taux connu
    final tag = day.isAfter(today) || day.isBefore(_firstDay) ? 'latest' : _iso(day);
    final table = await _table(tag, from);
    final value = (table[from] as Map<String, dynamic>?)?[to];
    if (value is! num || value <= 0) {
      throw ExchangeRateException(tr('Taux {0} → {1} introuvable.', [from.toUpperCase(), to.toUpperCase()]));
    }
    return ExchangeRate(rate: value.toDouble(), date: DateTime.tryParse('${table['date']}') ?? day);
  }

  Future<Map<String, dynamic>> _table(String tag, String base) {
    final key = '$tag/$base';
    return _cache.putIfAbsent(key, () async {
      try {
        return await _fetch(tag, base);
      } catch (e) {
        _cache.remove(key); // pas de cache pour un échec : on réessaiera
        rethrow;
      }
    });
  }

  Future<Map<String, dynamic>> _fetch(String tag, String base) async {
    final urls = [
      'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@$tag/v1/currencies/$base.json',
      'https://$tag.currency-api.pages.dev/v1/currencies/$base.json',
      if (tag != 'latest') 'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/$base.json',
    ];
    for (final url in urls) {
      try {
        final res = await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      } catch (_) {
        // serveur suivant
      }
    }
    throw ExchangeRateException(tr('Taux de change indisponible (hors ligne ?). Saisis-le à la main.'));
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
