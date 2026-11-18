import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/activity.dart';
import '../../models/trip_item.dart';
import '../../services/activity_repository.dart';
import '../../services/place_geocoder.dart';
import '../../services/trip_repository.dart';
import '../../theme/app_colors.dart';
import '../../utils/dates.dart';
import '../../utils/reloader.dart';
import '../../widgets/apple_map.dart';
import '../../widgets/logo_loader.dart';
import 'trip_route_page.dart';
import '../../l10n/i18n.dart';

/// Les voyages et les sorties ont un programme ; les autres types d'activité non.
bool hasProgram(Activity activity) => activity.type == ActivityType.voyage || activity.type == ActivityType.sortie;

enum _View { list, calendar, map }

enum _Sort {
  date('Par date', Icons.event_rounded),
  votes('Les plus votées', Icons.thumb_up_alt_outlined);

  const _Sort(this._label, this.icon);

  final String _label;

  String get label => _label.tr;
  final IconData icon;
}

/// Programme d'un voyage ou d'une sortie : les activités à faire, le vote pour / contre de chacun
/// et la carte des lieux.
class TripPlanPage extends StatefulWidget {
  const TripPlanPage({super.key, required this.activity, this.currentUserId});

  final Activity activity;
  final String? currentUserId;

  @override
  State<TripPlanPage> createState() => _TripPlanPageState();
}

class _TripPlanPageState extends State<TripPlanPage> {
  TripRepository get _repo => TripRepository.instance;

  List<TripItem>? _items;
  String? _error;
  var _view = _View.list;
  var _sort = _Sort.date;
  StreamSubscription<void>? _changes;
  late final _reloader = Reloader(_fetch);

  /// Éléments déjà cherchés sur la carte pendant cette visite (pour ne pas recommencer à chaque rechargement).
  final _locateTried = <String>{};

  bool get _isOwner => widget.activity.role == MemberRole.owner;

  /// Les spectateurs voient le programme sans ajouter ni voter.
  bool get _canEdit => widget.activity.role != MemberRole.viewer;

  bool _canManage(TripItem item) => _isOwner || item.createdBy == widget.currentUserId;

  @override
  void initState() {
    super.initState();
    _reloader.now();
    _changes = _repo.changes(widget.activity.id).listen((_) => _reloader.schedule());
  }

