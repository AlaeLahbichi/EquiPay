import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../models/activity.dart';
import '../../models/plan.dart';
import '../../services/account_service.dart';
import '../../services/activity_repository.dart';
import '../../widgets/currency_field.dart';
import '../plans/plans_page.dart';
import '../../l10n/i18n.dart';

enum _AddChoice { create, join }

/// Résultat du panneau « + ».
enum AddResult { none, created, createdWithoutLogo, requested }

/// Ouvre le choix « Créer / Rejoindre » puis le formulaire correspondant.
Future<AddResult> showAddActivitySheet(BuildContext context, ActivityRepository repository) async {
  final choice = await showModalBottomSheet<_AddChoice>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _ChoiceSheet(),
  );
  if (choice == null || !context.mounted) return AddResult.none;

  final result = await showModalBottomSheet<AddResult>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => switch (choice) {
      _AddChoice.create => _CreateSheet(repository: repository),
      _AddChoice.join => _JoinSheet(repository: repository),
    },
  );
  return result ?? AddResult.none;
}

class _ChoiceSheet extends StatelessWidget {
  const _ChoiceSheet();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ChoiceTile(
              icon: Icons.add_circle_outline_rounded,
              color: colors.primary,
              title: tr('Créer une activité'),
              subtitle: tr('Voyage, sortie, dépenses du quotidien…'),
              onTap: () => Navigator.pop(context, _AddChoice.create),
            ),
            const SizedBox(height: 10),
            _ChoiceTile(
              icon: Icons.vpn_key_outlined,
              color: colors.secondary,
              title: tr('Rejoindre une activité'),
              subtitle: tr('Avec le code envoyé par son créateur'),
              onTap: () => Navigator.pop(context, _AddChoice.join),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
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
                    Text(subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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

/// Mise en page commune des formulaires (suit le clavier).
class _FormSheet extends StatelessWidget {
  const _FormSheet({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({required this.label, required this.loading, required this.onPressed});

  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: loading ? null : onPressed,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: loading
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        if (loading) const _SlowHint(),
      ],
    );
  }
}

/// Apparaît si une action dure plus de 6 secondes.
class _SlowHint extends StatefulWidget {
  const _SlowHint();

  @override
  State<_SlowHint> createState() => _SlowHintState();
}

class _SlowHintState extends State<_SlowHint> {
  late final Timer _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 6), () => setState(() => _visible = true));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 300),
      child: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          tr('Ça prend un peu plus de temps que prévu…'),
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _CreateSheet extends StatefulWidget {
  const _CreateSheet({required this.repository});

  final ActivityRepository repository;

  @override
  State<_CreateSheet> createState() => _CreateSheetState();
}

class _CreateSheetState extends State<_CreateSheet> {
  final _name = TextEditingController();
  ActivityType _type = ActivityType.voyage;
  String? _currency = AccountService.instance.state.value?.defaultCurrency;
  Uint8List? _logo;
  bool _loading = false;
  String? _error;
  String? _currencyError;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _chooseLogo() async {
    final source = await showModalBottomSheet<ImageSource?>(
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
            if (_logo != null)
              ListTile(
                leading: const Icon(Icons.restart_alt_rounded),
                title: Text(tr('Utiliser le logo par défaut')),
                onTap: () {
                  setState(() => _logo = null);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      // Image réduite et compressée en JPEG pour un envoi rapide
      final file = await ImagePicker().pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 80);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (mounted) setState(() => _logo = bytes);
    } catch (_) {
      if (mounted) {
        setState(() => _error = tr('Impossible d\'accéder aux photos. Vérifie les autorisations.'));
      }
    }
  }

  Future<void> _submit() async {
    final currency = _currency;
    setState(() {
      _error = _name.text.trim().isEmpty ? tr('Donne un nom à ton activité') : null;
      _currencyError = currency == null ? tr('Choisis la devise des dépenses') : null;
    });
    if (_error != null || currency == null) return;
    setState(() => _loading = true);
    try {
      final logoSaved = await widget.repository.create(name: _name.text, type: _type, currency: currency, logo: _logo);
      if (mounted) {
        Navigator.pop(context, logoSaved ? AddResult.created : AddResult.createdWithoutLogo);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
      if (e is PostgrestException && e.hint == 'plan_limit') {
        await showUpgradeSheet(
          context,
          title: tr('Limite d\'activités en cours'),
          message: (AccountService.instance.state.value?.plan ?? Plan.free).limitMessage(PlanFeature.activities),
          feature: PlanFeature.activities,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _FormSheet(
      title: tr('Nouvelle activité'),
      children: [
        Center(
          child: _LogoPicker(logo: _logo, type: _type, onTap: _loading ? null : _chooseLogo),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: tr('Nom'),
            hintText: tr('Ex. Marrakech 2026'),
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        CurrencyField(
          value: _currency,
          errorText: _currencyError,
          helperText: tr('Toutes les dépenses de l\'activité seront calculées dans cette devise.'),
          onChanged: _loading
              ? null
              : (code) => setState(() {
                  _currency = code;
                  _currencyError = null;
                }),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final type in ActivityType.values)
              ChoiceChip(
                avatar: Icon(type.icon, size: 18, color: type.color),
                label: Text(type.label),
                selected: _type == type,
                onSelected: (_) => setState(() => _type = type),
              ),
          ],
        ),
        const SizedBox(height: 20),
        _SubmitButton(label: tr('Créer'), loading: _loading, onPressed: _submit),
      ],
    );
  }
}

/// Logo de l'activité : photo choisie, ou icône du type par défaut.
class _LogoPicker extends StatelessWidget {
  const _LogoPicker({required this.logo, required this.type, required this.onTap});

  final Uint8List? logo;
  final ActivityType type;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final logo = this.logo;
    return Semantics(
      button: true,
      label: tr('Choisir le logo de l\'activité'),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: type.color.withValues(alpha: 0.15),
                  foregroundImage: logo != null ? MemoryImage(logo) : null,
                  child: Icon(type.icon, color: type.color, size: 40),
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
              logo == null ? tr('Ajouter un logo (optionnel)') : tr('Changer le logo'),
              style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoinSheet extends StatefulWidget {
  const _JoinSheet({required this.repository});

  final ActivityRepository repository;

  @override
  State<_JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<_JoinSheet> {
  final _code = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (code.length != 8) {
      setState(() => _error = tr('Le code contient 8 caractères'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.repository.join(code);
      if (mounted) Navigator.pop(context, AddResult.requested);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _FormSheet(
      title: tr('Rejoindre une activité'),
      children: [
        TextField(
          controller: _code,
          autofocus: true,
          maxLength: 9,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          style: const TextStyle(fontSize: 20, letterSpacing: 3, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            labelText: tr('Code de l\'activité'),
            hintText: tr('ABCD-EFGH'),
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          tr('Le créateur de l\'activité recevra ta demande et pourra l\'accepter.'),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        _SubmitButton(label: tr('Envoyer la demande'), loading: _loading, onPressed: _submit),
      ],
    );
  }
}
