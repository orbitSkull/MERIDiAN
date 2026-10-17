import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

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

    if (kIsWeb) return 'http://localhost:8000';

    // 10.0.2.2 is the Android emulator's alias for the host machine's
    // loopback. A physical device needs the host's LAN address instead,
    // passed via --dart-define=API_BASE_URL=...
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8000';
    }

    return 'http://127.0.0.1:8000';
  }

  static String get wsBaseUrl {
    if (_overrideWs.isNotEmpty) return _overrideWs;
    return baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
  }
}
