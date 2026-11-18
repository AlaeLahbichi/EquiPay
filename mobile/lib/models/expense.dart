/// Part d'un participant dans une dépense (en pourcentage).
class ExpenseShare {
  const ExpenseShare({required this.userId, required this.percentage});

  final String userId;
  final double percentage;
}

/// Une dépense de l'activité, avec sa répartition.
class Expense {
  const Expense({
    required this.id,
    required this.activityId,
    required this.createdBy,
    required this.paidBy,
    required this.name,
    required this.amount,
    required this.currency,
    required this.date,
    required this.shares,
    this.exchangeRate = 1,
    this.description,
    this.country,
    this.city,
    this.address,
    this.createdAt,
    this.pending = false,
  });

  final String id;

  /// Enregistrée sur le téléphone sans réseau : sera envoyée au retour de la connexion.
  final bool pending;
  final String activityId;
  final String createdBy;
  final String paidBy;
  final String name;
  final String? description;
  final double amount;
  final String currency;

  /// Taux vers la devise de l'activité (1 si même devise).
  final double exchangeRate;
  final DateTime date;
  final String? country;
  final String? city;
  final String? address;
  final DateTime? createdAt;
  final List<ExpenseShare> shares;

  /// Montant dans la devise de l'activité.
  double get convertedAmount => amount * exchangeRate;

  /// « Marrakech, Maroc », null si aucun lieu.
  String? get place {
    final parts = [address, city, country].whereType<String>().where((p) => p.trim().isNotEmpty);
    return parts.isEmpty ? null : parts.join(', ');
  }

  factory Expense.fromRow(Map<String, dynamic> row) {
    final shares = (row['expense_shares'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map((s) => ExpenseShare(userId: s['user_id'] as String, percentage: _num(s['percentage'])))
        .toList();
    return Expense(
      id: row['id'] as String,
      activityId: row['activity_id'] as String,
      createdBy: row['created_by'] as String,
      paidBy: row['paid_by'] as String,
      name: row['name'] as String,
      description: row['description'] as String?,
      amount: _num(row['amount']),
      currency: (row['currency'] as String).trim(),
      exchangeRate: _num(row['exchange_rate']),
      date: DateTime.parse(row['expense_date'] as String),
      country: row['country'] as String?,
      city: row['city'] as String?,
      address: row['address'] as String?,
      createdAt: row['created_at'] == null ? null : DateTime.parse(row['created_at'] as String),
      shares: shares,
    );
  }
}

/// Données saisies dans le formulaire, avant enregistrement.
class ExpenseDraft {
  const ExpenseDraft({
    required this.activityId,
    required this.name,
    required this.amount,
    required this.currency,
    required this.date,
    required this.paidBy,
    required this.shares,
    this.exchangeRate = 1,
    this.description = '',
    this.country = '',
    this.city = '',
    this.address = '',
  });

  final String activityId;
  final String name;
  final String description;
  final double amount;
  final String currency;
  final double exchangeRate;
  final DateTime date;
  final String paidBy;
  final String country;
  final String city;
  final String address;

  /// Pourcentage par participant (somme = 100).
  final Map<String, double> shares;

  Map<String, Object?> toJson() => {
    'activity_id': activityId,
    'name': name,
    'description': description,
    'amount': amount,
    'currency': currency,
    'exchange_rate': exchangeRate,
    'date': date.toIso8601String(),
    'paid_by': paidBy,
    'country': country,
    'city': city,
    'address': address,
    'shares': shares,
  };

  factory ExpenseDraft.fromJson(Map<String, dynamic> j) => ExpenseDraft(
    activityId: j['activity_id'] as String,
    name: j['name'] as String,
    description: j['description'] as String? ?? '',
    amount: _num(j['amount']),
    currency: j['currency'] as String,
    exchangeRate: _num(j['exchange_rate']),
    date: DateTime.parse(j['date'] as String),
    paidBy: j['paid_by'] as String,
    country: j['country'] as String? ?? '',
    city: j['city'] as String? ?? '',
    address: j['address'] as String? ?? '',
    shares: {for (final e in (j['shares'] as Map).entries) e.key as String: _num(e.value)},
  );
}

/// Photo d'une activité ou justificatif d'une dépense (fichier privé, lien temporaire).
class Photo {
  const Photo({
    required this.id,
    required this.activityId,
    required this.uploadedBy,
    required this.storagePath,
    required this.url,
    this.expenseId,
    this.createdAt,
  });

  final String id;
  final String activityId;
  final String? expenseId;
  final String uploadedBy;
  final String storagePath;

  /// Lien signé, valable environ une heure.
  final String url;
  final DateTime? createdAt;
}

/// Répartition égale en centièmes : 3 personnes → 33,33 / 33,33 / 33,34 (somme exacte = 100).
Map<String, double> equalShares(List<String> userIds) {
  if (userIds.isEmpty) return {};
  final base = 10000 ~/ userIds.length;
  final rest = 10000 - base * userIds.length;
  return {for (var i = 0; i < userIds.length; i++) userIds[i]: (base + (i >= userIds.length - rest ? 1 : 0)) / 100};
}

double _num(Object? v) => (v as num?)?.toDouble() ?? double.tryParse('$v') ?? 0;
