import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/activity.dart';
import '../../models/activity_overview.dart';
import '../../models/expense.dart';
import '../../services/activity_repository.dart';
import '../../services/exchange_rates.dart';
import '../../services/expense_describer.dart';
import '../../services/expense_repository.dart';
import '../../services/pending_expenses.dart';
import '../../services/receipt_scanner.dart';
import '../../theme/app_colors.dart';
import '../../utils/dates.dart';
import '../../utils/money.dart';
import '../../utils/pick_photo.dart';
import '../../widgets/currency_field.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/user_avatar.dart';
import '../../l10n/i18n.dart';

/// Saisie d'une dépense (création, ou modification par son créateur).
/// Avec [prefill] (ticket scanné) ou [described] (phrase comprise par l'assistant), les champs sont
/// pré-remplis : l'utilisateur vérifie, corrige ou complète avant de valider. Renvoie le message à afficher une fois enregistrée.
class ExpenseFormPage extends StatefulWidget {
  const ExpenseFormPage({
    super.key,
    required this.activity,
    required this.members,
    required this.currentUserId,
    required this.repository,
    this.expense,
    this.photo,
    this.prefill,
    this.described,
    this.initialPhoto,
    this.rates,
  });

  final Activity activity;
  final List<MemberSummary> members;
  final String currentUserId;
  final ExpenseRepository repository;

  /// Dépense à modifier (null : nouvelle dépense).
  final Expense? expense;
  final Photo? photo;

  /// Lecture d'un ticket par le scanner (nouvelle dépense uniquement).
  final ReceiptScan? prefill;

  /// Dépense décrite en une phrase (nouvelle dépense uniquement).
  final DescribedExpense? described;

  /// Photo à joindre d'office (le ticket scanné).
  final Uint8List? initialPhoto;

  /// Taux de change automatiques (null : service partagé de l'app).
  final ExchangeRates? rates;

  @override
  State<ExpenseFormPage> createState() => _ExpenseFormPageState();
}

class _ExpenseFormPageState extends State<ExpenseFormPage> {
  late final Expense? _initial = widget.expense;
  late final ReceiptScan? _scan = widget.expense == null ? widget.prefill : null;
  late final DescribedExpense? _described = widget.expense == null ? widget.described : null;

  /// Pré-rempli par le scan ou par la phrase.
  bool get _prefilled => _scan != null || _described != null;

  /// Devise trouvée (ticket ou phrase) mais absente de la liste de l'app.
  late final String? _foundCurrency = _scan?.currency ?? _described?.currency;
  late final String? _unknownCurrency = _foundCurrency != null && currencyByCode(_foundCurrency) == null
      ? _foundCurrency
      : null;
  late final double? _foundAmount = _scan?.amount ?? _described?.amount;

  late final _name = TextEditingController(text: _initial?.name ?? _scan?.merchant ?? _described?.name);
  late final _amount = TextEditingController(
    text: _initial != null ? _plain(_initial.amount) : (_foundAmount != null ? _plain(_foundAmount) : ''),
  );
  late final _rate = TextEditingController(
    text: _initial == null || _initial.exchangeRate == 1 ? '' : _plain(_initial.exchangeRate, decimals: 6),
  );
  late final _description = TextEditingController(
    text: _initial?.description ?? _itemsSummary(_scan?.items ?? _described?.items ?? const []),
  );
  late final _country = TextEditingController(text: _initial?.country);
  late final _city = TextEditingController(text: _initial?.city);
  late final _address = TextEditingController(text: _initial?.address ?? _scan?.address);

  late String _currency =
      _initial?.currency ??
      (_foundCurrency != null && _unknownCurrency == null ? _foundCurrency : widget.activity.currency);
  late DateTime _date = _initial?.date ?? _scan?.date ?? _described?.date ?? DateTime.now();
  late String? _paidBy;
  final _included = <String>{};
  final _percent = <String, TextEditingController>{};

  late Uint8List? _newPhoto = widget.initialPhoto;

  // Taux de change : rempli automatiquement selon la devise et la date, modifiable à la main
  /// true : taux saisi ou corrigé par l'utilisateur (on ne l'écrase plus).
  late bool _rateManual = _initial != null && _initial.currency != widget.activity.currency;
  ExchangeRate? _autoRate;
  var _rateLoading = false;
  String? _rateNotice;
  var _rateRequest = 0;
  var _removePhoto = false;
  var _saving = false;
  String? _nameError, _amountError, _rateError, _sharesError, _saveError;

