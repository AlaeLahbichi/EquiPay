import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/plan.dart';
import '../../models/activity.dart';
import '../../models/trip_item.dart';
import '../../services/activity_repository.dart';
import '../../services/trip_planner.dart';
import '../../services/trip_repository.dart';
import '../../theme/app_colors.dart';
import '../../utils/dates.dart';
import '../../widgets/apple_map.dart';
import '../../widgets/logo_loader.dart';
import '../plans/plans_page.dart';
import '../../l10n/i18n.dart';

/// Options choisies avant d'organiser le trajet.
class TripOptions {
  const TripOptions({required this.mode, this.maxPerDay, this.notes});

  final TravelMode mode;
  final int? maxPerDay;
  final String? notes;
}

/// Feuille d'options : déplacement, maximum de visites par jour, consigne libre.
Future<TripOptions?> showTripOptions(BuildContext context) => showModalBottomSheet<TripOptions>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => const _OptionsSheet(),
);

class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet();

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  var _mode = TravelMode.walking;
  int? _max;
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('Organiser le trajet'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              tr('Je cherche l\'ordre de visite qui vous fait perdre le moins de temps, jour par jour, '
              'en gardant les heures que vous avez fixées.'),
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            Text(tr('Déplacements'), style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SegmentedButton<TravelMode>(
              showSelectedIcon: false,
              segments: [
                for (final m in TravelMode.values) ButtonSegment(value: m, icon: Icon(m.icon), label: Text(m.label)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 18),
            Text(tr('Visites par jour'), style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final n in [null, 2, 3, 4, 5])
                  ChoiceChip(
                    label: Text(n == null ? tr('Sans limite') : '$n max'),
                    selected: _max == n,
                    onSelected: (_) => setState(() => _max = n),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _notes,
              maxLength: 300,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: tr('Une consigne ? (facultatif)'),
                hintText: tr('Ex. on aime marcher tranquillement, pas trop tôt le matin'),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, TripOptions(mode: _mode, maxPerDay: _max, notes: _notes.text)),
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(tr('Organiser')),
            ),
          ],
        ),
      ),
    );
  }
}


String _dayTitle(DateTime? d) => d == null ? tr('À caser') : '${weekdayName(d)} ${formatDate(d)}';

String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}h${t.minute.toString().padLeft(2, '0')}';

/// Trajet proposé : temps gagné, étapes jour par jour, carte avec l'itinéraire, texte de l'IA.
/// « Appliquer » écrit les jours et les heures dans le programme partagé (créateur de l'activité).
class TripRoutePage extends StatefulWidget {
  const TripRoutePage({super.key, required this.activity, required this.items, required this.options});

  final Activity activity;
  final List<TripItem> items;
  final TripOptions options;

  @override
  State<TripRoutePage> createState() => _TripRoutePageState();
}

class _TripRoutePageState extends State<TripRoutePage> {
  TripPlan? _plan;
  String? _error;
  var _limited = false;
  var _day = 0;
  var _applying = false;

