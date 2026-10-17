import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Locally persisted UI settings.
///
/// Everything in here is device-local in this phase. Nothing is synced to the
/// API yet, so a reinstall resets these to defaults. When the backend wiring
/// lands, [AppSettings] becomes the local cache and the server becomes the
/// source of truth rather than a rename of this class.
///
/// Reads are eager into fields and writes go through [set], which persists and
/// notifies in one step. Widgets listen with [AnimatedBuilder] rather than
/// being rebuilt by hand at each call site.
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._prefs);

  final SharedPreferences _prefs;

  /// In-memory fallback used when shared_preferences is unavailable, which
  /// happens in widget tests that have not called
  /// `SharedPreferences.setMockInitialValues`. Persisting then no-ops, which
  /// is the right behaviour for a test.
  SettingsStore.inMemory() : _prefs = _NullPrefs() {
    _readAll();
  }

  static Future<SettingsStore> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = SettingsStore._(prefs);
      store._readAll();
      return store;
    } catch (_) {
      return SettingsStore.inMemory();
    }
  }

  // Appearance.
  String _themeModeName = 'system';
  double _fontScale = 1.0;

  // Notifications.
  bool _pushEnabled = true;
  bool _emailEnabled = true;
  bool _inAppEnabled = true;
  bool _notifyMessages = true;
  bool _notifyMentions = true;
  bool _notifyCalls = true;

  // Privacy.
  bool _readReceipts = true;
  bool _typingIndicator = true;
  bool _lastSeen = true;

  // Storage.
  bool _autoDownloadMedia = true;

  // Blocking preferences. Distinct from the privacy toggles above: those
  // control what everyone sees, these control what blocked people are shown.
  bool _blockUnknownCallers = true;
  bool _hideReadReceiptsFromBlocked = true;

  String get themeModeName => _themeModeName;
  double get fontScale => _fontScale;
  bool get pushEnabled => _pushEnabled;
  bool get emailEnabled => _emailEnabled;
  bool get inAppEnabled => _inAppEnabled;
  bool get notifyMessages => _notifyMessages;
  bool get notifyMentions => _notifyMentions;
  bool get notifyCalls => _notifyCalls;
  bool get readReceipts => _readReceipts;
  bool get typingIndicator => _typingIndicator;
  bool get lastSeen => _lastSeen;
  bool get autoDownloadMedia => _autoDownloadMedia;
  bool get blockUnknownCallers => _blockUnknownCallers;
  bool get hideReadReceiptsFromBlocked => _hideReadReceiptsFromBlocked;

  /// True when every notification channel is off, which is what the
  /// notification screen shows as a warning.
  bool get allNotificationsOff =>
      !_pushEnabled && !_emailEnabled && !_inAppEnabled;

  void _readAll() {
    _themeModeName = _prefs.getString(kThemeMode) ?? _themeModeName;
    _fontScale = _prefs.getDouble(kFontScale) ?? _fontScale;
    _pushEnabled = _prefs.getBool(kPush) ?? _pushEnabled;
    _emailEnabled = _prefs.getBool(kEmail) ?? _emailEnabled;
    _inAppEnabled = _prefs.getBool(kInApp) ?? _inAppEnabled;
    _notifyMessages = _prefs.getBool(kNotifyMessages) ?? _notifyMessages;
    _notifyMentions = _prefs.getBool(kNotifyMentions) ?? _notifyMentions;
    _notifyCalls = _prefs.getBool(kNotifyCalls) ?? _notifyCalls;
    _readReceipts = _prefs.getBool(kReadReceipts) ?? _readReceipts;
    _typingIndicator = _prefs.getBool(kTyping) ?? _typingIndicator;
    _lastSeen = _prefs.getBool(kLastSeen) ?? _lastSeen;
    _autoDownloadMedia =
        _prefs.getBool(kAutoDownload) ?? _autoDownloadMedia;
    _blockUnknownCallers =
        _prefs.getBool(kBlockUnknown) ?? _blockUnknownCallers;
    _hideReadReceiptsFromBlocked =
        _prefs.getBool(kHideReceiptsFromBlocked) ??
        _hideReadReceiptsFromBlocked;
  }

  Future<void> setThemeModeName(String value) =>
      _setString(kThemeMode, value, () => _themeModeName = value);

  Future<void> setFontScale(double value) =>
      _setDouble(kFontScale, value, () => _fontScale = value);

  Future<void> setPushEnabled(bool v) => _setBool(kPush, v, () => _pushEnabled = v);
  Future<void> setEmailEnabled(bool v) =>
      _setBool(kEmail, v, () => _emailEnabled = v);
  Future<void> setInAppEnabled(bool v) => _setBool(kInApp, v, () => _inAppEnabled = v);
  Future<void> setNotifyMessages(bool v) =>
      _setBool(kNotifyMessages, v, () => _notifyMessages = v);
  Future<void> setNotifyMentions(bool v) =>
      _setBool(kNotifyMentions, v, () => _notifyMentions = v);
  Future<void> setNotifyCalls(bool v) =>
      _setBool(kNotifyCalls, v, () => _notifyCalls = v);
  Future<void> setReadReceipts(bool v) =>
      _setBool(kReadReceipts, v, () => _readReceipts = v);
  Future<void> setTypingIndicator(bool v) =>
      _setBool(kTyping, v, () => _typingIndicator = v);
  Future<void> setLastSeen(bool v) => _setBool(kLastSeen, v, () => _lastSeen = v);
  Future<void> setAutoDownloadMedia(bool v) =>
      _setBool(kAutoDownload, v, () => _autoDownloadMedia = v);
  Future<void> setBlockUnknownCallers(bool v) =>
      _setBool(kBlockUnknown, v, () => _blockUnknownCallers = v);
  Future<void> setHideReadReceiptsFromBlocked(bool v) => _setBool(
    kHideReceiptsFromBlocked,
    v,
    () => _hideReadReceiptsFromBlocked = v,
  );

  Future<void> _setBool(String key, bool value, VoidCallback assign) {
    assign();
    notifyListeners();
    return _write(() => _prefs.setBool(key, value));
  }

  Future<void> _setString(String key, String value, VoidCallback assign) {
    assign();
    notifyListeners();
    return _write(() => _prefs.setString(key, value));
  }

  Future<void> _setDouble(String key, double value, VoidCallback assign) {
    assign();
    notifyListeners();
    return _write(() => _prefs.setDouble(key, value));
  }

  Future<void> _write(Future<bool> Function() action) async {
    try {
      await action();
    } catch (_) {
      // The in-memory value is already applied, so a failed write only costs
      // persistence until the next launch. Never surface this to the user.
    }
  }

  /// Restore defaults, used by the Advanced screen.
  Future<void> reset() async {
    for (final key in allKeys) {
      try {
        await _prefs.remove(key);
      } catch (_) {
        // See _write.
      }
    }
    _themeModeName = 'system';
    _fontScale = 1.0;
    _pushEnabled = true;
    _emailEnabled = true;
    _inAppEnabled = true;
    _notifyMessages = true;
    _notifyMentions = true;
    _notifyCalls = true;
    _readReceipts = true;
    _typingIndicator = true;
    _lastSeen = true;
    _autoDownloadMedia = true;
    _blockUnknownCallers = true;
    _hideReadReceiptsFromBlocked = true;
    notifyListeners();
  }

  static const kThemeMode = 'meridian.settings.theme_mode';
  static const kFontScale = 'meridian.settings.font_scale';
  static const kPush = 'meridian.settings.push';
  static const kEmail = 'meridian.settings.email';
  static const kInApp = 'meridian.settings.in_app';
  static const kNotifyMessages = 'meridian.settings.notify_messages';
  static const kNotifyMentions = 'meridian.settings.notify_mentions';
  static const kNotifyCalls = 'meridian.settings.notify_calls';
  static const kReadReceipts = 'meridian.settings.read_receipts';
  static const kTyping = 'meridian.settings.typing_indicator';
  static const kLastSeen = 'meridian.settings.last_seen';
  static const kAutoDownload = 'meridian.settings.auto_download';
  static const kBlockUnknown = 'meridian.settings.block_unknown_callers';
  static const kHideReceiptsFromBlocked =
      'meridian.settings.hide_receipts_from_blocked';

  static const allKeys = <String>[
    kThemeMode,
    kFontScale,
    kPush,
    kEmail,
    kInApp,
    kNotifyMessages,
    kNotifyMentions,
    kNotifyCalls,
    kReadReceipts,
    kTyping,
    kLastSeen,
    kAutoDownload,
    kBlockUnknown,
    kHideReceiptsFromBlocked,
  ];
}

/// A [SharedPreferences] stand-in that discards writes.
class _NullPrefs implements SharedPreferences {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getBool) return null;
    if (invocation.memberName == #getString) return null;
    if (invocation.memberName == #getDouble) return null;
    if (invocation.memberName == #remove ||
        invocation.memberName == #setBool ||
        invocation.memberName == #setString ||
        invocation.memberName == #setDouble ||
        invocation.memberName == #clear) {
      return Future<bool>.value(true);
    }
    if (invocation.memberName == #containsKey) return false;
    return null;
  }
}