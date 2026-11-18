import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../l10n/i18n.dart';

/// Page « À propos » : présentation de l'application.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const _features = [
    (
      Icons.luggage_rounded,
      'Activités',
      'Crée un voyage, une sortie, des dépenses du quotidien ou un crédit, et invite tes amis '
          'avec un code unique ou par email.',
    ),
    (
      Icons.receipt_long_rounded,
      'Dépenses',
      'Ajoute chaque dépense avec son montant, sa devise, sa date, un lieu et jusqu\'à deux photos '
          'du reçu. Seul son auteur peut la modifier.',
    ),
    (
      Icons.pie_chart_rounded,
      'Partage équitable',
      'Répartis chaque dépense en parts égales ou en pourcentages : EquiPay calcule qui doit '
          'combien à qui.',
    ),
    (
      Icons.sync_rounded,
      'Soldes en temps réel',
      'Les totaux et les soldes de chaque membre se mettent à jour instantanément sur tous les '
          'téléphones.',
    ),
    (
      Icons.visibility_rounded,
      'Spectateurs',
      'Invite une personne en lecture seule : elle suit l\'activité sans pouvoir la modifier.',
    ),
    (
      Icons.support_agent_rounded,
      'Assistant intelligent',
      'Un assistant entraîné spécialement pour EquiPay répond à tes questions sur l\'application, '
          'même sans compte.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('À propos'), style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Center(
            child: Container(
              width: 132,
              height: 132,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Image.asset('assets/branding/logo.png'),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            tr('EquiPay'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: colors.primary),
          ),
          Text(
            tr('Version 1.0.0 · by Alae Lahbichi'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Text(
            tr('EquiPay simplifie le partage des dépenses entre amis, en famille ou entre collègues. '
            'Fini les calculs compliqués après un voyage ou une soirée : chacun ajoute ce qu\'il a '
            'payé, et l\'application répartit les montants de façon juste et transparente.'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, height: 1.5, color: colors.onSurface),
          ),
          const SizedBox(height: 28),
          Text(tr('Fonctionnalités'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  for (final (icon, title, text) in _features)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      leading: Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(icon, color: colors.primary, size: 22),
                      ),
                      title: Text(title.tr, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(text.tr, style: const TextStyle(height: 1.35)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            tr('© 2026 Alae Lahbichi'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
