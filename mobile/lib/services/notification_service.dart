import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';

import '../config/env.dart';
import '../l10n/i18n.dart';
import '../models/budget.dart';
import '../utils/money.dart';

/// Notifications sur le téléphone : demandes pour rejoindre (avec Accepter / Refuser directement
/// dans la notification), réponses aux demandes, dépenses ajoutées par les autres et rappels du budget.
///
/// L'app vérifie les nouveautés à l'ouverture, en direct quand elle est ouverte, et toutes les
/// 15 minutes en arrière-plan sur Android (WorkManager). Les rappels du budget sont programmés
/// sur le téléphone et arrivent même sans réseau.
class NotificationService {
  NotificationService._();

  static final instance = NotificationService._();

  static const _acceptAction = 'accept';
  static const _rejectAction = 'reject';
  static const _checkTask = 'equipay-check';

  final _plugin = FlutterLocalNotificationsPlugin();
  var _ready = false;

  /// Notification touchée (sans bouton) : charge utile, ex. « requests » pour ouvrir l'onglet Demandes.
  final opened = StreamController<String>.broadcast();

  /// Une demande a reçu une réponse depuis la notification (l'app recharge la liste).
  final answered = StreamController<void>.broadcast();

  /// Notifications activées dans Profil (et autorisées par le téléphone).
  bool enabled = true;

