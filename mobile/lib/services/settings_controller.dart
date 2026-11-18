import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/i18n.dart';

export '../l10n/i18n.dart' show AppLanguage;

/// Préférences de l'app, gardées sur le téléphone.
class SettingsController extends ChangeNotifier {
  SettingsController({
    this._themeMode = ThemeMode.system,
    this._language = AppLanguage.fr,
    this._notifications = true,
    this._prefs,
  }) {
    AppLanguage.current = _language;
  }

  static Future<SettingsController> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return SettingsController(
        themeMode: ThemeMode.values.asNameMap()[prefs.getString('themeMode')] ?? ThemeMode.system,
        language: AppLanguage.values.asNameMap()[prefs.getString('language')] ?? AppLanguage.fr,
        notifications: prefs.getBool('notifications') ?? true,
        prefs: prefs,
      );
    } catch (_) {
      return SettingsController();
    }
  }

  final SharedPreferences? _prefs;
  ThemeMode _themeMode;
  AppLanguage _language;
  bool _notifications;

  ThemeMode get themeMode => _themeMode;
  AppLanguage get language => _language;

  /// Notifications sur le téléphone (demandes, réponses, dépenses, rappels du budget).
  bool get notifications => _notifications;

  void setNotifications(bool enabled) {
    _notifications = enabled;
    _prefs?.setBool('notifications', enabled);
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    _prefs?.setString('themeMode', mode.name);
    notifyListeners();
  }

  void setLanguage(AppLanguage language) {
    _language = language;
    AppLanguage.current = language;
    _prefs?.setString('language', language.name);
    notifyListeners();
  }
}
