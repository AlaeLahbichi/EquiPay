import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/activity.dart';
import '../../models/activity_overview.dart';
import '../../services/activity_repository.dart';
import '../../theme/app_colors.dart';
import '../../widgets/currency_field.dart';
import '../../widgets/user_avatar.dart';
import '../../l10n/i18n.dart';

/// Owner : modifier le nom, la photo et la devise de l'activité. Renvoie l'activité à jour, ou null si annulé.
/// currencyLocked : l'activité a déjà des dépenses, sa devise ne peut plus changer.
Future<Activity?> showEditActivitySheet(
  BuildContext context,
  ActivityRepository repository,
  Activity activity, {
  bool currencyLocked = false,
}) {
  return showModalBottomSheet<Activity>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _EditActivitySheet(repository: repository, activity: activity, currencyLocked: currencyLocked),
  );
}

class _EditActivitySheet extends StatefulWidget {
  const _EditActivitySheet({required this.repository, required this.activity, required this.currencyLocked});

  final ActivityRepository repository;
  final Activity activity;
  final bool currencyLocked;

  @override
  State<_EditActivitySheet> createState() => _EditActivitySheetState();
}

class _EditActivitySheetState extends State<_EditActivitySheet> {
  late final _name = TextEditingController(text: widget.activity.name);
  late var _currency = widget.activity.currency;
  Uint8List? _cover;
  var _removeCover = false;
  var _loading = false;
  String? _error;

  /// Erreur d'envoi ou d'accès aux photos (affichée au-dessus du bouton).
  String? _saveError;

