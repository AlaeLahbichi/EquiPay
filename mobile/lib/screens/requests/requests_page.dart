import 'package:flutter/material.dart';

import '../../models/join_request.dart';
import '../../services/activity_repository.dart';
import '../../services/requests_controller.dart';
import '../../theme/app_colors.dart';
import '../../utils/time_ago.dart';
import '../../widgets/user_avatar.dart';
import '../../l10n/i18n.dart';

/// Onglet Requests : demandes reçues (à accepter / refuser) et demandes envoyées.
class RequestsPage extends StatelessWidget {
  const RequestsPage({super.key, required this.controller, required this.onSignInRequested});

  final RequestsController controller;
  final VoidCallback onSignInRequested;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.user == null) {
          return Scaffold(
            appBar: AppBar(
              title: Text(tr('Demandes'), style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            body: _Empty(
              icon: Icons.lock_outline_rounded,
              title: tr('Connecte-toi pour voir tes demandes'),
              subtitle: tr('Les demandes pour rejoindre tes activités apparaîtront ici.'),
              action: FilledButton(onPressed: onSignInRequested, child: Text(tr('Se connecter'))),
            ),
          );
        }
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: Text(tr('Demandes'), style: TextStyle(fontWeight: FontWeight.w700)),
              bottom: TabBar(
                tabs: [
                  Tab(child: _TabLabel(tr('Reçues'), count: controller.pendingIncoming)),
                  Tab(child: _TabLabel(tr('Envoyées'), count: controller.unseenOutgoing)),
                ],
              ),
            ),
            body: !controller.loaded
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    children: [
                      _RequestList(
                        controller: controller,
                        requests: controller.incoming,
                        empty: _Empty(
                          icon: Icons.inbox_rounded,
                          title: tr('Aucune demande reçue'),
                          subtitle:
                              tr('Partage le code de ton activité : chaque demande pour la '
                              'rejoindre arrivera ici.'),
                        ),
                        itemBuilder: (r) => _IncomingCard(request: r, controller: controller),
                      ),
                      _RequestList(
                        controller: controller,
                        requests: controller.outgoing,
                        empty: _Empty(
                          icon: Icons.send_rounded,
                          title: tr('Aucune demande envoyée'),
                          subtitle:
                              tr('Rejoins une activité avec son code depuis l\'accueil : '
                              'tu suivras la réponse ici.'),
                        ),
                        itemBuilder: (r) => _OutgoingCard(request: r, controller: controller),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel(this.text, {required this.count});

  final String text;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text),
        if (count > 0) ...[const SizedBox(width: 6), Badge(label: Text('$count'), backgroundColor: AppColors.accent)],
      ],
    );
  }
}

class _RequestList extends StatelessWidget {
  const _RequestList({
    required this.controller,
    required this.requests,
    required this.empty,
    required this.itemBuilder,
  });

  final RequestsController controller;
  final List<JoinRequest> requests;
  final Widget empty;
  final Widget Function(JoinRequest) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: requests.isEmpty
          ? LayoutBuilder(
              // Défilable pour permettre le « tirer pour actualiser » même vide
              builder: (_, box) => SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: SizedBox(height: box.maxHeight, child: empty),
              ),
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              itemCount: requests.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _Appear(key: ValueKey(requests[i].id), child: itemBuilder(requests[i])),
            ),
    );
  }
}

/// Demande reçue : qui veut rejoindre quelle activité, avec Accepter / Refuser.
class _IncomingCard extends StatefulWidget {
  const _IncomingCard({required this.request, required this.controller});

  final JoinRequest request;
  final RequestsController controller;

  @override
  State<_IncomingCard> createState() => _IncomingCardState();
}

class _IncomingCardState extends State<_IncomingCard> {
  bool? _busyAccept; // true : acceptation en cours, false : refus en cours