  @override
  void dispose() {
    _changes?.cancel();
    _reloader.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final items = await _repo.items(widget.activity.id);
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
      unawaited(_locateMissing(items));
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  /// Éléments ajoutés sans position (lieu introuvable, ou ajoutés avant la recherche Apple Plans) :
  /// on cherche leur lieu automatiquement pour les placer sur la carte.
  Future<void> _locateMissing(List<TripItem> items) async {
    var placed = 0;
    for (final item in items) {
      if (item.hasPosition || !_canManage(item) || !_locateTried.add(item.id)) continue;
      final position = await PlaceGeocoder.instance.locate(place: item.place, address: item.address);
      if (position == null) continue;
      try {
        await _repo.setPosition(item, position.$1, position.$2);
        placed++;
      } catch (_) {
        // Réessayé à la prochaine ouverture du programme
      }
    }
    if (placed > 0 && mounted) {
      _toast(placed == 1 ? tr('1 lieu placé sur la carte') : tr('{0} lieux placés sur la carte', [placed]));
      await _reloader.now();
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Exécute une action ; en cas d'erreur, recharge et prévient.
  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _toast(friendlyError(e));
    }
    await _reloader.now();
  }

  List<TripItem> get _sorted {
    final items = [...?_items];
    if (_sort == _Sort.votes) {
      items.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : b.upVotes.compareTo(a.upVotes);
      });
    }
    if (_sort == _Sort.date) items.sort(compareByDateTime);
    return items;
  }

  Future<void> _edit([TripItem? item]) async {
    final draft = await showTripItemForm(context, item: item);
    if (draft == null || !mounted) return;
    // Position pour la carte : recherchée seulement si le lieu ou l'adresse a changé
    final moved = item == null || item.place != draft.place || item.address != draft.address;
    final position = draft.latitude != null
        ? (draft.latitude!, draft.longitude!) // lieu choisi dans les suggestions
        : moved || !item.hasPosition
        ? await PlaceGeocoder.instance.locate(place: draft.place, address: draft.address)
        : (item.latitude!, item.longitude!);
    final located = draft.withPosition(position);
    await _run(() => item == null ? _repo.add(widget.activity.id, located) : _repo.update(item, located));
    if (!mounted) return;
    final hadPlace = PlaceGeocoder.query(place: draft.place, address: draft.address) != null;
    _toast(
      hadPlace && position == null
          ? tr('Enregistré. Lieu introuvable : il n\'apparaîtra pas sur la carte.')
          : item == null
          ? tr('Ajouté au programme')
          : tr('Modifié'),
    );
  }

  /// Trajet proposé par l'IA : options, puis page du résultat ; « Appliquer » met à jour le programme.
  Future<void> _organize() async {
    final options = await showTripOptions(context);
    if (options == null || !mounted) return;
    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TripRoutePage(activity: widget.activity, items: _items!, options: options),
      ),
    );
    if (applied == true && mounted) {
      _toast(tr('Programme mis à jour'));
      await _reloader.now();
    }
  }

  Future<void> _delete(TripItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Supprimer « {0} » ?', [item.name])),
        content: Text(tr('L\'élément et ses votes seront supprimés pour tout le monde.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annuler'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Supprimer'))),
        ],
      ),
    );
    if (ok == true) await _run(() => _repo.delete(item));
  }

  /// Vote immédiat à l'écran, puis envoi au serveur. Toucher à nouveau son vote l'annule.
  Future<void> _vote(TripItem item, int value) async {
    final next = item.myVote == value ? 0 : value;
    int count(int vote, int target) => vote == target ? 1 : 0;
    final updated = item.copyWith(
      myVote: next,
      upVotes: item.upVotes - count(item.myVote, 1) + count(next, 1),
      downVotes: item.downVotes - count(item.myVote, -1) + count(next, -1),
    );
    setState(() => _items = [for (final i in _items!) i.id == item.id ? updated : i]);
    await _run(() => _repo.vote(item, next));
  }

  Future<void> _setDone(TripItem item, bool done) async {
    setState(() => _items = [for (final i in _items!) i.id == item.id ? i.copyWith(done: done) : i]);
    await _run(() => _repo.setDone(item, done));
  }

  Widget _card(TripItem item) => TripItemCard(
    item: item,
    canVote: _canEdit,
    canManage: _canManage(item),
    onVote: (v) => _vote(item, v),
    onDone: (d) => _setDone(item, d),
    onEdit: () => _edit(item),
    onDelete: () => _delete(item),
  );

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Programme · {0}', [widget.activity.name]))),
      floatingActionButton: _canEdit && items != null
          ? FloatingActionButton.extended(
              onPressed: _edit,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: Text(tr('Ajouter')),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SegmentedButton<_View>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: _View.list, icon: Icon(Icons.checklist_rounded), label: Text(tr('Liste'))),
                ButtonSegment(
                  value: _View.calendar,
                  icon: Icon(Icons.calendar_month_rounded),
                  label: Text(tr('Calendrier')),
                ),
                ButtonSegment(value: _View.map, icon: Icon(Icons.map_outlined), label: Text(tr('Carte'))),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
          ),
          if ((items ?? const []).where((i) => i.hasPosition && !i.done).length >= 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: _organize,
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: Text(tr('Organiser le trajet')),
                ),
              ),
            ),
          Expanded(
            child: switch ((items, _error)) {
              (null, final String error) => _Message(
                icon: Icons.wifi_off_rounded,
                text: error,
                action: FilledButton.tonal(onPressed: _reloader.now, child: Text(tr('Réessayer'))),
              ),
              (null, _) => Center(child: LogoLoader(logoSize: 72, message: tr('Chargement du programme…'))),
              (final List<TripItem> list, _) when list.isEmpty => _Message(
                icon: Icons.luggage_outlined,
                text: _canEdit
                    ? tr('Rien de prévu pour le moment.\nAjoute les visites et sorties, puis votez ensemble !')
                    : tr('Rien de prévu pour le moment.'),
              ),
              (final List<TripItem> list, _) => switch (_view) {
                _View.map => TripMap(items: list, onOpen: _openFromMap),
                _View.calendar => TripCalendar(items: list, cardBuilder: _card),
                _View.list => _list(),
              },
            },
          ),
        ],
      ),
    );
  }

  Widget _list() {
    final items = _sorted;
    final children = <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          children: [
            for (final s in _Sort.values)
              ChoiceChip(
                avatar: Icon(s.icon, size: 18),
                label: Text(s.label),
                selected: _sort == s,
                onSelected: (_) => setState(() => _sort = s),
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
    ];
    String? lastDay;
    for (final item in items) {
      if (_sort == _Sort.date) {
        final day = item.date == null ? tr('Sans date') : _dayLabel(item.date!);
        if (day != lastDay) {
          children.add(_DayHeader(label: day));
          lastDay = day;
        }
      }
      children.add(Padding(padding: const EdgeInsets.only(bottom: 10), child: _card(item)));
    }
    return RefreshIndicator(
      onRefresh: _reloader.now,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        children: children,
      ),
    );
  }

  void _openFromMap(TripItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        // Les votes faits ici mettent à jour la fiche ouverte
        child: StatefulBuilder(
          builder: (context, setSheet) {
            final current = _items?.firstWhere((i) => i.id == item.id, orElse: () => item) ?? item;
            return TripItemCard(
              item: current,
              canVote: _canEdit,
              canManage: _canManage(current),
              onVote: (v) async {
                final pending = _vote(current, v);
                setSheet(() {});
                await pending;
                if (sheetContext.mounted) setSheet(() {});
              },
              onDone: (d) async {
                final pending = _setDone(current, d);
                setSheet(() {});
                await pending;
              },
              onEdit: () {
                Navigator.pop(sheetContext);
                _edit(current);
              },
              onDelete: () {
                Navigator.pop(sheetContext);
                _delete(current);
              },
            );
          },
        ),
      ),
    );
  }
}


