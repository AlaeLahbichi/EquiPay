import 'package:flutter/material.dart';
import '../../l10n/i18n.dart';

/// Façon d'ajouter une dépense.
enum ExpenseMethod { manual, scan, describe }

/// Choix de la méthode : saisie manuelle, scan du reçu ou description en une phrase.
Future<ExpenseMethod?> showAddExpenseSheet(BuildContext context) {
  return showModalBottomSheet<ExpenseMethod>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const _MethodSheet(),
  );
}

class _MethodSheet extends StatelessWidget {
  const _MethodSheet();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text(tr('Ajouter une dépense'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ),
            _MethodTile(
              icon: Icons.edit_note_rounded,
              color: colors.primary,
              title: tr('Saisie manuelle'),
              subtitle: tr('Renseigne le montant, qui a payé et la répartition'),
              onTap: () => Navigator.pop(context, ExpenseMethod.manual),
            ),
            const SizedBox(height: 10),
            _MethodTile(
              icon: Icons.document_scanner_outlined,
              color: colors.secondary,
              title: tr('Scanner un reçu'),
              subtitle: tr('Photographie ou importe ton ticket, l\'assistant remplit la dépense'),
              onTap: () => Navigator.pop(context, ExpenseMethod.scan),
            ),
            const SizedBox(height: 10),
            _MethodTile(
              icon: Icons.auto_awesome_rounded,
              color: colors.tertiary,
              title: tr('Décrire la dépense'),
              subtitle: tr('Écris « 60 € de resto avec Sara », l\'assistant s\'occupe du reste'),
              onTap: () => Navigator.pop(context, ExpenseMethod.describe),
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: color, size: 30),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    Text(subtitle, style: TextStyle(color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
