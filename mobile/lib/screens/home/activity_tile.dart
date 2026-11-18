import 'package:flutter/material.dart';

import '../../models/activity.dart';

/// Ligne de la liste : logo de l'activité, son nom et une flèche
/// (ou une case à cocher en mode sélection).
class ActivityTile extends StatelessWidget {
  const ActivityTile({super.key, required this.activity, required this.onTap, this.onLongPress, this.selected});

  final Activity activity;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// null hors mode sélection.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = this.selected;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: selected == true ? colors.primary.withValues(alpha: 0.12) : null,
      shape: selected == true
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: colors.primary, width: 1.5),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ActivityLogo(activity: activity),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  activity.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: selected == null
                    ? Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant)
                    : Icon(
                        selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                        key: ValueKey(selected),
                        color: selected ? colors.primary : colors.onSurfaceVariant,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Photo de l'activité, ou à défaut l'icône de son type sur fond coloré.
class ActivityLogo extends StatelessWidget {
  const ActivityLogo({super.key, required this.activity, this.size = 48});

  final Activity activity;
  final double size;

  @override
  Widget build(BuildContext context) {
    final type = activity.type;
    final coverUrl = activity.coverUrl;
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: type.color.withValues(alpha: 0.15),
      foregroundImage: coverUrl != null ? NetworkImage(coverUrl) : null,
      child: Icon(type.icon, color: type.color, size: size * 0.5),
    );
  }
}