String _dayLabel(DateTime d) => '${weekdayName(d, short: true)} ${formatDate(d)}';

String _timeLabel(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}h${t.minute.toString().padLeft(2, '0')}';

/// Couleur d'un élément selon les votes : vert si plus de pour, rouge si plus de contre.
Color tripVoteColor(TripItem item) => item.score > 0
    ? AppColors.positive
    : item.score < 0
    ? AppColors.negative
    : AppColors.neutral;

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
    child: Text(
      label,
      style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: colors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              text,
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

/// Fiche d'un élément du programme : nom, lieu, adresse, date, votes.
class TripItemCard extends StatelessWidget {
  const TripItemCard({
    super.key,
    required this.item,
    required this.canVote,
    required this.canManage,
    required this.onVote,
    required this.onDone,
    required this.onEdit,
    required this.onDelete,
  });

  final TripItem item;
  final bool canVote;
  final bool canManage;
  final ValueChanged<int> onVote;
  final ValueChanged<bool> onDone;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final details = [
      if (item.place case final place?) (Icons.place_outlined, place),
      if (item.address case final address?) (Icons.signpost_outlined, address),
      if (item.date != null || item.time != null)
        (
          Icons.schedule_rounded,
          [if (item.date != null) _dayLabel(item.date!), if (item.time != null) _timeLabel(item.time!)].join(' · '),
        ),
    ];
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: tripVoteColor(item).withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(value: item.done, onChanged: canManage ? (v) => onDone(v ?? false) : null),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            decoration: item.done ? TextDecoration.lineThrough : null,
                            color: item.done ? colors.onSurfaceVariant : null,
                          ),
                        ),
                        for (final (icon, text) in details)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(icon, size: 16, color: colors.onSurfaceVariant),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(text, style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant)),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (canManage)
                  PopupMenuButton<bool>(
                    tooltip: tr('Modifier ou supprimer'),
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (edit) => edit ? onEdit() : onDelete(),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: true, child: Text(tr('Modifier'))),
                      PopupMenuItem(value: false, child: Text(tr('Supprimer'))),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 48),
              child: Row(
                children: [
                  _VoteButton(
                    icon: Icons.thumb_up_alt_rounded,
                    tooltip: tr('Pour'),
                    count: item.upVotes,
                    color: AppColors.positive,
                    selected: item.myVote == 1,
                    onPressed: canVote ? () => onVote(1) : null,
                  ),
                  const SizedBox(width: 8),
                  _VoteButton(
                    icon: Icons.thumb_down_alt_rounded,
                    tooltip: tr('Contre'),
                    count: item.downVotes,
                    color: AppColors.negative,
                    selected: item.myVote == -1,
                    onPressed: canVote ? () => onVote(-1) : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoteButton extends StatelessWidget {
  const _VoteButton({
    required this.icon,
    required this.tooltip,
    required this.count,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final int count;
  final Color color;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18, color: selected ? Colors.white : color),
        label: Text(
          '$count',
          style: TextStyle(fontWeight: FontWeight.w700, color: selected ? Colors.white : color),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? color : null,
          side: BorderSide(color: color.withValues(alpha: 0.6)),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
      ),
    );
  }
}

/// Ordre chronologique : jour puis heure ; sans heure en fin de journée, sans date à la fin.
int compareByDateTime(TripItem a, TripItem b) {
  if (a.date != b.date) {
    if (a.date == null) return 1;
    if (b.date == null) return -1;
    return a.date!.compareTo(b.date!);
  }
  final ta = a.time, tb = b.time;
  if (ta == tb) return 0;
  if (ta == null) return 1;
  if (tb == null) return -1;
  return (ta.hour * 60 + ta.minute).compareTo(tb.hour * 60 + tb.minute);
}

/// Jours du programme, dans l'ordre (sans les éléments non datés).
List<DateTime> tripDays(List<TripItem> items) {
  final days = {
    for (final i in items)
      if (i.date != null) DateTime(i.date!.year, i.date!.month, i.date!.day),
  }.toList()..sort();
  return days;
}

bool _sameDay(DateTime? a, DateTime? b) =>
    a != null && b != null && a.year == b.year && a.month == b.month && a.day == b.day;

/// Filtre par jour : null = tous, [_undated] = sans date, sinon le jour choisi.
final _undated = DateTime(0);

bool _matchesDay(TripItem item, DateTime? day) =>
    day == null || (identical(day, _undated) ? item.date == null : _sameDay(item.date, day));

String _shortDay(DateTime d) => formatShortDay(d);

/// Bande de jours (Tous, chaque date, Sans date) au-dessus du calendrier et de la carte.
class _DayFilter extends StatelessWidget {
  const _DayFilter({required this.items, required this.selected, required this.onSelected, this.showAll = true});

  final List<TripItem> items;
  final DateTime? selected;
  final ValueChanged<DateTime?> onSelected;
  final bool showAll;

  @override
  Widget build(BuildContext context) {
    final days = tripDays(items);
    final undated = items.where((i) => i.date == null).length;
    Widget chip(String label, DateTime? value, int count) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text('$label · $count'),
        selected: value == null
            ? selected == null
            : (identical(value, _undated) ? identical(selected, _undated) : _sameDay(selected, value)),
        onSelected: (_) => onSelected(value),
      ),
    );
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          if (showAll) chip(tr('Tous'), null, items.length),
          for (final d in days) chip(_shortDay(d), d, items.where((i) => _sameDay(i.date, d)).length),
          if (undated > 0) chip(tr('Sans date'), _undated, undated),
        ],
      ),
    );
  }
}

