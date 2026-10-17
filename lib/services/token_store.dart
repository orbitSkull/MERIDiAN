import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

const String kAccessTokenKey = 'meridian.access_token';
const String kRefreshTokenKey = 'meridian.refresh_token';

/// Cached copy of the last known profile.
///
/// Lets the app render the home screen while offline instead of bouncing the
/// user to the login form, which reads as "I was logged out".
const String kCachedUserKey = 'meridian.cached_user';

/// Storage backend for session tokens.
abstract class TokenBackend {
  Future<Map<String, String>> readAll();
  Future<void> writeAll(Map<String, String> values);
  Future<void> clear();
}

/// Keychain / Keystore / DPAPI backed storage. The preferred backend.
///
/// flutter_secure_storage 11.x defaults to AES-GCM with RSA-OAEP key wrapping
/// on Android, so no explicit cipher options are needed.
class SecureTokenBackend implements TokenBackend {
  SecureTokenBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  @override
  Future<void> writeAll(Map<String, String> values) async {
    for (final entry in values.entries) {
      if (entry.value.isEmpty) {
        // Never write an empty value: flutter_secure_storage stores it as an
        // empty string, which then reads back as "present but blank".
        await _storage.delete(key: entry.key);
      } else {
        await _storage.write(key: entry.key, value: entry.value);
      }
    }
  }

  @override
  Future<void> clear() => _storage.deleteAll();
}

/// Plain-file fallback.
///
/// Used only where the secure backend throws (missing plugin implementation on
/// an unsupported platform, keystore corruption, and so on). Tokens are stored
/// base64-encoded, which is *obfuscation, not encryption* — it keeps them out
/// of casual inspection, but anyone with filesystem access can recover them.
class FileTokenBackend implements TokenBackend {
  FileTokenBackend(this._file);

  final File _file;

  static Future<FileTokenBackend> create() async {
    final dir = await getApplicationSupportDirectory();
    return FileTokenBackend(File('${dir.path}/session.json'));
  }

  @override
  Future<Map<String, String>> readAll() async {
    try {
      if (!await _file.exists()) return {};
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (error) {
      // A corrupt token file must not brick the app; start a fresh session.
      debugPrint('Could not read session file: $error');
      return {};
    }
  }

  @override
  Future<void> writeAll(Map<String, String> values) async {
    final encoded = {
      for (final entry in values.entries)
        entry.key: base64Encode(utf8.encode(entry.value)),
    };
    await _file.writeAsString(jsonEncode(encoded), flush: true);
  }

  @override
  Future<void> clear() async {
    if (await _file.exists()) await _file.delete();
  }
}

/// Persists the session across app launches.
///
/// Probes the secure backend once, and permanently falls back to the file
/// backend if it throws.
class TokenStore {
  // `_backend` is private, so an initializing formal would force the public
  // named argument to be private too.
  // ignore: prefer_initializing_formals
  TokenStore({TokenBackend? backend}) : _backend = backend;

  TokenBackend? _backend;
  Future<TokenBackend>? _resolving;

  bool _usingFallback = false;
  bool get isUsingFallbackStorage => _usingFallback;

  Future<TokenBackend> _resolve() async {
    final existing = _backend;
    if (existing != null) return existing;

    final inFlight = _resolving;
    if (inFlight != null) return inFlight;

    final future = _probe();
    _resolving = future;
    return future;
  }

  Future<TokenBackend> _probe() async {
    try {
      final secure = SecureTokenBackend();
      // readAll() on an empty store exercises the plugin channel, which
      // catches an unimplemented platform before we depend on it.
      await secure.readAll();
      _usingFallback = false;
      _backend = secure;
      return secure;
    } catch (error) {
      debugPrint('Secure storage unavailable, using file backend: $error');
      if (kIsWeb) rethrow;
      final file = await FileTokenBackend.create();
      _usingFallback = true;
      _backend = file;
      return file;
    }
  }

  Future<String?> readAccessToken() async {
    final values = await (await _resolve()).readAll();
    return values[kAccessTokenKey];
  }

  Future<String?> readRefreshToken() async {
    final values = await (await _resolve()).readAll();
    return values[kRefreshTokenKey];
  }

  /// Last profile the server returned, for rendering while offline.
  Future<String?> readCachedUser() async {
    final values = await (await _resolve()).readAll();
    return values[kCachedUserKey];
  }

  Future<void> cacheUser(String json) async {
    final backend = await _resolve();
    await backend.writeAll({kCachedUserKey: json});
  }

  Future<void> save({
    required String accessToken,
    required String refreshToken,
  }) async {
    final backend = await _resolve();
    await backend.writeAll({
      kAccessTokenKey: accessToken,
      kRefreshTokenKey: refreshToken,
    });
  }

  Future<void> clear() async {
    final backend = await _resolve();
    await backend.clear();
  }
}
