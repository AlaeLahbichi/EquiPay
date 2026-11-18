import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/user_profile.dart';
import '../../services/assistant_service.dart';
import '../../l10n/i18n.dart';

class _Message {
  const _Message(this.text, {required this.fromUser, this.failed = false});

  final String text;
  final bool fromUser;
  final bool failed;
}

/// Discussion avec l'assistant EquiPay (connexion facultative).
class SupportChatPage extends StatefulWidget {
  const SupportChatPage({super.key, required this.assistant, this.user});

  final AssistantService assistant;
  final UserProfile? user;

  static const suggestions = [
    'Comment créer une activité ?',
    'Comment rejoindre une activité avec un code ?',
    'Qui peut modifier une dépense ?',
    'Comment inviter un spectateur ?',
  ];

  @override
  State<SupportChatPage> createState() => _SupportChatPageState();
}

class _SupportChatPageState extends State<SupportChatPage> {
  final _messages = <_Message>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  var _waiting = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    final question = text.trim();
    if (question.isEmpty || _waiting) return;
    _input.clear();
    setState(() {
      _messages.add(_Message(question, fromUser: true));
      _waiting = true;
    });
    _scrollToEnd();
    _Message reply;
    try {
      reply = _Message(await widget.assistant.ask(question), fromUser: false);
    } catch (e) {
      reply = _Message(e.toString(), fromUser: false, failed: true);
    }
    if (!mounted) return;
    setState(() {
      _messages.add(reply);
      _waiting = false;
    });
    _scrollToEnd();
  }

  /// Renvoie la dernière question après une erreur.
  void _retry() {
    final last = _messages.lastWhere((m) => m.fromUser);
    setState(() {
      _messages
        ..removeLast() // l'erreur
        ..removeLast(); // la question, renvoyée ci-dessous
    });
    _send(last.text);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 0,
        title: Row(
          children: [
            const _AssistantAvatar(size: 38),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('Assistant EquiPay'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                Text(_waiting ? tr('écrit…') : tr('Support · en ligne'), style: TextStyle(fontSize: 12, color: colors.primary)),
              ],
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? _Welcome(name: widget.user?.displayName.split(' ').first, onPick: _send)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      itemCount: _messages.length + (_waiting ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i == _messages.length) return const _TypingBubble();
                        final m = _messages[i];
                        final isLast = i == _messages.length - 1;
                        return _Bubble(message: m, onRetry: m.failed && isLast ? _retry : null);
                      },
                    ),
            ),
            if (widget.user == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  tr('Connecte-toi pour garder l\'historique de tes conversations.'),
                  style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                ),
              ),
            _Composer(controller: _input, enabled: !_waiting, onSend: _send),
          ],
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.name, required this.onPick});

  final String? name;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
      children: [
        const Center(child: _AssistantAvatar(size: 84)),
        const SizedBox(height: 16),
        Text(
          name == null ? tr('Bonjour 👋') : tr('Bonjour {0} 👋', [name]),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          tr('Je suis l\'assistant EquiPay. Pose-moi une question sur l\'utilisation de l\'app.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in SupportChatPage.suggestions)
              ActionChip(
                label: Text(s.tr),
                onPressed: () => onPick(s.tr),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
          ],
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.onRetry});

  final _Message message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mine = message.fromUser;
    final background = mine
        ? colors.primary
        : message.failed
        ? colors.errorContainer
        : colors.surfaceContainerHighest;
    final foreground = mine
        ? colors.onPrimary
        : message.failed
        ? colors.onErrorContainer
        : colors.onSurface;

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 4),
          bottomRight: Radius.circular(mine ? 4 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(message.text, style: TextStyle(color: foreground, fontSize: 15, height: 1.35)),
          if (onRetry != null)
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(tr('Réessayer')),
              style: TextButton.styleFrom(foregroundColor: foreground, padding: EdgeInsets.zero),
            ),
        ],
      ),
    );

    // Apparition douce de chaque nouveau message
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      builder: (_, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 12 * (1 - t)), child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!mine) ...[const _AssistantAvatar(size: 28), const SizedBox(width: 6)],
            bubble,
          ],
        ),
      ),
    );
  }
}

/// Bulle « l'assistant écrit… » avec trois points animés.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const _AssistantAvatar(size: 28),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
              ),
            ),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (_, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2.5),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.onSurfaceVariant.withValues(
                          alpha: 0.3 + 0.7 * math.max(0, math.sin((_controller.value - i * 0.2) * 2 * math.pi)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.enabled, required this.onSend});

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onSend;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              onSubmitted: onSend,
              decoration: InputDecoration(
                hintText: tr('Écris ta question…'),
                counterText: '',
                filled: true,
                fillColor: colors.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ListenableBuilder(
            listenable: controller,
            builder: (_, _) => IconButton.filled(
              tooltip: tr('Envoyer'),
              iconSize: 22,
              style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: enabled && controller.text.trim().isNotEmpty ? () => onSend(controller.text) : null,
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.12),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Image.asset('assets/branding/logo.png'),
    );
  }
}