  /// Vérifie tout de suite les nouveautés (branché dans main.dart ; appelé à chaque changement en direct).
  Future<void> Function()? checkNow;

  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> init() async {
    if (_ready || !_supported) return;
    try {
      tzdata.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier));
    } catch (_) {
      // Fuseau inconnu : heure UTC
    }
    await _plugin.initialize(
      settings: _settings,
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: onNotificationActionInBackground,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true && payload != null) {
      // Laisse l'app se construire avant d'ouvrir l'onglet
      Future.delayed(const Duration(seconds: 2), () => opened.add(payload));
    }
    if (Platform.isAndroid) {
      await Workmanager().initialize(backgroundCheck);
    }
    _ready = true;
  }

  static final _settings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: <DarwinNotificationCategory>[
        DarwinNotificationCategory(
          'join',
          actions: [
            DarwinNotificationAction.plain(_acceptAction, 'Accepter'),
            DarwinNotificationAction.plain(
              _rejectAction,
              'Refuser',
              options: {DarwinNotificationActionOption.destructive},
            ),
          ],
        ),
      ],
    ),
  );

  /// Demande l'autorisation au téléphone ; renvoie false si elle est refusée.
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    await init();
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    return await ios?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
  }

  /// Active ou coupe les notifications (réglage de Profil).
  Future<void> setEnabled(bool on) async {
    enabled = on;
    if (!_supported) return;
    await init();
    if (Platform.isAndroid) {
      if (on) {
        await Workmanager().registerPeriodicTask(
          _checkTask,
          _checkTask,
          frequency: const Duration(minutes: 15),
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      } else {
        await Workmanager().cancelByUniqueName(_checkTask);
      }
    }
    if (!on) await _plugin.cancelAll();
  }

  // ---------------------------------------------------------------------------
  // Affichage
  // ---------------------------------------------------------------------------

  static NotificationDetails _details(String channel, String channelName, {List<AndroidNotificationAction>? actions}) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel,
          channelName,
          importance: Importance.high,
          priority: Priority.high,
          actions: actions,
          styleInformation: const BigTextStyleInformation(''),
        ),
        iOS: DarwinNotificationDetails(categoryIdentifier: actions == null ? null : 'join'),
      );

  Future<void> show(String title, String body, {String channel = 'activity', String? payload}) async {
    if (!enabled || !_supported) return;
    await init();
    await _plugin.show(
      id: (title + body).hashCode & 0x7fffffff,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: _details(channel, _channelName(channel)),
    );
  }

  /// Nouvelle demande pour rejoindre une de mes activités, avec Accepter / Refuser.
  Future<void> showJoinRequest({required String requestId, required String who, required String activity}) async {
    if (!enabled || !_supported) return;
    await init();
    await _plugin.show(
      id: requestId.hashCode & 0x7fffffff,
      title: tr('Nouvelle demande'),
      body: tr('{0} veut rejoindre « {1} »', [who, activity]),
      payload: 'join:$requestId',
      notificationDetails: _details(
        'requests',
        _channelName('requests'),
        actions: [
          AndroidNotificationAction(_acceptAction, tr('Accepter'), showsUserInterface: false, cancelNotification: true),
          AndroidNotificationAction(_rejectAction, tr('Refuser'), showsUserInterface: false, cancelNotification: true),
        ],
      ),
    );
  }

  static String _channelName(String channel) => switch (channel) {
    'requests' => tr('Demandes pour rejoindre'),
    'budget' => tr('Rappels du budget'),
    _ => tr('Activités et dépenses'),
  };

  // ---------------------------------------------------------------------------
  // Réponses aux notifications
  // ---------------------------------------------------------------------------

  Future<void> _onResponse(NotificationResponse response) async {
    final payload = response.payload ?? '';
    final action = response.actionId;
    if (payload.startsWith('join:') && (action == _acceptAction || action == _rejectAction)) {
      await respondFromNotification(payload.substring(5), accept: action == _acceptAction, client: _client);
      answered.add(null);
      return;
    }
    opened.add(payload.startsWith('join:') ? 'requests' : payload);
  }

  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// Accepte ou refuse une demande depuis la notification, puis confirme par une notification.
  static Future<void> respondFromNotification(String requestId, {required bool accept, SupabaseClient? client}) async {
    final plugin = FlutterLocalNotificationsPlugin();
    String message;
    try {
      final c = client ?? await _backgroundClient();
      await c.rpc('respond_join_request', params: {'p_request': requestId, 'p_accept': accept});
      message = accept ? tr('Demande acceptée : la personne a rejoint ton activité.') : tr('Demande refusée.');
    } catch (_) {
      message = tr('La réponse n\'a pas pu être envoyée. Ouvre l\'app pour réessayer.');
    }
    try {
      await plugin.initialize(settings: _settings);
      await plugin.show(
        id: requestId.hashCode & 0x7fffffff,
        title: 'EquiPay',
        body: message,
        notificationDetails: _details('requests', _channelName('requests')),
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Nouveautés (demandes, réponses, dépenses des autres)
  // ---------------------------------------------------------------------------

  /// Cherche ce qui s'est passé depuis la dernière vérification et prévient l'utilisateur.
  /// La première fois, on note seulement l'heure (pas d'avalanche de vieilles notifications).
  static Future<void> checkForNews(SupabaseClient client, {bool notify = true}) async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'notif_last_check:$uid';
    final last = prefs.getString(key);
    final now = DateTime.now().toUtc();
    await prefs.setString(key, now.toIso8601String());
    if (last == null || !notify) return;
    final seen = (prefs.getStringList('notif_seen:$uid') ?? const []).toSet();
    final service = instance;

    // Demandes reçues en attente (pour mes activités) et réponses à mes demandes
    final requests = await client
        .from('join_requests')
        .select('id, user_id, activity_name, status, created_at, decided_at, profiles(full_name, email)')
        .or('created_at.gt."$last",decided_at.gt."$last"')
        .limit(30);
    for (final r in requests) {
      final id = r['id'] as String;
      final status = r['status'] as String;
      final mark = '$id:$status';
      if (seen.contains(mark)) continue;
      seen.add(mark);
      final profile = r['profiles'] as Map? ?? const {};
      final who = (profile['full_name'] as String?)?.trim().isNotEmpty == true
          ? profile['full_name'] as String
          : (profile['email'] as String? ?? '').split('@').first;
      final activity = r['activity_name'] as String;
      if (r['user_id'] != uid && status == 'pending') {
        await service.showJoinRequest(requestId: id, who: who, activity: activity);
      } else if (r['user_id'] == uid && status == 'accepted') {
        await service.show(
          tr('Demande acceptée 🎉'),
          tr('Tu as rejoint « {0} ».', [activity]),
          channel: 'requests',
          payload: 'requests',
        );
      } else if (r['user_id'] == uid && status == 'rejected') {
        await service.show(
          tr('Demande refusée'),
          tr('Ta demande pour « {0} » a été refusée.', [activity]),
          channel: 'requests',
          payload: 'requests',
        );
      }
    }

    // Dépenses ajoutées par les autres membres de mes activités
    final expenses = await client
        .from('expenses')
        .select('id, name, amount, currency, created_by, activities(name)')
        .neq('created_by', uid)
        .gt('created_at', last)
        .order('created_at')
        .limit(20);
    if (expenses.isNotEmpty) {
      final ids = {for (final e in expenses) e['created_by'] as String}.toList();
      final profiles = await client.from('profiles').select('id, full_name, email').inFilter('id', ids);
      final names = {
        for (final p in profiles)
          p['id'] as String: (p['full_name'] as String?)?.trim().isNotEmpty == true
              ? p['full_name'] as String
              : (p['email'] as String).split('@').first,
      };
      for (final e in expenses) {
        final mark = 'expense:${e['id']}';
        if (seen.contains(mark)) continue;
        seen.add(mark);
        await service.show(
          tr('Nouvelle dépense dans « {0} »', [(e['activities'] as Map?)?['name'] ?? '']),
          tr('{0} a ajouté « {1} » : {2}', [
            names[e['created_by']] ?? tr('Un membre'),
            e['name'],
            formatMoney((e['amount'] as num).toDouble(), (e['currency'] as String).trim()),
          ]),
          payload: 'home',
        );
      }
    }
    await prefs.setStringList('notif_seen:$uid', seen.toList().reversed.take(300).toList());
  }

  // ---------------------------------------------------------------------------
  // Rappels du budget (programmés sur le téléphone)
  // ---------------------------------------------------------------------------

  static const _budgetIds = 900000;

  /// Reprogramme les rappels : chaque charge 2 jours avant (9 h) et le jour de paie (10 h).
  Future<void> scheduleBudget(BudgetSettings? settings, List<BudgetRecurring> items) async {
    if (!_supported) return;
    await init();
    final pending = await _plugin.pendingNotificationRequests();
    for (final p in pending.where((p) => p.id >= _budgetIds)) {
      await _plugin.cancel(id: p.id);
    }
    if (!enabled || settings == null || !settings.reminders) return;
    final details = _details('budget', _channelName('budget'));
    var id = _budgetIds;
    Future<void> monthly(int day, int hour, String title, String body) async {
      final now = tz.TZDateTime.now(tz.local);
      var date = tz.TZDateTime(tz.local, now.year, now.month, day.clamp(1, 28), hour);
      if (date.isBefore(now)) date = tz.TZDateTime(tz.local, now.year, now.month + 1, day.clamp(1, 28), hour);
      await _plugin.zonedSchedule(
        id: id++,
        scheduledDate: date,
        title: title,
        body: body,
        payload: 'budget',
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime,
      );
    }

    await monthly(
      settings.payday,
      10,
      tr('Jour de paie 💰'),
      tr('Ton salaire est arrivé ? Marque-le comme reçu et prépare ton budget du mois.'),
    );
    for (final r in items.where((r) => r.active && r.kind == BudgetKind.expense).take(40)) {
      final day = r.day - 2 < 1 ? 1 : r.day - 2;
      await monthly(
        day,
        9,
        tr('À payer bientôt : {0}', [r.name]),
        tr('{0} à payer le {1} de ce mois.', [formatMoney(r.amount, settings.currency), r.day]),
      );
    }
  }

  /// Budget d'une catégorie bientôt (80 %) ou entièrement utilisé.
  Future<void> budgetAlert(BudgetCategory category, double spent, double limit, String currency) async {
    final ratio = spent / limit;
    if (ratio < 0.8) return;
    await show(
      ratio >= 1 ? tr('Budget {0} dépassé', [category.label]) : tr('Budget {0} presque atteint', [category.label]),
      tr('{0} dépensés sur {1} ce mois-ci.', [formatMoney(spent, currency), formatMoney(limit, currency)]),
      channel: 'budget',
      payload: 'budget',
    );
  }
}

/// Client Supabase dans un isolat d'arrière-plan (la session est relue sur le téléphone).
Future<SupabaseClient> _backgroundClient() async {
  try {
    return Supabase.instance.client;
  } catch (_) {
    await Supabase.initialize(url: Env.supabaseUrl, publishableKey: Env.supabasePublishableKey);
    return Supabase.instance.client;
  }
}

Future<void> _loadLanguage() async {
  final prefs = await SharedPreferences.getInstance();
  AppLanguage.current = AppLanguage.values.asNameMap()[prefs.getString('language')] ?? AppLanguage.fr;
}

/// Bouton Accepter / Refuser touché alors que l'app est fermée ou en arrière-plan.
@pragma('vm:entry-point')
Future<void> onNotificationActionInBackground(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final payload = response.payload ?? '';
  if (!payload.startsWith('join:')) return;
  await _loadLanguage();
  await NotificationService.respondFromNotification(
    payload.substring(5),
    accept: response.actionId == NotificationService._acceptAction,
  );
}

/// Vérification périodique en arrière-plan (Android, toutes les 15 minutes environ).
@pragma('vm:entry-point')
void backgroundCheck() {
  Workmanager().executeTask((task, _) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('notifications') ?? true)) return true;
      await _loadLanguage();
      await NotificationService.instance.init();
      await NotificationService.checkForNews(await _backgroundClient());
    } catch (_) {
      // Pas de réseau ou session expirée : on réessaiera au prochain passage
    }
    return true;
  });
}
