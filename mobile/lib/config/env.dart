/// Configuration lue depuis env.json (flutter run --dart-define-from-file=env.json).
class Env {
  Env._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  // API Python (assistant), ex. http://192.168.1.23:8000
  static const apiUrl = String.fromEnvironment('API_URL');

  // Lien de retour dans l'app après Google ou la confirmation de l'email.
  // À ajouter dans Supabase : Authentication > URL Configuration > Redirect URLs.
  static const authRedirect = 'io.equipay.app://login-callback';

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
}
