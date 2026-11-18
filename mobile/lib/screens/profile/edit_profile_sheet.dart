import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/user_profile.dart';
import '../../services/activity_repository.dart';
import '../../services/auth_service.dart';
import '../../l10n/i18n.dart';

/// Feuille « Modifier mes informations » : nom, pseudo et email.
Future<void> showEditProfileSheet(BuildContext context, AuthService auth, UserProfile user) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _EditProfileSheet(auth: auth, user: user),
  );
}

/// Choix d'une nouvelle photo (galerie ou appareil photo), puis envoi.
Future<void> changeAvatar(BuildContext context, AuthService auth) async {
  final messenger = ScaffoldMessenger.of(context);
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(tr('Photo de profil'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
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
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null) return;

  final XFile? file;
  try {
    // Image carrée réduite et compressée en JPEG pour un envoi rapide
    file = await ImagePicker().pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 80);
  } catch (_) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('Impossible d\'accéder aux photos. Vérifie les autorisations.'))),
    );
    return;
  }
  if (file == null) return;

  messenger.showSnackBar(SnackBar(content: Text(tr('Envoi de la photo…'))));
  try {
    await auth.updateAvatar(await file.readAsBytes());
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tr('Photo de profil mise à jour.'))));
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }
}

class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({required this.auth, required this.user});

  final AuthService auth;
  final UserProfile user;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user.fullName ?? '');
  late final _username = TextEditingController(text: widget.user.username ?? '');
  late final _email = TextEditingController(text: widget.user.email);
  var _busy = false;
  String? _error;

  static final _usernamePattern = RegExp(r'^[a-z0-9_]{3,30}$');

  @override
  void dispose() {
    for (final c in [_name, _username, _email]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.auth.updateProfile(fullName: _name.text, username: _username.text);
      final newEmail = _email.text.trim().toLowerCase();
      final emailChanged = newEmail != widget.user.email.toLowerCase();
      if (emailChanged) await widget.auth.updateEmail(newEmail);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            emailChanged
                ? tr('Informations enregistrées. Confirme ton nouvel email avec le lien reçu à {0}.', [newEmail])
                : tr('Informations enregistrées.'),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is UsernameTakenException ? e.toString() : friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('Modifier mes informations'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 20),
            _field(
              _name,
              tr('Nom'),
              Icons.badge_outlined,
              capitalize: true,
              validator: (v) => v!.trim().isEmpty ? tr('Obligatoire') : null,
            ),
            const SizedBox(height: 12),
            _field(
              _username,
              tr('Pseudo'),
              Icons.alternate_email_rounded,
              helper: tr('Lettres minuscules, chiffres et _ (3 à 30)'),
              validator: (v) => _usernamePattern.hasMatch(v!.trim().toLowerCase()) ? null : tr('Pseudo invalide'),
            ),
            const SizedBox(height: 12),
            _field(
              _email,
              tr('Email'),
              Icons.mail_outline_rounded,
              keyboard: TextInputType.emailAddress,
              validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v!.trim()) ? null : tr('Email invalide'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Text(tr('Enregistrer'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    String? helper,
    TextInputType? keyboard,
    bool capitalize = false,
    required String? Function(String?) validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboard,
      textCapitalization: capitalize ? TextCapitalization.words : TextCapitalization.none,
      autocorrect: false,
      textInputAction: TextInputAction.next,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        prefixIcon: Icon(icon),
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
    );
  }
}
