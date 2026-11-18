import 'package:flutter/material.dart';

import '../../l10n/i18n.dart';
import '../../services/notification_service.dart';

import '../../models/plan.dart';
import '../../models/user_profile.dart';
import '../../services/account_service.dart';
import '../../services/activity_repository.dart';
import '../../services/assistant_service.dart';
import '../../services/auth_service.dart';
import '../../services/expense_repository.dart';
import '../../services/receipt_scanner.dart';
import '../../services/settings_controller.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/user_avatar.dart';
import '../plans/plans_page.dart';
import '../support/support_chat_page.dart';
import 'about_page.dart';
import 'archived_activities_page.dart';
import 'edit_profile_sheet.dart';
import 'sign_in_sheet.dart';

/// Onglet Profil : connexion (visiteur) ou infos du compte, préférences, support.
class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.auth,
    required this.settings,
    required this.assistant,
    required this.activities,
    required this.expenses,
    required this.receipts,
  });

  final AuthService auth;
  final SettingsController settings;
  final AssistantService assistant;
  final ActivityRepository activities;
  final ExpenseRepository expenses;
  final ReceiptScanner receipts;

  void _openArchives(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArchivedActivitiesPage(
          repository: activities,
          expenses: expenses,
          receipts: receipts,
          currentUserId: auth.user.value?.id,
        ),
      ),
    );
  }

  void _openSupport(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SupportChatPage(assistant: assistant, user: auth.user.value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Profil'), style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _SupportButton(onPressed: () => _openSupport(context)),
      body: ValueListenableBuilder<UserProfile?>(
        valueListenable: auth.user,
        builder: (context, user, _) => ListView(
          // Marge basse : le contenu passe au-dessus du bouton Support
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(sizeFactor: animation, child: child),
              ),
              child: user == null
                  ? _SignedOutHeader(key: const ValueKey('out'), auth: auth)
                  : _SignedInHeader(key: ValueKey(user.id), user: user, auth: auth),
            ),
            if (user != null) ...[
              _SectionTitle(tr('Mon offre')),
              ValueListenableBuilder<AccountState?>(
                valueListenable: AccountService.instance.state,
                builder: (context, account, _) => _OfferCard(plan: account?.plan ?? Plan.free),
              ),
              _SectionTitle(tr('Mes activités')),
              _Section(
                children: [
                  _Tile(
                    icon: Icons.inventory_2_outlined,
                    title: tr('Activités archivées'),
                    onTap: () => _openArchives(context),
                  ),
                ],
              ),
            ],
            _SectionTitle(tr('Préférences')),
            _Section(
              children: [
                _LanguageTile(settings: settings),
                _DarkModeTile(settings: settings),
                _NotificationsTile(settings: settings),
              ],
            ),
            _SectionTitle(tr('Extra')),
            _Section(
              children: [
                _Tile(
                  title: tr('À propos'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutPage())),
                ),
              ],
            ),
            if (user != null) ...[
              const SizedBox(height: 28),
              _Section(
                children: [
                  _CenteredAction(label: tr('Se déconnecter'), onTap: () => _signOut(context)),
                  _CenteredAction(label: tr('Supprimer mon compte'), onTap: () => _deleteAccount(context)),
                ],
              ),
            ],
            const SizedBox(height: 28),
            Text(
              tr('EquiPay · version 1.0.0\nby Alae Lahbichi'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _signOut(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: tr('Se déconnecter ?'),
      message: tr('Tu pourras te reconnecter à tout moment.'),
      action: tr('Se déconnecter'),
    );
    if (!ok || !context.mounted) return;
    await _run(context, auth.signOut, done: tr('Tu es déconnecté.'));
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: tr('Supprimer ton compte ?'),
      message: tr(
        'Ton profil, les activités que tu as créées et tes dépenses seront '
        'supprimés définitivement. Cette action est irréversible.',
      ),
      action: tr('Supprimer'),
    );
    if (!ok || !context.mounted) return;
    await _run(context, auth.deleteAccount, done: tr('Ton compte a été supprimé.'));
  }

  /// Exécute l'action avec un indicateur de chargement, puis affiche le résultat.
  Future<void> _run(BuildContext context, Future<void> Function() action, {required String done}) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
    );
    var message = done;
    try {
      await action();
    } catch (e) {
      message = tr('Échec : {0}', [e]);
    }
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String action,
  }) async {
    final colors = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annuler'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colors.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class _SignedOutHeader extends StatelessWidget {
  const _SignedOutHeader({super.key, required this.auth});

  final AuthService auth;

  Future<void> _google(BuildContext context) async {
    try {
      await auth.signInWithGoogle();
    } catch (e) {
      if (!context.mounted) return;
      final message = e is GoogleNotEnabledException ? e.toString() : tr('Connexion Google impossible.');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const SizedBox(height: 8),
        const UserAvatar(),
        const SizedBox(height: 16),
        Text(tr('Bienvenue sur EquiPay'), style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          tr('Connecte-toi pour créer tes activités\net partager tes dépenses.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 22),
        OutlinedButton.icon(
          onPressed: () => _google(context),
          icon: const _GoogleMark(),
          label: Text(tr('Continuer avec Google')),
          style: _buttonStyle.copyWith(backgroundColor: WidgetStatePropertyAll(colors.surface)),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () => showSignInSheet(context, auth),
          icon: const Icon(Icons.mail_outline_rounded),
          label: Text(tr('Continuer avec un email')),
          style: _buttonStyle,
        ),
      ],
    );
  }

  static final _buttonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size.fromHeight(52)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
  );
}

