/// « 1234.5 » + « EUR » → « 1 234,50 € ».
String formatMoney(double amount, String currency) {
  final negative = amount < 0;
  final parts = amount.abs().toStringAsFixed(2).split('.');
  final digits = parts[0];
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(' '); // espace fine insécable
    grouped.write(digits[i]);
  }
  return '${negative ? '−' : ''}$grouped,${parts[1]} ${currencySymbol(currency)}';
}

String currencySymbol(String code) => currencyByCode(code)?.symbol ?? code;

/// Devise proposée pour une activité.
class Currency {
  const Currency(this.code, this.name, this.symbol, this.flag);

  final String code;
  final String name;
  final String symbol;
  final String flag;
}

const currencies = [
  Currency('EUR', 'Euro', '€', '🇪🇺'),
  Currency('MAD', 'Dirham marocain', 'DH', '🇲🇦'),
  Currency('USD', 'Dollar américain', '\$', '🇺🇸'),
  Currency('GBP', 'Livre sterling', '£', '🇬🇧'),
  Currency('CHF', 'Franc suisse', 'CHF', '🇨🇭'),
  Currency('CAD', 'Dollar canadien', 'CA\$', '🇨🇦'),
  Currency('TRY', 'Livre turque', '₺', '🇹🇷'),
  Currency('AED', 'Dirham des Émirats', 'AED', '🇦🇪'),
  Currency('SAR', 'Riyal saoudien', 'SAR', '🇸🇦'),
  Currency('TND', 'Dinar tunisien', 'DT', '🇹🇳'),
  Currency('DZD', 'Dinar algérien', 'DA', '🇩🇿'),
  Currency('JPY', 'Yen japonais', '¥', '🇯🇵'),
];

Currency? currencyByCode(String code) => currencies.where((c) => c.code == code).firstOrNull;
