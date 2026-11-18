import 'package:flutter/material.dart';

import '../utils/money.dart';
import '../l10n/i18n.dart';

/// Champ « Devise » : affiche la devise choisie et ouvre la liste au toucher.
class CurrencyField extends StatelessWidget {
  const CurrencyField({super.key, required this.value, required this.onChanged, this.errorText, this.helperText});

  /// Code ISO (ex. « EUR »), null tant que rien n'est choisi.
  final String? value;

  /// null : champ désactivé.
  final ValueChanged<String>? onChanged;
  final String? errorText;
  final String? helperText;

  Future<void> _pick(BuildContext context) async {
    final code = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _CurrencyList(selected: value),
    );
    if (code != null) onChanged?.call(code);
  }

  @override
  Widget build(BuildContext context) {
    final currency = value == null ? null : currencyByCode(value!);
    final enabled = onChanged != null;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: enabled ? () => _pick(context) : null,
      child: InputDecorator(
        isEmpty: value == null,
        decoration: InputDecoration(
          labelText: tr('Devise'),
          hintText: tr('Choisis la devise'),
          errorText: errorText,
          helperText: helperText,
          helperMaxLines: 2,
          enabled: enabled,
          border: const OutlineInputBorder(),
          suffixIcon: Icon(enabled ? Icons.expand_more_rounded : Icons.lock_outline_rounded),
        ),
        child: value == null
            ? null
            : Text(
                currency == null
                    ? value!
                    : '${currency.flag}  ${currency.name.tr} (${currency.code} · ${currency.symbol})',
                overflow: TextOverflow.ellipsis,
              ),
      ),
    );
  }
}

class _CurrencyList extends StatelessWidget {
  const _CurrencyList({required this.selected});

  final String? selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(tr('Devise de l\'activité'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ),
          for (final c in currencies)
            ListTile(
              leading: Text(c.flag, style: const TextStyle(fontSize: 26)),
              title: Text(c.name.tr),
              subtitle: Text('${c.code} · ${c.symbol}'),
              trailing: c.code == selected ? Icon(Icons.check_circle_rounded, color: colors.primary) : null,
              selected: c.code == selected,
              onTap: () => Navigator.pop(context, c.code),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
