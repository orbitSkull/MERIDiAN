import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/user.dart';
import 'api_client.dart';
import 'token_store.dart';

/// Result of restoring a persisted session at app start.
enum SessionStatus {
  /// No stored credentials, or they were rejected. Show the login screen.
  signedOut,

  /// Stored credentials were valid, possibly after a silent refresh.
  signedIn,

  /// Credentials could not be checked because the server is unreachable.
  /// The user stays signed in using their cached profile.
  signedInOffline,
}

/// Owns the app's authentication state and the single [ApiClient] instance.
class AuthService extends ChangeNotifier {
  AuthService({ApiClient? client, TokenStore? tokenStore})
    : tokens = tokenStore ?? TokenStore() {
    // One shared TokenStore, so an injected client and this service never end
    // up reading and writing two different backends.
    _client = client ?? ApiClient(tokens: tokens);
    _client.onSessionExpired = _handleSessionExpired;
  }

  final TokenStore tokens;
  late final ApiClient _client;

  UserProfile? _user;
  UserProfile? get user => _user;

  bool get isSignedIn => _user != null;

  /// True when the last server interaction failed because it was unreachable.
  /// The session is still valid; this only drives the offline banner.
  bool _isOffline = false;
  bool get isOffline => _isOffline;

  ApiClient get api => _client;

  /// Re-read the profile from the server and refresh the offline cache.
  ///
  /// Called after an edit in settings. The edit screens return the profile the
  /// server sent, but re-reading is what guarantees the rest of the app and the
  /// cached copy agree with the server rather than with whatever was on screen
  /// when the save happened.
  ///
  /// An unreachable server is not a failure here: the edited value is already
  /// correct locally and the next launch will catch up.
  Future<void> refreshProfile() async {
    try {
      _user = await _client.me();
      _isOffline = false;
      await _cacheUser();
    } on ApiException catch (error) {
      if (error.isOffline) _isOffline = true;
    }
    notifyListeners();
  }

  /// Restore a persisted session so returning users skip the login screen.
  ///
  /// Tries the stored access token, then a single silent refresh. A failed
  /// refresh (401) clears the session. A *network* failure does not: the
  /// tokens are still valid, so the user stays signed in using their cached
  /// profile, and [isOffline] is set so the UI can say so.
  Future<SessionStatus> restoreSession() async {
    final access = await tokens.readAccessToken();
    final refresh = await tokens.readRefreshToken();
    if (access == null && refresh == null) {
      return SessionStatus.signedOut;
    }

    try {
      _user = await _client.me();
      _isOffline = false;
      return SessionStatus.signedIn;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        // Access token rejected. Fall through to the refresh attempt.
      } else if (e.isOffline) {
        // Could not reach the server. Keep the session and show the cached
        // profile rather than bouncing to the login screen.
        final cached = await _loadCachedUser();
        if (cached != null) {
          _user = cached;
          _isOffline = true;
          debugPrint('Restored session offline from cached profile.');
          return SessionStatus.signedInOffline;
        }
        // No cached profile yet (first launch after this shipped), so there is
        // nothing to render. Keep tokens so the next online launch works.
        debugPrint('Offline with no cached profile; keeping tokens.');
        return SessionStatus.signedOut;
      } else {
        // Server error (5xx etc). Tokens are probably fine.
        final cached = await _loadCachedUser();
        if (cached != null) {
          _user = cached;
          _isOffline = true;
          return SessionStatus.signedInOffline;
        }
        return SessionStatus.signedOut;
      }
    }

    // Access token missing or rejected: one silent refresh attempt.
    if (!await _client.tryRefresh()) {
      await _signOutLocally();
      return SessionStatus.signedOut;
    }

    try {
      _user = await _client.me();
      _isOffline = false;
      await _cacheUser();
      return SessionStatus.signedIn;
    } on ApiException catch (e) {
      if (e.isOffline) {
        final cached = await _loadCachedUser();
        if (cached != null) {
          _user = cached;
          _isOffline = true;
          return SessionStatus.signedInOffline;
        }
      }
      debugPrint('Retry after refresh failed; signing out.');
      await _signOutLocally();
      return SessionStatus.signedOut;
    }
  }

  Future<UserProfile?> _loadCachedUser() async {
    final raw = await tokens.readCachedUser();
    if (raw == null || raw.isEmpty) return null;
    try {
      return UserProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (error) {
      debugPrint('Discarding unreadable cached profile: $error');
      return null;
    }
  }

  Future<void> _cacheUser() async {
    final user = _user;
    if (user == null) return;
    try {
      await tokens.cacheUser(jsonEncode(user.toJson()));
    } catch (error) {
      debugPrint('Could not cache profile: $error');
    }
  }

  Future<void> _signOutLocally() async {
    await tokens.clear();
    _user = null;
  }

  Future<void> login({
    required String collegeCode,
    String? identifier,
    String? password,
    String? moderatorKey,
  }) async {
    await _client.login(
      collegeCode: collegeCode,
      identifier: identifier,
      password: password,
      moderatorKey: moderatorKey,
    );
    _user = await _client.me();
    _isOffline = false;
    await _cacheUser();
    notifyListeners();
  }

  Future<UserProfile> register({
    required String collegeCode,
    required String role,
    required String firstName,
    required String surname,
    String? prn,
    String? empId,
    required String password,
  }) async {
    final profile = await _client.register(
      collegeCode: collegeCode,
      role: role,
      firstName: firstName,
      surname: surname,
      prn: prn,
      empId: empId,
      password: password,
    );
    await _client.login(
      collegeCode: collegeCode,
      identifier: prn ?? empId,
      password: password,
    );
    _user = await _client.me();
    _isOffline = false;
    await _cacheUser();
    notifyListeners();
    return profile;
  }

  Future<void> logout() async {
    await _client.logout();
    _user = null;
    _isOffline = false;
    notifyListeners();
  }

  /// Called when a request's refresh was genuinely rejected by the server.
  ///
  /// A network failure does not reach here: [ApiClient] only ends the session
  /// when the server refuses the token, so a dropped packet cannot log the
  /// user out.
  void _handleSessionExpired() {
    if (_user == null) return;
    _user = null;
    notifyListeners();
  }
}