  Future<void> _respond(bool accept) async {
    final messenger = ScaffoldMessenger.of(context);
    final r = widget.request;
    setState(() => _busyAccept = accept);
    try {
      await widget.controller.respond(r, accept: accept);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            accept
                ? tr('{0} a rejoint « {1} »', [r.requester.displayName, r.activityName])
                : tr('Demande de {0} refusée', [r.requester.displayName]),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busyAccept = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final colors = Theme.of(context).colorScheme;
    final busy = _busyAccept != null;
    return _CardShell(
      highlighted: r.isPending,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              UserAvatar(user: r.requester, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: r.requester.displayName,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: tr(' veut rejoindre ')),
                          TextSpan(
                            text: r.activityName,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      style: const TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [if (r.requester.username != null) '@${r.requester.username}', timeAgo(r.createdAt)].join(' · '),
                      style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: r.isPending
                ? Row(
                    key: const ValueKey('actions'),
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: busy ? null : () => _respond(false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.error,
                            minimumSize: const Size.fromHeight(44),
                          ),
                          child: _busyAccept == false ? const _Spinner() : Text(tr('Refuser')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: busy ? null : () => _respond(true),
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                          child: _busyAccept == true ? const _Spinner() : Text(tr('Accepter')),
                        ),
                      ),
                    ],
                  )
                : Align(
                    key: const ValueKey('status'),
                    alignment: Alignment.centerLeft,
                    child: _StatusChip(r.status, decidedAt: r.decidedAt),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Demande envoyée : activité visée, statut, et annulation tant qu'elle est en attente.
class _OutgoingCard extends StatefulWidget {
  const _OutgoingCard({required this.request, required this.controller});

  final JoinRequest request;
  final RequestsController controller;

  @override
  State<_OutgoingCard> createState() => _OutgoingCardState();
}

class _OutgoingCardState extends State<_OutgoingCard> {
  var _busy = false;

  Future<void> _cancel() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.controller.cancel(widget.request);
      messenger.showSnackBar(SnackBar(content: Text(tr('Demande annulée'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final colors = Theme.of(context).colorScheme;
    final cover = r.activityCover;
    return _CardShell(
      highlighted: !r.seenByRequester,
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: colors.primary.withValues(alpha: 0.12),
            foregroundImage: cover != null ? NetworkImage(cover) : null,
            child: Icon(Icons.groups_rounded, color: colors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.activityName,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(tr('Envoyée {0}', [timeAgo(r.createdAt)]), style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant)),
                const SizedBox(height: 8),
                _StatusChip(r.status, decidedAt: r.decidedAt),
              ],
            ),
          ),
          if (r.isPending)
            TextButton(onPressed: _busy ? null : _cancel, child: _busy ? const _Spinner() : Text(tr('Annuler'))),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status, {this.decidedAt});

  final JoinRequestStatus status;
  final DateTime? decidedAt;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch (status) {
      JoinRequestStatus.pending => (tr('En attente'), Icons.schedule_rounded, AppColors.credit),
      JoinRequestStatus.accepted => (tr('Acceptée'), Icons.check_circle_rounded, AppColors.positive),
      JoinRequestStatus.rejected => (tr('Refusée'), Icons.cancel_rounded, AppColors.negative),
      JoinRequestStatus.cancelled => (tr('Annulée'), Icons.block_rounded, AppColors.neutral),
    };
    final when = decidedAt == null ? '' : ' ${timeAgo(decidedAt!)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 5),
          Text(
            '$label$when',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({required this.child, required this.highlighted});

  final Widget child;

  /// Bordure colorée : demande à traiter ou réponse pas encore vue.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: highlighted ? colors.primary.withValues(alpha: 0.5) : colors.outlineVariant.withValues(alpha: 0.4),
          width: highlighted ? 1.5 : 1,
        ),
      ),
      child: child,
    );
  }
}

/// Apparition douce d'une nouvelle carte.
class _Appear extends StatelessWidget {
  const _Appear({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (_, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.subtitle, this.action});

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: colors.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: colors.primary),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