  /// Owner et membres : les spectateurs ne participent pas aux dépenses.
  late final List<MemberSummary> _eligible = widget.members.where((m) => m.role != MemberRole.viewer).toList();

  bool get _foreign => _currency != widget.activity.currency;
  bool get _editing => _initial != null;

  @override
  void initState() {
    super.initState();
    final ids = _eligible.map((m) => m.profile.id).toList();
    for (final id in ids) {
      _percent[id] = TextEditingController()..addListener(_refresh);
    }
    _amount.addListener(_refresh);
    _rate.addListener(_refresh);
    final initial = _initial;
    if (initial == null) {
      final described = _described;
      _paidBy = described?.paidBy != null && ids.contains(described!.paidBy)
          ? described.paidBy
          : ids.contains(widget.currentUserId)
          ? widget.currentUserId
          : ids.firstOrNull;
      // Par défaut : tout le monde, parts égales ; sinon les participants compris dans la phrase
      final named = described?.participants?.where(ids.contains).toList() ?? const <String>[];
      _included.addAll(named.isEmpty ? ids : named);
      _applyEqualShares();
      final shares = described?.shares;
      if (shares != null && shares.keys.every(_included.contains)) {
        for (final e in shares.entries) {
          _percent[e.key]!.text = _plain(e.value);
        }
      }
      if (_foreign) _fetchRate(); // devise étrangère lue sur un ticket ou dans la phrase
    } else {
      _paidBy = initial.paidBy;
      for (final s in initial.shares) {
        if (_percent[s.userId] case final c?) {
          _included.add(s.userId);
          c.text = _plain(s.percentage);
        }
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _amount, _rate, _description, _country, _city, _address, ..._percent.values]) {
      c.dispose();
    }
    super.dispose();
  }

  void _refresh() => setState(() {});

  /// Parts égales entre les participants cochés (somme exacte de 100 %).
  void _applyEqualShares() {
    final shares = equalShares(_eligible.map((m) => m.profile.id).where(_included.contains).toList());
    for (final entry in _percent.entries) {
      entry.value.text = shares.containsKey(entry.key) ? _plain(shares[entry.key]!) : '';
    }
    _sharesError = null;
  }

  void _toggle(String userId, bool on) {
    setState(() {
      on ? _included.add(userId) : _included.remove(userId);
      _applyEqualShares();
    });
  }

  double? get _amountValue => _parse(_amount.text);
  double? get _rateValue => _foreign ? _parse(_rate.text) : 1;

