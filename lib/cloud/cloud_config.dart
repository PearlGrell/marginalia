import 'package:firebase_core/firebase_core.dart';

/// The Firebase project this build talks to, passed in at build time:
///
///     flutter build apk --dart-define-from-file=cloud.json
///
/// (`scripts/deploy-to-phone.ps1` does this when `cloud.json` exists; see `docs/cloud-setup.md`.)
/// Without it the app is fully offline: no sign-in, no sync.
abstract final class CloudConfig {
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  /// The OAuth "Web client" id from the Firebase project, which Google sign-in on Android
  /// needs to issue an ID token Firebase accepts.
  static const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  static bool get isConfigured =>
      _apiKey.isNotEmpty &&
      _appId.isNotEmpty &&
      _senderId.isNotEmpty &&
      _projectId.isNotEmpty &&
      webClientId.isNotEmpty;

  static FirebaseOptions get options => const FirebaseOptions(
    apiKey: _apiKey,
    appId: _appId,
    messagingSenderId: _senderId,
    projectId: _projectId,
  );
}