  bool get _hasCover => _cover != null || (widget.activity.coverUrl != null && !_removeCover);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _choosePhoto() async {
    final source = await showModalBottomSheet<Object?>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr('Choisir dans la galerie')),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(tr('Prendre une photo')),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            if (_hasCover)
              ListTile(
                leading: const Icon(Icons.restart_alt_rounded),
                title: Text(tr('Utiliser le logo par défaut')),
                onTap: () => Navigator.pop(context, 'default'),
              ),
          ],
        ),
      ),
    );
    if (source == 'default') {
      setState(() {
        _cover = null;
        _removeCover = true;
      });
      return;
    }
    if (source is! ImageSource) return;
    try {
      final file = await ImagePicker().pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 80);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (mounted) {
        setState(() {
          _cover = bytes;
          _removeCover = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saveError = tr('Impossible d\'accéder aux photos. Vérifie les autorisations.'));
      }
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr('Donne un nom à ton activité'));
      return;
    }
    final unchanged =
        name == widget.activity.name && _currency == widget.activity.currency && _cover == null && !_removeCover;
    if (unchanged) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _saveError = null;
    });
    try {
      final updated = await widget.repository.updateActivity(
        widget.activity,
        name: name,
        currency: _currency,
        cover: _cover,
        removeCover: _removeCover,
      );
      if (mounted) Navigator.pop(context, updated);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _saveError = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = widget.activity.type;
    final coverUrl = _removeCover ? null : widget.activity.coverUrl;
    final ImageProvider? image = _cover != null
        ? MemoryImage(_cover!)
        : coverUrl != null
        ? NetworkImage(coverUrl)
        : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('Modifier l\'activité'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              Center(
                child: Semantics(
                  button: true,
                  label: tr('Changer la photo de l\'activité'),
                  child: GestureDetector(
                    onTap: _loading ? null : _choosePhoto,
                    child: Column(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            CircleAvatar(
                              radius: 48,
                              backgroundColor: type.color.withValues(alpha: 0.15),
                              foregroundImage: image,
                              child: Icon(type.icon, color: type.color, size: 44),
                            ),
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: CircleAvatar(
                                radius: 16,
                                backgroundColor: colors.primary,
                                child: const Icon(Icons.photo_camera_rounded, size: 16, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          tr('Changer la photo'),
                          style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                enabled: !_loading,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(labelText: tr('Titre'), errorText: _error, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              CurrencyField(
                value: _currency,
                helperText: widget.currencyLocked
                    ? tr('L\'activité contient déjà des dépenses : sa devise ne peut plus changer.')
                    : tr('Toutes les dépenses de l\'activité sont calculées dans cette devise.'),
                onChanged: widget.currencyLocked || _loading ? null : (code) => setState(() => _currency = code),
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _saveError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _loading ? null : _save,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                child: _loading
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : Text(tr('Enregistrer'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Owner : gérer un participant (rôle membre/spectateur, ou le retirer).
/// Renvoie le message à afficher une fois l'action faite, ou null si rien n'a changé.
Future<String?> showMemberActionsSheet(
  BuildContext context,
  ActivityRepository repository, {
  required String activityId,
  required MemberSummary member,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _MemberActionsSheet(repository: repository, activityId: activityId, member: member),
  );
}

class _MemberActionsSheet extends StatefulWidget {
  const _MemberActionsSheet({required this.repository, required this.activityId, required this.member});

  final ActivityRepository repository;
  final String activityId;
  final MemberSummary member;

  @override
  State<_MemberActionsSheet> createState() => _MemberActionsSheetState();
}

class _MemberActionsSheetState extends State<_MemberActionsSheet> {
  late var _role = widget.member.role;
  var _loading = false;
  String? _error;

  String get _name => widget.member.profile.displayName;

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.pop(context, done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _role = widget.member.role;
          _error = friendlyError(e);
        });
      }
    }
  }

  void _setRole(MemberRole role) {
    if (role == _role || _loading) return;
    setState(() => _role = role);
    final label = role == MemberRole.viewer ? 'spectateur' : 'membre';
    _run(
      () => widget.repository.setMemberRole(widget.activityId, widget.member.profile.id, role),
      tr('{0} est maintenant {1}', [_name, label]),
    );
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Retirer {0} ?', [_name])),
        content: Text(
          tr('Cette personne n\'aura plus accès à l\'activité. Elle pourra redemander à la rejoindre avec le code.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annuler'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.negative),
            child: Text(tr('Retirer')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _run(
      () => widget.repository.removeMember(widget.activityId, widget.member.profile.id),
      tr('{0} a été retiré de l\'activité', [_name]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final profile = widget.member.profile;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: UserAvatar(user: profile, size: 64)),
            const SizedBox(height: 8),
            Text(
              _name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            if (profile.email.isNotEmpty)
              Text(
                profile.email,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                tr('Rôle'),
                style: TextStyle(fontWeight: FontWeight.w700, color: colors.onSurfaceVariant),
              ),
            ),
            _RoleOption(
              icon: Icons.person_rounded,
              title: tr('Membre (participant)'),
              subtitle: tr('Ajoute des dépenses et participe au partage'),
              selected: _role == MemberRole.member,
              onTap: _loading ? null : () => _setRole(MemberRole.member),
            ),
            const SizedBox(height: 8),
            _RoleOption(
              icon: Icons.visibility_outlined,
              title: tr('Spectateur'),
              subtitle: tr('Consulte l\'activité sans rien modifier'),
              selected: _role == MemberRole.viewer,
              onTap: _loading ? null : () => _setRole(MemberRole.viewer),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.error),
              ),
            ],
            const SizedBox(height: 16),
            if (_loading)
              const Center(
                child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
              )
            else
              TextButton.icon(
                onPressed: _remove,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.negative,
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: const Icon(Icons.person_remove_outlined),
                label: Text(tr('Retirer de l\'activité'), style: TextStyle(fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }
}

class _RoleOption extends StatelessWidget {
  const _RoleOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.primary.withValues(alpha: 0.10) : colors.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? colors.primary : Colors.transparent, width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: selected ? colors.primary : colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(subtitle, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: selected
                    ? Icon(Icons.check_circle_rounded, key: const ValueKey(true), color: colors.primary)
                    : Icon(Icons.circle_outlined, key: const ValueKey(false), color: colors.outlineVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
