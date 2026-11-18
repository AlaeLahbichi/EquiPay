import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../l10n/i18n.dart';

/// Bouton rond « + » avec dégradé orange.
class AddButton extends StatelessWidget {
  const AddButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tr('Créer ou rejoindre une activité'),
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFB923C), AppColors.accent],
          ),
          boxShadow: [
            BoxShadow(color: AppColors.accent.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, 6)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: const Icon(Icons.add_rounded, color: Colors.white, size: 36),
          ),
        ),
      ),
    );
  }
}
