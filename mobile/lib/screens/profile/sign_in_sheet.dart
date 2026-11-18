import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../../services/activity_repository.dart';
import '../../services/auth_service.dart';
import '../../l10n/i18n.dart';

/// Feuille de connexion / inscription par email.
Future<void> showSignInSheet(BuildContext context, AuthService auth) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SignInSheet(auth: auth),
  );
}

enum _Mode { signIn, signUp }

class _SignInSheet extends StatefulWidget {
  const _SignInSheet({required this.auth});

  final AuthService auth;

  @override
  State<_SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<_SignInSheet> {
  final _form = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _mode = _Mode.signIn;
  var _busy = false;
  var _hidePassword = true;
  String? _error;
  String? _confirmationSentTo;

  @override
  void dispose() {
    for (final c in [_firstName, _lastName, _email, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_mode == _Mode.signIn) {
        await widget.auth.signInWithEmail(email: _email.text, password: _password.text);
        if (mounted) Navigator.pop(context);
      } else {
        final needsConfirmation = await widget.auth.signUpWithEmail(
          email: _email.text,
          password: _password.text,
          firstName: _firstName.text,
          lastName: _lastName.text,
        );
        if (!mounted) return;
        if (needsConfirmation) {
          setState(() => _confirmationSentTo = _email.text.trim());
        } else {
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object e) {
    if (e is AuthException) {
      if (e.code == 'invalid_credentials') return tr('Email ou mot de passe incorrect.');
      if (e.code == 'email_not_confirmed') return tr('Confirme d\'abord ton email (lien reçu par mail).');
      if (e.code == 'user_already_exists') return tr('Un compte existe déjà avec cet email.');
      if (e.code == 'weak_password') return tr('Mot de passe trop faible (6 caractères minimum).');
      return e.message;
    }
    return friendlyError(e);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        child: _confirmationSentTo != null ? _confirmationSent() : _formView(),
      ),
    );
  }

  Widget _confirmationSent() {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.mark_email_read_rounded, size: 64, color: colors.primary),
        const SizedBox(height: 16),
        Text(tr('Vérifie ta boîte mail'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(
          tr('Un lien de confirmation a été envoyé à {0}.\n'
          'Ouvre-le depuis ce téléphone pour activer ton compte.', [_confirmationSentTo]),
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: Text(tr('Compris')),
        ),
      ],
    );
  }

  Widget _formView() {
    final signUp = _mode == _Mode.signUp;
    final colors = Theme.of(context).colorScheme;
    return Form(
      key: _form,
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              signUp ? tr('Créer un compte') : tr('Se connecter'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            SegmentedButton<_Mode>(
              segments: [
                ButtonSegment(value: _Mode.signIn, label: Text(tr('Connexion'))),
                ButtonSegment(value: _Mode.signUp, label: Text(tr('Inscription'))),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              onSelectionChanged: _busy
                  ? null
                  : (s) => setState(() {
                      _mode = s.first;
                      _error = null;
                    }),
            ),
            const SizedBox(height: 16),
            if (signUp) ...[
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _firstName,
                      tr('Prénom'),
                      autofill: AutofillHints.givenName,
                      capitalize: true,
                      required: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      _lastName,
                      tr('Nom'),
                      autofill: AutofillHints.familyName,
                      capitalize: true,
                      required: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            _field(
              _email,
              tr('Email'),
              autofill: AutofillHints.email,
              keyboard: TextInputType.emailAddress,
              icon: Icons.mail_outline_rounded,
              validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v!.trim()) ? null : tr('Email invalide'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: _hidePassword,
              autofillHints: [signUp ? AutofillHints.newPassword : AutofillHints.password],
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              validator: (v) => v!.length < 6 ? tr('6 caractères minimum') : null,
              decoration: _decoration(tr('Mot de passe'), Icons.lock_outline_rounded).copyWith(
                suffixIcon: IconButton(
                  tooltip: _hidePassword ? tr('Afficher') : tr('Masquer'),
                  icon: Icon(_hidePassword ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                  onPressed: () => setState(() => _hidePassword = !_hidePassword),
                ),
              ),
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
              onPressed: _busy ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Text(
                      signUp ? tr('Créer mon compte') : tr('Se connecter'),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? autofill,
    TextInputType? keyboard,
    IconData? icon,
    bool capitalize = false,
    bool required = false,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboard,
      autofillHints: autofill == null ? null : [autofill],
      textCapitalization: capitalize ? TextCapitalization.words : TextCapitalization.none,
      textInputAction: TextInputAction.next,
      validator: validator ?? (required ? (v) => v!.trim().isEmpty ? tr('Obligatoire') : null : null),
      decoration: _decoration(label, icon),
    );
  }

  InputDecoration _decoration(String label, IconData? icon) => InputDecoration(
    labelText: label,
    prefixIcon: icon == null ? null : Icon(icon),
    filled: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
  );
}
