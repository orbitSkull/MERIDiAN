import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';
import 'api_client.dart';
import 'meridian_api.dart';

/// Locally persisted settings, synced to the account where it makes sense.
///
/// Two tiers, deliberately:
///
///   * **Appearance** (theme, font scale) stays on the device. A person who
///     prefers dark mode on their phone and light on their laptop is not
///     misconfigured, and syncing it would override the second device every
///     time they opened the app.
///   * **Notifications, privacy and blocking preferences** sync. These describe
///     the account, and the whole point of them existing server side is that a
///     new phone does not come back with defaults.
///
/// The server is the source of truth; this is the cache. Reads come down on
/// [attachApi], a toggle goes up immediately, and a rejected toggle is rolled
/// back rather than left on screen as if it had worked.
///
/// Writes are optimistic so a switch never lags a finger, and pushed through a
/// serial queue so two fast taps cannot arrive out of order and leave the server
/// holding the older value.
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

  // ---------------------------------------------------------------------
  // Server sync
  // ---------------------------------------------------------------------

  MeridianApi? _api;

  /// Set once a session exists, and cleared on sign-out.
  ///
  /// Held rather than passed per call because the store outlives any one
  /// screen, and because clearing it on sign-out stops a toggle tapped after
  /// leaving the account from being pushed to whoever signs in next.
  MeridianApi? get api => _api;

  bool get isSynced => _api != null;

  /// The last values the server confirmed, by API field name.
  ///
  /// What a failed push is rolled back to. Without it a rejection would either
  /// leave the switch on, lying about the account's settings, or reset it to a
  /// default that is also a guess.
  final Map<String, bool> _confirmed = <String, bool>{};

  /// Set when the last push failed, so a screen can say so rather than showing
  /// a switch that silently did not save.
  String? _syncError;
  String? get syncError => _syncError;

  bool _isSyncing = false;

  /// True while the initial read from the server is in flight.
  bool get isSyncing => _isSyncing;

  /// Serialises pushes so two taps cannot race and leave the older value last.
  Future<void> _pushQueue = Future<void>.value();

  /// Start syncing for a signed-in account and pull the server's values.
  ///
  /// Returns false when the server could not be reached, which leaves the
  /// device's cached values in place rather than overwriting them with nothing.
  Future<bool> attachApi(MeridianApi api) async {
    _api = api;
    return syncFromServer();
  }

  /// Attach or detach as the session changes, without doing the work twice.
  ///
  /// Called on every auth notification by the provider in main.dart, so it has
  /// to be cheap and idempotent: re-reading twelve preferences each time
  /// AuthService notifies would hammer the API for a theme change.
  void bindApi(MeridianApi? api) {
    if (api == null) {
      if (_api != null) detachApi();
      return;
    }
    if (identical(api, _api)) return;
    // Deferred, and not for tidiness. This is called from the provider's update
    // callback, which runs during build, and attachApi notifies immediately to
    // raise the syncing flag. Notifying during build is an error in Flutter, so
    // the whole first sign-in would have thrown.
    scheduleMicrotask(() {
      if (identical(_api, api)) return;
      unawaited(attachApi(api));
    });
  }

  /// Stop syncing. The local cache is kept, so signing back in works offline.
  void detachApi() {
    _api = null;
    _confirmed.clear();
    _syncError = null;
  }

  /// Read the account's preferences and apply them locally.
  ///
  /// Server wins. The alternative, letting local values win on launch, means a
  /// change made on one device is silently reverted by opening the app on
  /// another.
  Future<bool> syncFromServer() async {
    final api = _api;
    if (api == null) return false;
    _isSyncing = true;
    notifyListeners();
    try {
      final remote = await api.preferences();
      _applyAll(remote);
      remote.toJson().forEach((key, value) {
        if (value is bool) _confirmed[key] = value;
      });
      _syncError = null;
      return true;
    } on ApiException catch (error) {
      _syncError = error.message;
      return false;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  void _applyAll(UserPreferences remote) {
    _pushEnabled = remote.pushEnabled;
    _emailEnabled = remote.emailEnabled;
    _inAppEnabled = remote.inAppEnabled;
    _notifyMessages = remote.notifyMessages;
    _notifyMentions = remote.notifyMentions;
    _notifyCalls = remote.notifyCalls;
    _readReceipts = remote.readReceipts;
    _typingIndicator = remote.typingIndicator;
    _lastSeen = remote.lastSeen;
    _autoDownloadMedia = remote.autoDownloadMedia;
    _blockUnknownCallers = remote.blockUnknownCallers;
    _hideReadReceiptsFromBlocked = remote.hideReadReceiptsFromBlocked;
  }

  /// Push one preference, rolling the local value back if the server refuses.
  ///
  /// Called by every setter. A no-op without an API, so widget tests and the
  /// signed-out state behave exactly as before.
  Future<void> _push(String apiKey, bool value) {
    final api = _api;
    if (api == null) return Future<void>.value();
    return _pushQueue = _pushQueue.then((_) async {
      try {
        await api.updatePreferences(<String, bool>{apiKey: value});
        _confirmed[apiKey] = value;
        _syncError = null;
      } on ApiException catch (error) {
        _syncError = error.message;
        final previous = _confirmed[apiKey];
        // Only roll back a field the server has actually told us about. With no
        // confirmation yet, reverting to a default would be a second guess on
        // top of the first failure.
        if (previous != null && previous != value) {
          _restore(apiKey, previous);
        }
      }
      notifyListeners();
    });
  }

  /// Put one field back to a known server value.
  void _restore(String apiKey, bool value) {
    switch (apiKey) {
      case 'push_enabled':
        _pushEnabled = value;
      case 'email_enabled':
        _emailEnabled = value;
      case 'in_app_enabled':
        _inAppEnabled = value;
      case 'notify_messages':
        _notifyMessages = value;
      case 'notify_mentions':
        _notifyMentions = value;
      case 'notify_calls':
        _notifyCalls = value;
      case 'read_receipts':
        _readReceipts = value;
      case 'typing_indicator':
        _typingIndicator = value;
      case 'last_seen':
        _lastSeen = value;
      case 'block_unknown_callers':
        _blockUnknownCallers = value;
      case 'hide_receipts_from_blocked':
        _hideReadReceiptsFromBlocked = value;
      case 'auto_download_media':
        _autoDownloadMedia = value;
    }
  }

  /// Discard the reported sync error, once a screen has shown it.
  void clearSyncError() {
    if (_syncError == null) return;
    _syncError = null;
    notifyListeners();
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

Future<void> setPushEnabled(bool v) =>
      _setBool(kPush, v, () => _pushEnabled = v, 'push_enabled');
  Future<void> setEmailEnabled(bool v) =>
      _setBool(kEmail, v, () => _emailEnabled = v, 'email_enabled');
  Future<void> setInAppEnabled(bool v) =>
      _setBool(kInApp, v, () => _inAppEnabled = v, 'in_app_enabled');
  Future<void> setNotifyMessages(bool v) =>
      _setBool(kNotifyMessages, v, () => _notifyMessages = v, 'notify_messages');
  Future<void> setNotifyMentions(bool v) =>
      _setBool(kNotifyMentions, v, () => _notifyMentions = v, 'notify_mentions');
  Future<void> setNotifyCalls(bool v) =>
      _setBool(kNotifyCalls, v, () => _notifyCalls = v, 'notify_calls');
  Future<void> setReadReceipts(bool v) =>
      _setBool(kReadReceipts, v, () => _readReceipts = v, 'read_receipts');
  Future<void> setTypingIndicator(bool v) =>
      _setBool(kTyping, v, () => _typingIndicator = v, 'typing_indicator');
  Future<void> setLastSeen(bool v) =>
      _setBool(kLastSeen, v, () => _lastSeen = v, 'last_seen');
  Future<void> setAutoDownloadMedia(bool v) => _setBool(
    kAutoDownload,
    v,
    () => _autoDownloadMedia = v,
    'auto_download_media',
  );
  Future<void> setBlockUnknownCallers(bool v) => _setBool(
    kBlockUnknown,
    v,
    () => _blockUnknownCallers = v,
    'block_unknown_callers',
  );
  Future<void> setHideReadReceiptsFromBlocked(bool v) => _setBool(
    kHideReceiptsFromBlocked,
    v,
    () => _hideReadReceiptsFromBlocked = v,
    'hide_receipts_from_blocked',
  );

  Future<void> _setBool(
    String key,
    bool value,
    VoidCallback assign, [
    String? apiKey,
  ]) {
    assign();
    notifyListeners();
    final local = _write(() => _prefs.setBool(key, value));
    // A null apiKey means the setting is this device's own business, which is
    // the case for everything written through _setString and _setDouble.
    return apiKey == null ? local : _push(apiKey, value);
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
  ///
  /// Clears the device cache and, when synced, pushes every preference back to
  /// the server too. Resetting only this device would leave the account's
  /// settings untouched and then immediately overwritten by the next sync, which
  /// reads as the button not working.
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

    final api = _api;
    if (api == null) return;
    // Only the fields that actually differ, so a reset that changes nothing does
    // not send twelve writes.
    final changes = <String, bool>{};
    for (final entry in currentPreferences().toJson().entries) {
      if (entry.value is! bool) continue;
      if (_confirmed[entry.key] != entry.value) {
        changes[entry.key] = entry.value as bool;
      }
    }
    if (changes.isEmpty) return;
    try {
      await api.updatePreferences(changes);
      changes.forEach((key, value) => _confirmed[key] = value);
      _syncError = null;
    } on ApiException catch (error) {
      _syncError = error.message;
    }
    notifyListeners();
  }

  /// The current twelve preferences as one value.
  ///
  /// Lets the sync layer and [reset] treat the store as a model without
  /// threading twelve getters through both.
  UserPreferences currentPreferences() => UserPreferences(
    pushEnabled: _pushEnabled,
    emailEnabled: _emailEnabled,
    inAppEnabled: _inAppEnabled,
    notifyMessages: _notifyMessages,
    notifyMentions: _notifyMentions,
    notifyCalls: _notifyCalls,
    readReceipts: _readReceipts,
    typingIndicator: _typingIndicator,
    lastSeen: _lastSeen,
    blockUnknownCallers: _blockUnknownCallers,
    hideReadReceiptsFromBlocked: _hideReadReceiptsFromBlocked,
    autoDownloadMedia: _autoDownloadMedia,
  );

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