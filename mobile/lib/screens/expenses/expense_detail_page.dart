import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/activity.dart';
import '../../models/activity_overview.dart';
import '../../models/expense.dart';
import '../../models/user_profile.dart';
import '../../services/activity_repository.dart';
import '../../services/expense_repository.dart';
import '../../theme/app_colors.dart';
import '../../utils/dates.dart';
import '../../utils/money.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/user_avatar.dart';
import 'expense_form_page.dart';
import '../../l10n/i18n.dart';

/// Détail d'une dépense : montant, payeur, date, lieu, répartition et photo du reçu.
class ExpenseDetailPage extends StatefulWidget {
  const ExpenseDetailPage({
    super.key,
    required this.activity,
    required this.expense,
    required this.members,
    required this.currentUserId,
    required this.expenses,
    required this.activities,
  });

  final Activity activity;

  /// Affichée tout de suite, puis rechargée avec sa photo.
  final Expense expense;
  final List<MemberSummary> members;
  final String? currentUserId;
  final ExpenseRepository expenses;
  final ActivityRepository activities;

  @override
  State<ExpenseDetailPage> createState() => _ExpenseDetailPageState();
}

class _ExpenseDetailPageState extends State<ExpenseDetailPage> {
  late Expense _expense = widget.expense;
  Photo? _photo;
  var _photoLoaded = false;
  var _deleting = false;
  StreamSubscription<void>? _changes;

  late final Map<String, UserProfile> _profiles = {for (final m in widget.members) m.profile.id: m.profile};

  bool get _mine => _expense.createdBy == widget.currentUserId;

  @override
  void initState() {
    super.initState();
    _load();
    _changes = widget.activities.activityChanges(widget.activity.id).listen((_) => _load());
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await widget.expenses.expense(_expense.id);
      if (!mounted) return;
      if (result == null) {
        // Supprimée (par exemple depuis un autre téléphone)
        if (!_deleting) Navigator.pop(context);
        return;
      }
      setState(() {
        _expense = result.$1;
        _photo = result.$2;
        _photoLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _photoLoaded = true);
    }
  }

  String _name(String userId) {
    final profile = _profiles[userId];
    final name = profile?.displayName ?? tr('Ancien membre');
    return userId == widget.currentUserId ? '$name (toi)' : name;
  }

  Future<void> _edit() async {
    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ExpenseFormPage(
          activity: widget.activity,
          members: widget.members,
          currentUserId: widget.currentUserId!,
          repository: widget.expenses,
          expense: _expense,
          photo: _photo,
        ),
      ),
    );
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _load();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Supprimer « {0} » ?', [_expense.name])),
        content: Text(tr('Les soldes de tous les membres seront recalculés. Cette action est définitive.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annuler'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.negative),
            child: Text(tr('Supprimer')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.expenses.delete(_expense);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text(tr('Dépense supprimée'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  void _viewPhoto() {
    final photo = _photo!;
    openPhotoViewer(
      context,
      photos: [
        ViewerPhoto(image: NetworkImage(photo.url), heroTag: 'expense-photo-${photo.id}', caption: _expense.name),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = _expense;
    final colors = Theme.of(context).colorScheme;
    final foreign = e.currency != widget.activity.currency;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Dépense')),
        actions: [
          if (_mine) ...[
            IconButton(
              tooltip: tr('Modifier la dépense'),
              onPressed: _deleting ? null : _edit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: tr('Supprimer la dépense'),
              onPressed: _deleting ? null : _delete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.primary, Color(0xFF14B8A6)],
                ),
              ),
              child: Column(
                children: [
                  Text(
                    e.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    formatMoney(e.amount, e.currency),
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                  if (foreign)
                    Text(
                      tr('soit {0} '
                      '(1 {1} = {2} {3})', [formatMoney(e.convertedAmount, widget.activity.currency), e.currency, e.exchangeRate.toString().replaceAll('.', ','), widget.activity.currency]),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  const SizedBox(height: 4),
                  Text(formatDate(e.date), style: const TextStyle(color: Colors.white70)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _InfoCard(
              children: [
                _InfoRow(
                  icon: Icons.account_balance_wallet_outlined,
                  label: tr('Payé par'),
                  value: _name(e.paidBy),
                  leading: UserAvatar(user: _profiles[e.paidBy], size: 28),
                ),
                _InfoRow(icon: Icons.event_outlined, label: tr('Date'), value: formatDate(e.date)),
                if (e.place != null) _InfoRow(icon: Icons.place_outlined, label: tr('Lieu'), value: e.place!),
                if (e.description != null && e.description!.isNotEmpty)
                  _InfoRow(icon: Icons.notes_rounded, label: tr('Description'), value: e.description!),
                _InfoRow(icon: Icons.person_add_alt_outlined, label: tr('Ajoutée par'), value: _name(e.createdBy)),
              ],
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(
                tr('Répartition ({0})', [e.shares.length]),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            _InfoCard(
              children: [
                for (final s in [...e.shares]..sort((a, b) => b.percentage.compareTo(a.percentage)))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        UserAvatar(user: _profiles[s.userId], size: 40),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _name(s.userId),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${s.percentage.toStringAsFixed(s.percentage % 1 == 0 ? 0 : 2).replaceAll('.', ',')} %',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: colors.primary),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          formatMoney(e.amount * s.percentage / 100, e.currency),
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Padding(
              padding: EdgeInsets.only(left: 4, bottom: 10),
              child: Text(tr('Photo du reçu'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            if (!_photoLoaded)
              const Center(
                child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
              )
            else if (_photo == null)
              Text(
                _mine ? tr('Aucune photo. Ajoute-la avec le crayon en haut.') : tr('Aucune photo pour cette dépense.'),
                style: TextStyle(color: colors.onSurfaceVariant),
              )
            else
              GestureDetector(
                onTap: _viewPhoto,
                child: Hero(
                  tag: 'expense-photo-${_photo!.id}',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Image.network(
                        _photo!.url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: colors.surfaceContainerHighest,
                          child: const Center(child: Icon(Icons.broken_image_outlined, size: 40)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value, this.leading});

  final IconData icon;
  final String label;
  final String value;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 12),
          SizedBox(
            width: 92,
            child: Text(label, style: TextStyle(color: colors.onSurfaceVariant)),
          ),
          if (leading != null) ...[leading!, const SizedBox(width: 8)],
          Expanded(
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