class _SignedInHeader extends StatelessWidget {
  const _SignedInHeader({super.key, required this.user, required this.auth});

  final UserProfile user;
  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    void edit() => showEditProfileSheet(context, auth, user);
    return Column(
      children: [
        const SizedBox(height: 8),
        Stack(
          children: [
            Semantics(
              button: true,
              label: tr('Voir la photo de profil'),
              child: GestureDetector(
                onTap: () => openPhotoViewer(
                  context,
                  photos: [
                    ViewerPhoto(
                      image: user.avatarUrl?.isNotEmpty == true
                          ? NetworkImage(user.avatarUrl!)
                          : UserAvatar.defaultImage as ImageProvider,
                      heroTag: 'my-avatar',
                      caption: user.displayName,
                    ),
                  ],
                  action: ViewerAction(
                    icon: Icons.photo_camera_rounded,
                    label: tr('Changer la photo'),
                    onPressed: () => changeAvatar(context, auth),
                  ),
                ),
                child: Hero(
                  tag: 'my-avatar',
                  child: UserAvatar(user: user),
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Semantics(
                button: true,
                label: tr('Changer la photo de profil'),
                child: GestureDetector(
                  onTap: () => changeAvatar(context, auth),
                  child: Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 3),
                    ),
                    child: Icon(Icons.photo_camera_rounded, size: 18, color: colors.onPrimary),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          user.displayName,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(user.email, style: TextStyle(fontSize: 16, color: colors.onSurfaceVariant)),
        const SizedBox(height: 24),
        _Section(
          children: [
            _InfoTile(label: tr('Nom'), value: user.displayName, onTap: edit),
            _InfoTile(label: tr('Pseudo'), value: user.username == null ? '—' : '@${user.username}', onTap: edit),
            _InfoTile(label: tr('Email'), value: user.email, onTap: edit),
          ],
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: edit,
          icon: const Icon(Icons.edit_rounded, size: 18),
          label: Text(tr('Modifier mes informations')),
        ),
      ],
    );
  }
}

class _DarkModeTile extends StatelessWidget {
  const _DarkModeTile({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return SwitchListTile(
          contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
          title: Text(tr('Mode sombre'), style: TextStyle(fontSize: 17)),
          value: dark,
          onChanged: (on) => settings.setThemeMode(on ? ThemeMode.dark : ThemeMode.light),
        );
      },
    );
  }
}

/// Notifications sur le téléphone : demande l'autorisation quand on les active.
class _NotificationsTile extends StatelessWidget {
  const _NotificationsTile({required this.settings});

  final SettingsController settings;

  Future<void> _toggle(BuildContext context, bool on) async {
    if (on && !await NotificationService.instance.requestPermission()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Autorise les notifications d\'EquiPay dans les réglages du téléphone.'.tr)),
        );
      }
      return;
    }
    settings.setNotifications(on);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => SwitchListTile(
        contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
        title: Text('Notifications'.tr, style: const TextStyle(fontSize: 17)),
        subtitle: Text('Demandes, dépenses ajoutées, rappels du budget'.tr),
        value: settings.notifications,
        onChanged: (on) => _toggle(context, on),
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) =>
          _Tile(title: tr('Langue'), value: settings.language.nativeName, onTap: () => _pick(context)),
    );
  }

  void _pick(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(tr('Langue'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              RadioGroup<AppLanguage>(
                groupValue: settings.language,
                onChanged: (lang) {
                  if (lang != null) settings.setLanguage(lang);
                  Navigator.pop(context);
                },
                child: Column(
                  children: [
                    for (final lang in AppLanguage.values)
                      RadioListTile<AppLanguage>(value: lang, title: Text(lang.nativeName)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ligne « libellé gris + valeur », centrée (infos du compte).
class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.value, required this.onTap});

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          children: [
            Text(label, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.title, required this.onTap, this.value, this.icon});

  final String title;
  final IconData? icon;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
      leading: icon == null ? null : Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title, style: const TextStyle(fontSize: 17)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null) Text(value!, style: TextStyle(fontSize: 16, color: muted)),
          Icon(Icons.chevron_right_rounded, color: muted),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Offre en cours, bien visible : invite à passer à l'offre supérieure, ou à gérer l'abonnement.
class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.plan});

  final Plan plan;

  @override
  Widget build(BuildContext context) {
    final next = plan.next;
    final gradient = plan.isPaid
        ? planGradient(plan)
        : LinearGradient(colors: [Plan.plus.color, Plan.pro.color, Plan.premium.color]);
    return Material(
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(gradient: gradient),
        child: InkWell(
          onTap: () => openPlans(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 24,
                  backgroundColor: Colors.white24,
                  child: Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('Offre {0}', [plan.label]),
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        plan.isPaid
                            ? tr('Gérer mon abonnement ou le résilier')
                            : tr('Passe à {0} dès {1} DH/mois : plus d\'IA et les statistiques', [
                                next!.label,
                                next.monthlyPrice,
                              ]),
                        style: const TextStyle(color: Colors.white, fontSize: 13.5),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Action en rouge centrée (déconnexion, suppression du compte).
class _CenteredAction extends StatelessWidget {
  const _CenteredAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            label,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 10),
      child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
    );
  }
}

/// Carte arrondie qui regroupe des lignes séparées par un trait fin.
class _Section extends StatelessWidget {
  const _Section({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 20, endIndent: 20),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Bulle « Support » flottante qui ouvre le chat avec l'assistant.
class _SupportButton extends StatelessWidget {
  const _SupportButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: tr('Support'),
      child: GestureDetector(
        onTap: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.primary,
                boxShadow: [
                  BoxShadow(color: colors.primary.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, 6)),
                ],
              ),
              child: Icon(Icons.chat_bubble_rounded, color: colors.onPrimary, size: 28),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: BorderRadius.circular(12)),
              child: Text(
                tr('Support'),
                style: TextStyle(fontWeight: FontWeight.w700, color: colors.onPrimaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// « G » aux couleurs de Google (sans image).
class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (rect) => const SweepGradient(
        colors: [Color(0xFF4285F4), Color(0xFF34A853), Color(0xFFFBBC05), Color(0xFFEA4335), Color(0xFF4285F4)],
      ).createShader(rect),
      child: Text(
        'G',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
      ),
    );
  }
}