  /// Total des pourcentages en centièmes (10 000 = 100 %).
  int get _totalCents => _included.fold(0, (sum, id) => sum + ((_parse(_percent[id]!.text) ?? 0) * 100).round());

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: tr('Date de la dépense'),
    );
    if (picked != null) {
      setState(() => _date = picked);
      if (_foreign && !_rateManual) _fetchRate(); // taux du nouveau jour
    }
  }

  void _setCurrency(String code) {
    setState(() {
      _currency = code;
      _rateManual = false;
      _autoRate = null;
      _rateNotice = null;
      _rateError = null;
      _rate.text = '';
    });
    if (_foreign) _fetchRate();
  }

  /// Cherche le taux « devise de la dépense → devise de l'activité » au jour de la dépense.
  Future<void> _fetchRate() async {
    final request = ++_rateRequest;
    final from = _currency, to = widget.activity.currency, date = _date;
    setState(() {
      _rateLoading = true;
      _rateNotice = null;
    });
    try {
      final rate = await (widget.rates ?? ExchangeRates.instance).rate(from: from, to: to, date: date);
      if (!mounted || request != _rateRequest) return;
      setState(() {
        _rateLoading = false;
        _rateManual = false;
        _autoRate = rate;
        _rateError = null;
        _rate.text = _plain(double.parse(rate.rate.toStringAsFixed(6)), decimals: 6);
      });
    } catch (e) {
      if (!mounted || request != _rateRequest) return;
      setState(() {
        _rateLoading = false;
        _autoRate = null;
        _rateNotice = e is ExchangeRateException ? e.message : tr('Taux de change indisponible. Saisis-le à la main.');
      });
    }
  }

  String? get _rateHelper {
    final amount = _amountValue, rate = _rateValue;
    final converted = amount != null && rate != null
        ? tr('soit {0} dans les totaux', [formatMoney(amount * rate, widget.activity.currency)])
        : null;
    if (_rateLoading) return tr('Recherche du taux du jour…');
    if (_rateNotice != null) return _rateNotice;
    final origin = _rateManual
        ? tr('Taux saisi à la main')
        : _autoRate != null
        ? tr('Taux automatique du {0}', [formatDate(_autoRate!.date)])
        : null;
    return [?origin, ?converted].join(' · ').ifEmpty(tr('Pour convertir la dépense dans la devise de l\'activité'));
  }

  Future<void> _pickPhoto() async {
    final bytes = await pickPhoto(context, title: tr('Photo du reçu'));
    if (bytes != null && mounted) {
      setState(() {
        _newPhoto = bytes;
        _removePhoto = false;
      });
    }
  }

  void _viewPhoto() {
    final image = _newPhoto != null ? MemoryImage(_newPhoto!) : NetworkImage(widget.photo!.url) as ImageProvider;
    openPhotoViewer(
      context,
      photos: [ViewerPhoto(image: image, heroTag: 'form-photo', caption: tr('Justificatif'))],
    );
  }

  bool _validate() {
    final amount = _amountValue;
    final rate = _rateValue;
    setState(() {
      _nameError = _name.text.trim().isEmpty ? tr('Donne un nom à la dépense') : null;
      _amountError = amount == null || amount <= 0
          ? tr('Indique un montant positif')
          : _decimals(_amount.text) > 2
          ? tr('2 chiffres après la virgule maximum')
          : amount >= 1e10
          ? tr('Montant trop élevé')
          : null;
      _rateError = rate == null || rate <= 0
          ? (_rateLoading ? tr('Patiente, le taux est en cours de recherche') : tr('Indique le taux de change'))
          : _decimals(_rate.text) > 6
          ? tr('6 chiffres après la virgule maximum')
          : null;
      _sharesError = _included.isEmpty
          ? tr('Choisis au moins un participant')
          : _included.any((id) => (_parse(_percent[id]!.text) ?? 0) <= 0)
          ? tr('Chaque participant doit avoir un pourcentage supérieur à 0')
          : _totalCents != 10000
          ? tr('La somme des pourcentages doit faire 100 %')
          : null;
      _saveError = _paidBy == null ? tr('Choisis qui a payé') : null;
    });
    return [_nameError, _amountError, _rateError, _sharesError, _saveError].every((e) => e == null);
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_validate()) return;
    setState(() => _saving = true);
    final draft = ExpenseDraft(
      activityId: widget.activity.id,
      name: _name.text.trim(),
      description: _description.text.trim(),
      amount: _amountValue!,
      currency: _currency,
      exchangeRate: _rateValue!,
      date: _date,
      paidBy: _paidBy!,
      country: _country.text.trim(),
      city: _city.text.trim(),
      address: _address.text.trim(),
      shares: {for (final id in _included) id: _parse(_percent[id]!.text)!},
    );
    String id;
    try {
      id = await widget.repository.save(draft, expenseId: _initial?.id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = friendlyError(e);
        });
      }
      return;
    }
    // Pas de réseau : la dépense attend sur le téléphone (sans sa photo, qui demande une connexion)
    final pending = PendingExpenses.instance.byId(id) != null;
    if (pending) {
      final message = _newPhoto != null
          ? tr('Hors ligne : dépense gardée sur le téléphone, envoyée au retour du réseau (ajoute la photo ensuite)')
          : tr('Hors ligne : dépense gardée sur le téléphone, elle sera envoyée au retour du réseau');
      if (mounted) Navigator.pop(context, message);
      return;
    }
    var message = _editing ? tr('Dépense modifiée') : tr('Dépense ajoutée');
    try {
      if (_newPhoto != null) {
        await widget.repository.setExpensePhoto(widget.activity.id, id, _newPhoto!);
      } else if (_removePhoto && widget.photo != null) {
        await widget.repository.deletePhoto(widget.photo!);
      }
    } catch (_) {
      message = tr('{0}, mais la photo n\'a pas pu être enregistrée', [message]);
    }
    if (mounted) Navigator.pop(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final amount = _amountValue;
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? tr('Modifier la dépense') : tr('Nouvelle dépense'))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (_scan case final scan?) ...[
            _ScanBanner(scan: scan, unknownCurrency: _unknownCurrency),
            SizedBox(height: 16),
          ],
          if (_described case final described?) ...[
            _DescribeBanner(described: described, unknownCurrency: _unknownCurrency),
            SizedBox(height: 16),
          ],
          TextField(
            controller: _name,
            autofocus: !_editing && !_prefilled,
            enabled: !_saving,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: tr('Titre'),
              hintText: tr('Ex. Dîner au riad'),
              errorText: _nameError,
              helperText: _scanHint(
                _scan?.merchant != null || _described?.name != null,
                found: tr('Enseigne lue sur le ticket'),
                missing: tr('Non trouvé sur le ticket : à compléter'),
              ),
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.receipt_long_outlined),
            ),
          ),
          SizedBox(height: 14),
          TextField(
            controller: _amount,
            enabled: !_saving,
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              labelText: tr('Montant'),
              hintText: '0,00',
              errorText: _amountError,
              helperText: _scanHint(
                _foundAmount != null,
                found: _scan?.amountText != null ? tr('Lu sur le ticket : « {0} »', [_scan!.amountText]) : tr('Lu sur le ticket'),
                found2: _described?.warnings.where((w) => w.startsWith('Montant calculé')).firstOrNull,
              ),
              suffixText: currencySymbol(_currency),
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.payments_outlined),
            ),
          ),
          SizedBox(height: 14),
          CurrencyField(
            value: _currency,
            helperText: _unknownCurrency != null
                ? tr('Devise lue : {0} (non proposée) — choisis la bonne', [_unknownCurrency])
                : _scan?.currency != null
                ? tr('Lue sur le ticket')
                : _described?.currency != null
                ? tr('Comprise dans ta phrase')
                : _described != null
                ? tr('Pas de devise dans ta phrase : devise de l\'activité')
                : _foreign
                ? null
                : tr('Devise de l\'activité'),
            onChanged: _saving ? null : _setCurrency,
          ),
          if (_foreign) ...[
            SizedBox(height: 14),
            TextField(
              controller: _rate,
              enabled: !_saving,
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              // Une correction à la main n'est plus écrasée par le taux automatique
              onChanged: (_) => setState(() => _rateManual = true),
              decoration: InputDecoration(
                labelText: tr('Taux de change'),
                prefixText: '1 $_currency = ',
                suffixText: widget.activity.currency,
                errorText: _rateError,
                helperText: _rateHelper,
                helperMaxLines: 2,
                border: OutlineInputBorder(),
                suffixIcon: _rateLoading
                    ? Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(
                        tooltip: tr('Taux automatique'),
                        icon: Icon(Icons.currency_exchange_rounded),
                        onPressed: _saving ? null : _fetchRate,
                      ),
              ),
            ),
          ],
          SizedBox(height: 14),
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: _saving ? null : _pickDate,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: tr('Date'),
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.event_outlined),
                suffixIcon: Icon(Icons.expand_more_rounded),
                helperText: _scanHint(
                  _scan?.date != null || _described?.date != null,
                  found: tr('Lue sur le ticket'),
                  missing: tr('Date non trouvée sur le ticket : aujourd\'hui par défaut'),
                  describedMissing: tr('Pas de date dans ta phrase : aujourd\'hui par défaut'),
                ),
              ),
              child: Text(formatDate(_date)),
            ),
          ),
          SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _paidBy,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: tr('Payé par'),
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.account_balance_wallet_outlined),
              helperText: _described == null
                  ? null
                  : _described.paidBy != null
                  ? tr('Compris dans ta phrase')
                  : tr('Pas de payeur dans ta phrase : toi par défaut'),
            ),
            items: [
              for (final m in _eligible)
                DropdownMenuItem(
                  value: m.profile.id,
                  child: Row(
                    children: [
                      UserAvatar(user: m.profile, size: 26),
                      SizedBox(width: 10),
                      Flexible(child: Text(_label(m), overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
            ],
            onChanged: _saving ? null : (id) => setState(() => _paidBy = id),
          ),
          SizedBox(height: 24),
          _SectionTitle(
            title: tr('Répartition'),
            trailing: TextButton.icon(
              onPressed: _saving || _included.isEmpty ? null : () => setState(_applyEqualShares),
              icon: Icon(Icons.balance_rounded, size: 18),
              label: Text(tr('Parts égales')),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: Column(
              children: [
                for (final m in _eligible)
                  _ShareRow(
                    member: m,
                    label: _label(m),
                    included: _included.contains(m.profile.id),
                    controller: _percent[m.profile.id]!,
                    share: amount == null ? null : amount * (_parse(_percent[m.profile.id]!.text) ?? 0) / 100,
                    currency: _currency,
                    enabled: !_saving,
                    onToggle: (on) => _toggle(m.profile.id, on),
                  ),
              ],
            ),
          ),
          if (_described case final d?)
            Padding(
              padding: EdgeInsets.only(top: 6, left: 4),
              child: Text(
                [
                  d.participants == null
                      ? tr('Participants non précisés : tout le monde')
                      : tr('Participants compris dans ta phrase'),
                  switch (d.splitType) {
                    'percent' => tr('répartition en pourcentages'),
                    'shares' => tr('répartition en parts'),
                    'amounts' => tr('montants par personne convertis en %'),
                    _ => tr('parts égales'),
                  },
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          SizedBox(height: 8),
          _TotalLine(totalCents: _totalCents, error: _sharesError),
          SizedBox(height: 24),
          _SectionTitle(title: tr('Photo du reçu (1 maximum)')),
          _PhotoPicker(
            bytes: _newPhoto,
            url: _removePhoto ? null : widget.photo?.url,
            enabled: !_saving,
            onPick: _pickPhoto,
            onView: _viewPhoto,
            onRemove: () => setState(() {
              _newPhoto = null;
              _removePhoto = true;
            }),
          ),
          SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: ExpansionTile(
              initiallyExpanded: [_description, _country, _city, _address].any((c) => c.text.isNotEmpty),
              leading: Icon(Icons.notes_rounded),
              title: Text(tr('Plus de détails')),
              subtitle: Text(tr('Description et lieu (optionnels)')),
              childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                TextField(
                  controller: _description,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: tr('Description'), border: OutlineInputBorder()),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: _country,
                  enabled: !_saving,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: tr('Pays'), border: OutlineInputBorder()),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: _city,
                  enabled: !_saving,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: tr('Ville'), border: OutlineInputBorder()),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: _address,
                  enabled: !_saving,
                  decoration: InputDecoration(labelText: tr('Adresse'), border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
          if (_saveError != null) ...[
            SizedBox(height: 16),
            Text(
              _saveError!,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.error),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: Size.fromHeight(52)),
            child: _saving
                ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text(
                    _editing ? tr('Enregistrer') : tr('Ajouter la dépense'),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
      ),
    );
  }

  /// Indication sous un champ pré-rempli (rien en saisie manuelle).
  /// [found2] : précision pour une phrase (ex. « Montant calculé à partir des articles »).
  String? _scanHint(
    bool detected, {
    required String found,
    String? missing,
    String? found2,
    String? describedMissing,
  }) {
    if (_described != null) {
      return detected ? (found2 ?? tr('Compris dans ta phrase')) : describedMissing ?? tr('Pas dans ta phrase : à compléter');
    }
    if (_scan == null) return null;
    return detected ? found : missing ?? tr('Non trouvé sur le ticket : à compléter');
  }

  String _label(MemberSummary m) =>
      m.profile.id == widget.currentUserId ? '${m.profile.displayName} (toi)' : m.profile.displayName;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _ShareRow extends StatelessWidget {
  const _ShareRow({
    required this.member,
    required this.label,
    required this.included,
    required this.controller,
    required this.share,
    required this.currency,
    required this.enabled,
    required this.onToggle,
  });

  final MemberSummary member;
  final String label;
  final bool included;
  final TextEditingController controller;
  final double? share;
  final String currency;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
      child: Row(
        children: [
          Checkbox(value: included, onChanged: enabled ? (v) => onToggle(v ?? false) : null),
          UserAvatar(user: member.profile, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  included && share != null ? formatMoney(share!, currency) : tr('Ne participe pas'),
                  style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 92,
            child: TextField(
              controller: controller,
              enabled: enabled && included,
              textAlign: TextAlign.end,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                isDense: true,
                suffixText: '%',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalLine extends StatelessWidget {
  const _TotalLine({required this.totalCents, required this.error});

  final int totalCents;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final ok = totalCents == 10000;
    final color = ok ? AppColors.positive : AppColors.negative;
    final missing = (10000 - totalCents) / 100;
    final text = ok
        ? tr('Total : 100 %')
        : missing > 0
        ? tr('Total : {0} % (il manque {1} %)', [_plain(totalCents / 100), _plain(missing)])
        : tr('Total : {0} % ({1} % de trop)', [_plain(totalCents / 100), _plain(-missing)]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded, size: 18, color: color),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          ),
      ],
    );
  }
}

class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({
    required this.bytes,
    required this.url,
    required this.enabled,
    required this.onPick,
    required this.onView,
    required this.onRemove,
  });

  final Uint8List? bytes;
  final String? url;
  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onView;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = bytes != null ? MemoryImage(bytes!) : (url != null ? NetworkImage(url!) : null);
    if (image == null) {
      return OutlinedButton.icon(
        onPressed: enabled ? onPick : null,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        icon: const Icon(Icons.add_a_photo_outlined),
        label: Text(tr('Ajouter une photo du reçu')),
      );
    }
    return Row(
      children: [
        GestureDetector(
          onTap: onView,
          child: Hero(
            tag: 'form-photo',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image(image: image, width: 84, height: 84, fit: BoxFit.cover),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                onPressed: enabled ? onPick : null,
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: Text(tr('Remplacer')),
              ),
              TextButton.icon(
                onPressed: enabled ? onRemove : null,
                style: TextButton.styleFrom(foregroundColor: AppColors.negative),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(tr('Retirer')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Bandeau en tête du formulaire pré-rempli : rappelle de vérifier, et signale les points douteux.
/// Bandeau en tête du formulaire rempli à partir d'une phrase : la phrase et ce qui reste à vérifier.
class _DescribeBanner extends StatelessWidget {
  const _DescribeBanner({required this.described, required this.unknownCurrency});

  final DescribedExpense described;
  final String? unknownCurrency;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final warnings = [
      for (final w in described.warnings)
        if (w == 'Montant non indiqué') tr('Montant absent de ta phrase : saisis-le.') else if (!w.startsWith('Montant')) w,
      if (unknownCurrency != null) tr('Devise {0} non proposée dans l\'app.', [unknownCurrency]),
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.tertiary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.tertiary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, color: colors.tertiary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('Rempli à partir de ta phrase'),
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('« ${described.sentence} »', style: const TextStyle(fontStyle: FontStyle.italic)),
          const SizedBox(height: 6),
          Text(
            tr('Vérifie chaque champ, corrige si besoin et complète ce qui manque avant de valider.'),
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          for (final w in warnings)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warning),
                  const SizedBox(width: 6),
                  Expanded(child: Text(w)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ScanBanner extends StatelessWidget {
  const _ScanBanner({required this.scan, required this.unknownCurrency});

  final ReceiptScan scan;
  final String? unknownCurrency;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final warnings = [
      if (!scan.amountMatchesText) tr('Le montant ne correspond pas exactement au total imprimé : vérifie-le.'),
      if (scan.amount == null) tr('Total non trouvé : saisis-le.'),
      if (unknownCurrency != null) tr('Devise {0} non proposée dans l\'app.', [unknownCurrency]),
      if (scan.date == null) tr('Date non trouvée sur le ticket.'),
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, color: colors.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(tr('Rempli à partir du ticket'), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            tr('Vérifie chaque champ, corrige si besoin et complète ce qui manque avant de valider.'),
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          for (final w in warnings)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warning),
                  const SizedBox(width: 6),
                  Expanded(child: Text(w)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Articles du ticket en description : « 2 × Café crème — 7,00 ».
String? _itemsSummary(List<ReceiptItem> items) {
  if (items.isEmpty) return null;
  return items
      .map((i) {
        final qty = i.qty != null && i.qty! > 1 ? tr('{0} × ', [_plain(i.qty!)]) : '';
        return '$qty${i.label} — ${_plain(i.price)}';
      })
      .join('\n');
}

/// Nombre de chiffres après la virgule tels que saisis (« 12,345 » → 3).
int _decimals(String text) {
  final parts = text.trim().replaceAll(',', '.').split('.');
  return parts.length < 2 ? 0 : parts.last.length;
}

double? _parse(String text) => double.tryParse(text.trim().replaceAll(' ', '').replaceAll(',', '.'));

/// 12.5 → « 12,5 », 33.0 → « 33 » (saisie lisible en français).
String _plain(double value, {int decimals = 2}) {
  var text = value.toStringAsFixed(decimals);
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return text.replaceAll('.', ',');
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
