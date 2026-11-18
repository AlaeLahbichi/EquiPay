import 'package:flutter/material.dart';

import '../../models/user_profile.dart';
import '../../services/account_service.dart';
import '../../services/activity_repository.dart';
import '../../services/auth_service.dart';
import '../../widgets/currency_field.dart';
import '../plans/plans_page.dart';
import '../../l10n/i18n.dart';

/// Formulaire de bienvenue, en trois étapes, affiché une fois au premier lancement après l'inscription.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.user, this.account});

  final UserProfile user;
  final AccountService? account;

  static const usages = [
    ('voyages', 'Voyages', Icons.flight_takeoff_rounded),
    ('sorties', 'Sorties entre amis', Icons.celebration_rounded),
    ('colocation', 'Colocation', Icons.home_rounded),
    ('couple', 'En couple', Icons.favorite_rounded),
    ('famille', 'Famille', Icons.family_restroom_rounded),
    ('credits', 'Prêts et crédits', Icons.credit_card_rounded),
    ('evenements', 'Événements', Icons.cake_rounded),
  ];

  static const referrals = [
    ('ami', 'Un ami'),
    ('reseaux', 'Réseaux sociaux'),
    ('store', 'App Store / Google Play'),
    ('ecole', 'École ou université'),
    ('autre', 'Autre'),
  ];

  static const countries = ['Maroc', 'France', 'Belgique', 'Suisse', 'Canada', 'Espagne'];

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pages = PageController();
  late final _name = TextEditingController(text: widget.user.fullName ?? '');
  late final _username = TextEditingController(text: widget.user.username ?? '');
  final _otherCountry = TextEditingController();
  var _step = 0;
  String _currency = 'MAD';
  String? _country = 'Maroc';
  final _usages = <String>{};
  String? _referral;
  String? _nameError;
  String? _usernameError;
  String? _error;
  var _saving = false;

  AccountService get _account => widget.account ?? AccountService.instance;

  static final _usernamePattern = RegExp(r'^[a-z0-9_]{3,30}$');

  @override
  void dispose() {
    _pages.dispose();
    _name.dispose();
    _username.dispose();
    _otherCountry.dispose();
    super.dispose();
  }

  bool _validateIdentity() {
    final username = _username.text.trim().toLowerCase();
    setState(() {
      _nameError = _name.text.trim().length < 2 ? tr('Indique ton nom') : null;
      _usernameError = _usernamePattern.hasMatch(username)
          ? null
          : tr('3 à 30 caractères : lettres minuscules, chiffres ou _');
    });
    return _nameError == null && _usernameError == null;
  }

  Future<void> _next() async {
    FocusScope.of(context).unfocus();
    if (_step == 0 && !_validateIdentity()) return;
    if (_step < 2) {
      setState(() => _step++);
      await _pages.animateToPage(_step, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
      return;
    }
    await _finish();
  }

  Future<void> _back() async {
    if (_step == 0) return;
    setState(() => _step--);
    await _pages.animateToPage(_step, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
  }

  Future<void> _finish() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _account.completeOnboarding(
        OnboardingAnswers(
          fullName: _name.text,
          username: _username.text,
          currency: _currency,
          country: _country == 'Autre' ? _otherCountry.text : _country,
          usages: _usages.toList(),
          referral: _referral,
        ),
      );
      if (!mounted) return;
      await Navigator.of(context)
          .pushReplacement(MaterialPageRoute(builder: (_) => PlansPage(welcome: true, account: widget.account)));
    } on UsernameTakenException catch (e) {
      // Pseudo déjà pris : retour à la première étape pour en choisir un autre
      if (!mounted) return;
      setState(() {
        _saving = false;
        _usernameError = e.toString();
        _step = 0;
      });
      _pages.jumpToPage(0);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(
                  children: [
                    for (var i = 0; i < 3; i++)
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: 5,
                          margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                          decoration: BoxDecoration(
                            color: i <= _step ? colors.primary : colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [_identity(), _place(), _usage()],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    _error!,
                    style: TextStyle(color: colors.error),
                    textAlign: TextAlign.center,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Row(
                  children: [
                    if (_step > 0)
                      TextButton.icon(
                        onPressed: _saving ? null : _back,
                        icon: const Icon(Icons.arrow_back_rounded),
                        label: Text(tr('Retour')),
                      ),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(150, 50)),
                      onPressed: _saving ? null : _next,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                            )
                          : Text(_step < 2 ? tr('Continuer') : tr('Terminer')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepPage({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
      children: [
        CircleAvatar(
          radius: 30,
          backgroundColor: colors.primary.withValues(alpha: 0.12),
          child: Icon(icon, color: colors.primary, size: 30),
        ),
        const SizedBox(height: 18),
        Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(subtitle, style: TextStyle(fontSize: 15, color: colors.onSurfaceVariant)),
        const SizedBox(height: 24),
        ...children,
      ],
    );
  }

  Widget _identity() => _stepPage(
    icon: Icons.waving_hand_rounded,
    title: tr('Bienvenue sur EquiPay'),
    subtitle: tr('Quelques questions pour préparer ton compte. Ça prend moins d\'une minute.'),
    children: [
      TextField(
        controller: _name,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: tr('Ton nom'),
          helperText: tr('Visible par les membres de tes activités'),
          errorText: _nameError,
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.person_outline_rounded),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _username,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: tr('Pseudo'),
          helperText: tr('Tes amis te retrouvent avec @pseudo'),
          errorText: _usernameError,
          border: const OutlineInputBorder(),
          prefixText: '@',
        ),
      ),
    ],
  );

  Widget _place() => _stepPage(
    icon: Icons.public_rounded,
    title: tr('Ta devise et ton pays'),
    subtitle: tr('Ta devise sera proposée par défaut quand tu crées une activité.'),
    children: [
      CurrencyField(value: _currency, onChanged: (code) => setState(() => _currency = code)),
      const SizedBox(height: 22),
      Text(tr('Tu habites'), style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in [...OnboardingPage.countries, 'Autre'])
            ChoiceChip(label: Text(c.tr), selected: _country == c, onSelected: (_) => setState(() => _country = c)),
        ],
      ),
      if (_country == 'Autre') ...[
        const SizedBox(height: 12),
        TextField(
          controller: _otherCountry,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: tr('Ton pays'), border: OutlineInputBorder()),
        ),
      ],
    ],
  );

  Widget _usage() => _stepPage(
    icon: Icons.groups_rounded,
    title: tr('Tu utiliseras EquiPay pour…'),
    subtitle: tr('Choisis autant de réponses que tu veux.'),
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (id, label, icon) in OnboardingPage.usages)
            FilterChip(
              avatar: Icon(icon, size: 18),
              label: Text(label.tr),
              selected: _usages.contains(id),
              onSelected: (on) => setState(() => on ? _usages.add(id) : _usages.remove(id)),
            ),
        ],
      ),
      const SizedBox(height: 26),
      Text(tr('Comment as-tu connu EquiPay ?'), style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (id, label) in OnboardingPage.referrals)
            ChoiceChip(
              label: Text(label.tr),
              selected: _referral == id,
              onSelected: (on) => setState(() => _referral = on ? id : null),
            ),
        ],
      ),
    ],
  );
}