  bool get _canApply => widget.activity.role == MemberRole.owner;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _plan = null;
      _error = null;
    });
    try {
      final plan = await TripPlanner.instance.optimize(
        widget.items,
        mode: widget.options.mode,
        maxPerDay: widget.options.maxPerDay,
        notes: widget.options.notes,
      );
      if (mounted) setState(() => _plan = plan);
    } catch (e) {
      if (mounted) {
        setState(() {
          _limited = e is PlanLimitException;
          _error = switch (e) {
            TripPlanException() => e.message,
            PlanLimitException() => e.message,
            _ => tr('L\'organisation du trajet a échoué.'),
          };
        });
        if (_limited) _upgrade();
      }
    }
  }

  TripItem? _item(String id) {
    for (final i in widget.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// L'app Plans s'ouvre avec les étapes du jour dans l'ordre proposé (guidage, heure d'arrivée…).
  Future<void> _openInPlans(PlannedDay day, TravelMode mode) async {
    final stops = [
      for (final s in day.stops)
        if (_item(s.id) case final item? when item.hasPosition) (item.latitude!, item.longitude!, item.name),
    ];
    final opened = await openInAppleMaps(stops, mode: mode.name);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Impossible d\'ouvrir Plans.'))));
    }
  }

  Future<void> _apply() async {
    final plan = _plan!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Appliquer ce programme ?')),
        content: Text(
          tr('Les jours et les heures proposés seront enregistrés dans le programme, pour tout le groupe.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Annuler'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Appliquer'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _applying = true);
    try {
      for (final day in plan.days) {
        for (final stop in day.stops) {
          final item = _item(stop.id);
          if (item == null) continue;
          await TripRepository.instance.schedule(item, date: day.date, time: stop.time);
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  /// Quota du mois atteint : propose l'offre supérieure.
  Future<void> _upgrade() => showUpgradeSheet(context, message: _error ?? '', feature: PlanFeature.trip);

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Trajet proposé'))),
      bottomNavigationBar: plan == null || plan.days.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: _canApply
                    ? FilledButton.icon(
                        onPressed: _applying ? null : _apply,
                        icon: _applying
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.check_rounded),
                        label: Text(tr('Appliquer ce programme')),
                      )
                    : Text(
                        tr('Seul le créateur de l\'activité peut appliquer ce programme.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
              ),
            ),
      body: switch ((plan, _error)) {
        (null, final String error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.route_outlined, size: 56),
                const SizedBox(height: 12),
                Text(error, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                if (_limited)
                  FilledButton.icon(
                    onPressed: _upgrade,
                    icon: const Icon(Icons.workspace_premium_rounded),
                    label: Text(tr('Passer à l\'offre supérieure')),
                  )
                else
                  FilledButton.tonal(onPressed: _run, child: Text(tr('Réessayer'))),
              ],
            ),
          ),
        ),
        (null, _) => Center(
          child: LogoLoader(logoSize: 84, message: tr('Calcul des itinéraires et rédaction du programme…')),
        ),
        (final TripPlan plan, _) => _result(plan),
      },
    );
  }

  Widget _result(TripPlan plan) {
    final colors = Theme.of(context).colorScheme;
    final day = plan.days.isEmpty ? null : plan.days[_day.clamp(0, plan.days.length - 1)];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _GainCard(plan: plan),
        if (plan.days.length > 1) ...[
          const SizedBox(height: 14),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < plan.days.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_dayTitle(plan.days[i].date)),
                      selected: _day == i,
                      onSelected: (_) => setState(() => _day = i),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (day != null) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              height: 280,
              child: _RouteMap(day: day, items: widget.items, mode: plan.mode),
            ),
          ),
          if (appleMapsAvailable) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => _openInPlans(day, plan.mode),
              icon: const Icon(Icons.navigation_rounded),
              label: Text(tr('Ouvrir l\'itinéraire dans Plans')),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            '${_dayTitle(day.date)[0].toUpperCase()}${_dayTitle(day.date).substring(1)}',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: colors.primary),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < day.stops.length; i++) _StopRow(index: i, stop: day.stops[i], mode: plan.mode),
        ],
        if (plan.summary != null) ...[
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded, color: colors.primary),
                      const SizedBox(width: 8),
                      Text(tr('Le mot de l\'IA'), style: TextStyle(fontWeight: FontWeight.w800)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(plan.summary!, style: const TextStyle(height: 1.4)),
                  if (plan.modelVersion != null) ...[
                    const SizedBox(height: 8),
                    Text(plan.modelVersion!, style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
          ),
        ],
        if (plan.excluded.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            color: AppColors.negative.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: ListTile(
              leading: const Icon(Icons.thumb_down_alt_outlined, color: AppColors.negative),
              title: Text(tr('Mis de côté (plus de contre que de pour)')),
              subtitle: Text(plan.excluded.map((e) => e.$2).join(', ')),
            ),
          ),
        ],
      ],
    );
  }
}

class _GainCard extends StatelessWidget {
  const _GainCard({required this.plan});

  final TripPlan plan;

