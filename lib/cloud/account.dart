import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import 'cloud_config.dart';

/// Starts Firebase once per isolate (the app, or a background sync).
Future<bool> ensureCloud() async {
  if (!CloudConfig.isConfigured) return false;
  if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: CloudConfig.options);
  return true;
}

/// The signed-in user, as the account screen shows them.
class Account {
  const Account({required this.uid, this.name, this.email, this.photoUrl});

  final String uid;
  final String? name;
  final String? email;
  final String? photoUrl;
}

class AccountState {
  const AccountState({this.configured = false, this.account, this.busy = false, this.error});

  /// Whether this build has a Firebase project at all.
  final bool configured;
  final Account? account;
  final bool busy;
  final String? error;

  bool get signedIn => account != null;
}

/// Google sign-in for Firebase (library data) and the user's Drive app folder (book files).
class AccountController extends Notifier<AccountState> {
  static const driveScopes = [drive.DriveApi.driveAppdataScope];

  /// For sharing books: the app folder plus files the app puts in the visible Drive.
  static const shareScopes = [drive.DriveApi.driveAppdataScope, drive.DriveApi.driveFileScope];

  StreamSubscription<User?>? _auth;

  @override
  AccountState build() {
    ref.onDispose(() => _auth?.cancel());
    if (!CloudConfig.isConfigured) return const AccountState();
    unawaited(_start());
    return const AccountState(configured: true, busy: true);
  }

  Future<void> _start() async {
    await ensureCloud();
    _auth = FirebaseAuth.instance.authStateChanges().listen((user) {
      state = AccountState(
        configured: true,
        account: user == null
            ? null
            : Account(
                uid: user.uid,
                name: user.displayName,
                email: user.email,
                photoUrl: user.photoURL,
              ),
      );
    });
  }

  Future<void> signIn() async {
    if (!state.configured) return;
    state = AccountState(configured: true, account: state.account, busy: true);
    try {
      final signIn = await googleSignIn();
      final account = await signIn.authenticate(scopeHint: driveScopes);
      final idToken = account.authentication.idToken;
      if (idToken == null) throw StateError('Google did not return an ID token.');
      await FirebaseAuth.instance.signInWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
      // Ask for the Drive app folder now, while the user is here to answer.
      await account.authorizationClient.authorizeScopes(driveScopes);
    } on GoogleSignInException catch (e) {
      final cancelled = e.code == GoogleSignInExceptionCode.canceled;
      state = AccountState(
        configured: true,
        account: state.account,
        error: cancelled ? null : 'Sign-in failed: ${e.description ?? e.code.name}',
      );
    } catch (e) {
      state = AccountState(configured: true, account: state.account, error: 'Sign-in failed: $e');
    }
  }

  Future<void> signOut() async {
    await (await googleSignIn()).signOut();
    await FirebaseAuth.instance.signOut();
  }
}

Future<GoogleSignIn>? _googleSignIn;

/// Google sign-in, set up once per isolate (it may only be initialized once).
Future<GoogleSignIn> googleSignIn() => _googleSignIn ??= () async {
  await GoogleSignIn.instance.initialize(serverClientId: CloudConfig.webClientId);
  return GoogleSignIn.instance;
}();

/// An HTTP client for the user's Drive app folder, or null without access.
///
/// Uses Google's authorization API directly: it returns a token silently when the user has
/// already allowed the app folder, and only shows a consent screen when [prompt] is set.
/// (Lightweight sign-in, used before, can wait on a sign-in sheet that never shows.)
///
/// [scopes] defaults to the hidden app folder; sharing adds `drive.file` (files the app
/// creates in the user's visible Drive).
Future<http.Client?> driveClientFor({
  bool prompt = false,
  List<String> scopes = AccountController.driveScopes,
}) async {
  try {
    final google = await googleSignIn().timeout(const Duration(seconds: 10));
    final client = google.authorizationClient;
    final authorization =
        await client.authorizationForScopes(scopes).timeout(const Duration(seconds: 20)) ??
        (prompt ? await client.authorizeScopes(scopes) : null);
    if (authorization == null) return null;
    return _BearerClient(authorization.accessToken);
  } catch (_) {
    return null;
  }
}

class _BearerClient extends http.BaseClient {
  _BearerClient(this._token);

  final String _token;
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $_token';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

final accountProvider = NotifierProvider<AccountController, AccountState>(AccountController.new);
