import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, kReleaseMode;

/// Where the API lives, per platform.
///
/// Override at build time when the server is not on loopback:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
class ApiConfig {
  const ApiConfig._();

  static const String _override = String.fromEnvironment('API_BASE_URL');
  static const String _overrideWs = String.fromEnvironment(
    'API_BASE_URL_WS',
    defaultValue: '',
  );

  static const String prefix = '/api/v1';

  static String get baseUrl {
    if (_override.isNotEmpty) return _override;

    // A release build with no override used to fall through to loopback, which
    // can never answer on a phone: every request failed with a connection error
    // and there was nothing in the app to explain why. Ship the production API
    // instead, so a plain `flutter build apk --release` produces something that
    // works, and the override stays available for pointing a build elsewhere.
    if (kReleaseMode) return productionBaseUrl;

    if (kIsWeb) return 'http://localhost:8000';

    // 10.0.2.2 is the Android emulator's alias for the host machine's
    // loopback. A physical device needs the host's LAN address instead,
    // passed via --dart-define=API_BASE_URL=...
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8000';
    }

    return 'http://127.0.0.1:8000';
  }

  /// The hosted API.
  ///
  /// Free tier, so it sleeps after about fifteen minutes idle and needs up to a
  /// minute to come back. The client's timeouts are set around that, not around
  /// a warm server.
  static const String productionBaseUrl = 'https://meridian-api-gvmr.onrender.com';

  static String get wsBaseUrl {
    if (_overrideWs.isNotEmpty) return _overrideWs;
    return baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
  }
}