  @override
  Widget build(BuildContext context) {
    final saved = plan.savedSeconds >= 60;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(colors: [AppColors.primary, Color(0xFF14B8A6)]),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(plan.mode.icon, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  saved ? tr('{0} gagnées', [formatTravel(plan.savedSeconds)]) : tr('Votre ordre est déjà le meilleur'),
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            saved
                ? tr('{0} de trajet {1} au lieu de {2}', [formatTravel(plan.totalSeconds), plan.mode.inSentence, formatTravel(plan.currentSeconds)])
                : tr('{0} de trajet {1} au total', [formatTravel(plan.totalSeconds), plan.mode.inSentence]),
            style: const TextStyle(color: Colors.white70),
          ),
          if (plan.estimated) ...[
            const SizedBox(height: 8),
            Text(
              tr('⚠︎ Temps estimés à vol d\'oiseau : le service d\'itinéraires ne répond pas.'),
              style: TextStyle(color: Colors.white, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _StopRow extends StatelessWidget {
  const _StopRow({required this.index, required this.stop, required this.mode});

  final int index;
  final PlannedStop stop;
  final TravelMode mode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 15,
              backgroundColor: colors.primary,
              child: Text(
                '${index + 1}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 54,
              child: Text(_hhmm(stop.time), style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            Expanded(
              child: Text(stop.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            if (stop.timeFixed)
              Tooltip(message: tr('Heure fixée par le groupe'), child: Icon(Icons.push_pin_outlined, size: 18))
            else if (stop.dateAssigned)
              Tooltip(message: tr('Jour proposé'), child: Icon(Icons.event_available_outlined, size: 18)),
          ],
        ),
        if (stop.nextSeconds != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 0, 2),
            child: Row(
              children: [
                Container(width: 2, height: 30, color: colors.outlineVariant),
                const SizedBox(width: 18),
                Icon(mode.icon, size: 16, color: colors.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  '${formatTravel(stop.nextSeconds!)} · ${formatDistance(stop.nextMeters ?? 0)}',
                  style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
                ),
              ],
            ),
          )
        else
          const SizedBox(height: 8),
      ],
    );
  }
}

/// Carte de la journée : étapes numérotées et itinéraire (Apple Plans sur iPhone, OpenStreetMap ailleurs).
class _RouteMap extends StatelessWidget {
  const _RouteMap({required this.day, required this.items, required this.mode});

  final PlannedDay day;
  final List<TripItem> items;
  final TravelMode mode;

  @override
  Widget build(BuildContext context) {
    final placed = [
      for (final s in day.stops)
        if (items.where((i) => i.id == s.id && i.hasPosition).firstOrNull case final item?) (s, item),
    ];
    if (placed.isEmpty) return const SizedBox.shrink();
    final points = [for (final (_, i) in placed) (i.latitude!, i.longitude!)];
    if (appleMapsAvailable) {
      return AppleMap(
        pins: [
          for (var k = 0; k < placed.length; k++)
            MapPin(
              id: placed[k].$2.id,
              latitude: placed[k].$2.latitude!,
              longitude: placed[k].$2.longitude!,
              label: '${k + 1}',
              color: AppColors.primary,
              title: placed[k].$2.name,
              subtitle: _hhmm(placed[k].$1.time),
            ),
        ],
        route: points,
        routeMode: mode.name,
        onTap: (_) {},
      );
    }
    final latLngs = [for (final (lat, lng) in points) LatLng(lat, lng)];
    return FlutterMap(
      key: ValueKey(day),
      options: MapOptions(
        initialCenter: latLngs.first,
        initialZoom: 14,
        initialCameraFit: latLngs.length > 1
            ? CameraFit.coordinates(coordinates: latLngs, padding: const EdgeInsets.all(40), maxZoom: 16)
            : null,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.emsi.mobileApp',
        ),
        PolylineLayer(
          polylines: [Polyline(points: latLngs, strokeWidth: 5, color: AppColors.primary)],
        ),
        MarkerLayer(
          markers: [
            for (var k = 0; k < latLngs.length; k++)
              Marker(
                point: latLngs[k],
                width: 32,
                height: 32,
                child: CircleAvatar(
                  backgroundColor: AppColors.primary,
                  child: Text(
                    '${k + 1}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