/// Calendrier du programme : un jour à la fois, les activités dans l'ordre des heures.
class TripCalendar extends StatefulWidget {
  const TripCalendar({super.key, required this.items, required this.cardBuilder});

  final List<TripItem> items;
  final Widget Function(TripItem) cardBuilder;

  @override
  State<TripCalendar> createState() => _TripCalendarState();
}

class _TripCalendarState extends State<TripCalendar> {
  DateTime? _day;

  /// Jour affiché : celui choisi, sinon aujourd'hui ou le prochain jour prévu, sinon le premier.
  DateTime _current() {
    final days = tripDays(widget.items);
    final chosen = _day;
    if (chosen != null && (identical(chosen, _undated) || days.any((d) => _sameDay(d, chosen)))) return chosen;
    if (days.isEmpty) return _undated;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return days.firstWhere((d) => !d.isBefore(today), orElse: () => days.first);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final day = _current();
    final items = [
      for (final i in widget.items)
        if (_matchesDay(i, day)) i,
    ]..sort(compareByDateTime);
    return Column(
      children: [
        _DayFilter(items: widget.items, selected: day, showAll: false, onSelected: (d) => setState(() => _day = d)),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              identical(day, _undated) ? tr('Sans date') : _dayLabel(day),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: colors.primary),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 16, 96),
            children: [
              for (final item in items)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Colonne des heures, reliée par une ligne
                      SizedBox(
                        width: 58,
                        child: Column(
                          children: [
                            const SizedBox(height: 14),
                            Text(
                              item.time == null ? 'libre' : _timeLabel(item.time!),
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: item.time == null ? colors.onSurfaceVariant : colors.onSurface,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(color: tripVoteColor(item), shape: BoxShape.circle),
                            ),
                            Expanded(child: Container(width: 2, color: colors.outlineVariant)),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(padding: const EdgeInsets.only(bottom: 10), child: widget.cardBuilder(item)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Carte des lieux du programme (Apple Plans sur iPhone, OpenStreetMap ailleurs) : un repère numéroté par lieu, dans l'ordre chronologique,
/// coloré selon les votes. Filtrable par jour.
class TripMap extends StatefulWidget {
  const TripMap({super.key, required this.items, required this.onOpen});

  final List<TripItem> items;
  final ValueChanged<TripItem> onOpen;

  @override
  State<TripMap> createState() => _TripMapState();
}

class _TripMapState extends State<TripMap> {
  /// null : tous les jours.
  DateTime? _day;

  @override
  Widget build(BuildContext context) {
    final day = _day;
    final shown = [
      for (final i in widget.items)
        if (_matchesDay(i, day)) i,
    ]..sort(compareByDateTime);
    final placed = [
      for (final i in shown)
        if (i.hasPosition) i,
    ];
    final missing = shown.length - placed.length;
    final points = [for (final i in placed) LatLng(i.latitude!, i.longitude!)];
    return Column(
      children: [
        _DayFilter(items: widget.items, selected: day, onSelected: (d) => setState(() => _day = d)),
        Expanded(
          child: placed.isEmpty
              ? _Message(
                  icon: Icons.location_off_outlined,
                  text: day == null
                      ? tr('Aucun lieu à afficher.\nAjoute une adresse aux éléments du programme pour les voir sur la carte.')
                      : tr('Aucun lieu à afficher pour ce jour.'),
                )
              : Stack(
                  children: [
                    if (appleMapsAvailable)
                      // iPhone : carte Apple Plans native, bulles numérotées de l'app Plans
                      AppleMap(
                        pins: [
                          for (var i = 0; i < placed.length; i++)
                            MapPin(
                              id: placed[i].id,
                              latitude: placed[i].latitude!,
                              longitude: placed[i].longitude!,
                              label: '${i + 1}',
                              color: tripVoteColor(placed[i]),
                              title: placed[i].name,
                              subtitle: placed[i].place,
                              faded: placed[i].done,
                            ),
                        ],
                        onTap: (id) => widget.onOpen(placed.firstWhere((p) => p.id == id)),
                      )
                    else
                      // Android et tests : carte OpenStreetMap
                      FlutterMap(
                        // Nouveau filtre : la carte se recentre sur les lieux affichés
                        key: ValueKey(day),
                        options: MapOptions(
                          initialCenter: points.first,
                          initialZoom: 14,
                          initialCameraFit: points.length > 1
                              ? CameraFit.coordinates(
                                  coordinates: points,
                                  padding: const EdgeInsets.all(56),
                                  maxZoom: 16,
                                )
                              : null,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.emsi.mobileApp',
                          ),
                          MarkerLayer(
                            markers: [
                              for (var i = 0; i < placed.length; i++)
                                Marker(
                                  point: points[i],
                                  width: 40,
                                  height: 40,
                                  child: GestureDetector(
                                    onTap: () => widget.onOpen(placed[i]),
                                    child: _Pin(number: i + 1, color: tripVoteColor(placed[i]), faded: placed[i].done),
                                  ),
                                ),
                            ],
                          ),
                          SimpleAttributionWidget(source: Text(tr('OpenStreetMap'))),
                        ],
                      ),
                    if (missing > 0)
                      Positioned(
                        left: 12,
                        right: 12,
                        top: 8,
                        child: Material(
                          borderRadius: BorderRadius.circular(12),
                          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Text(
                              missing == 1
                                  ? tr('1 élément sans lieu trouvé n\'est pas affiché')
                                  : tr('{0} éléments sans lieu trouvé ne sont pas affichés', [missing]),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.number, required this.color, required this.faded});

  final int number;
  final Color color;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: faded ? 0.5 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        alignment: Alignment.center,
        child: Text(
          '$number',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

/// Formulaire d'ajout ou de modification d'un élément du programme.
Future<TripItemDraft?> showTripItemForm(BuildContext context, {TripItem? item}) => showModalBottomSheet<TripItemDraft>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _TripItemForm(item: item),
);

class _TripItemForm extends StatefulWidget {
  const _TripItemForm({this.item});

  final TripItem? item;

  @override
  State<_TripItemForm> createState() => _TripItemFormState();
}

class _TripItemFormState extends State<_TripItemForm> {
  late final _name = TextEditingController(text: widget.item?.name);
  late final _place = TextEditingController(text: widget.item?.place);
  late final _address = TextEditingController(text: widget.item?.address);
  late DateTime? _date = widget.item?.date;
  late TimeOfDay? _time = widget.item?.time;
  final _form = GlobalKey<FormState>();

  /// Suggestions d'Apple Plans pour le champ « Lieu », et le lieu choisi (position exacte).
  List<PlaceSuggestion> _suggestions = const [];
  PlaceSuggestion? _picked;
  Timer? _searchDelay;
  var _searchId = 0;

  void _onPlaceChanged(String text) {
    _picked = null;
    _searchDelay?.cancel();
    if (text.trim().length < 2) {
      setState(() => _suggestions = const []);
      return;
    }
    // On attend une courte pause dans la frappe avant de chercher
    _searchDelay = Timer(const Duration(milliseconds: 400), () async {
      final id = ++_searchId;
      final found = await PlaceGeocoder.instance.search(text);
      if (mounted && id == _searchId) setState(() => _suggestions = found);
    });
  }

  void _pick(PlaceSuggestion place) {
    setState(() {
      _picked = place;
      _suggestions = const [];
      _place.text = place.name;
      _address.text = place.address;
      if (_name.text.trim().isEmpty) _name.text = place.name;
    });
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    _searchDelay?.cancel();
    _name.dispose();
    _place.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      helpText: tr('Jour prévu'),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 10, minute: 0),
      helpText: tr('Heure prévue'),
    );
    if (picked != null) setState(() => _time = picked);
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final draft = TripItemDraft(name: _name.text, place: _place.text, address: _address.text, date: _date, time: _time);
    final picked = _picked;
    Navigator.pop(context, picked == null ? draft : draft.withPosition((picked.latitude, picked.longitude)));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.item != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                editing ? tr('Modifier l\'élément') : tr('Ajouter au programme'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                autofocus: !editing,
                maxLength: 120,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: tr('Nom'), hintText: tr('Ex. Visite du Jardin Majorelle')),
                validator: (v) => (v ?? '').trim().isEmpty ? tr('Donne un nom à cette activité') : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _place,
                maxLength: 120,
                textCapitalization: TextCapitalization.words,
                onChanged: _onPlaceChanged,
                decoration: InputDecoration(
                  labelText: tr('Lieu'),
                  hintText: tr('Ex. Jardin Majorelle'),
                  helperText: _picked != null ? tr('Lieu trouvé : il sera placé sur la carte') : null,
                  suffixIcon: _picked != null
                      ? const Icon(Icons.check_circle_rounded, color: AppColors.positive)
                      : null,
                ),
              ),
              for (final s in _suggestions)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: const Icon(Icons.place_rounded),
                  title: Text(s.name),
                  subtitle: Text(s.address, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => _pick(s),
                ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _address,
                maxLength: 300,
                onChanged: (_) => setState(() => _picked = null),
                decoration: InputDecoration(
                  labelText: tr('Adresse'),
                  hintText: tr('Ex. Rue Yves Saint Laurent, Marrakech'),
                  helperText: tr('Le lieu et l\'adresse servent à le placer sur la carte'),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.event_rounded),
                      label: Text(_date == null ? tr('Date') : formatDate(_date!)),
                    ),
                  ),
                  if (_date != null)
                    IconButton(
                      tooltip: tr('Retirer la date'),
                      onPressed: () => setState(() => _date = null),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule_rounded),
                      label: Text(_time == null ? tr('Heure') : _timeLabel(_time!)),
                    ),
                  ),
                  if (_time != null)
                    IconButton(
                      tooltip: tr('Retirer l\'heure'),
                      onPressed: () => setState(() => _time = null),
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton(onPressed: _save, child: Text(editing ? tr('Enregistrer') : tr('Ajouter'))),
            ],
          ),
        ),
      ),
    );
  }
}
