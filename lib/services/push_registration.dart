import 'dart:async';

import 'package:flutter/foundation.dart';

import 'meridian_api.dart';
import 'push_service.dart';

/// Ties the push token to the sign-in session.
///
/// A token outlives an account. That is the whole reason this exists: Firebase
/// does not know who signed out, so unless the device row is removed on the way
/// out, the next person to sign in on a sold or shared phone keeps being woken
/// up by the previous one's messages.
///
/// Bind and unbind follow the session rather than the app, which means a crash
/// between sign-in and registration cannot leave a stale row pointing at an
/// account nobody is in -- registration is re-attempted on every launch.
class PushRegistration extends ChangeNotifier {
  PushRegistration({PushService? service})
    : _service = service ?? NoopPushService();

  PushService _service;
  MeridianApi? _api;
  bool _registered = false;

  /// Whether this device currently has a token with the server.
  bool get isRegistered => _registered;

  void useService(PushService service) {
    _service = service;
    unawaited(register());
    notifyListeners();
  }

  /// Register, if signed in.
  ///
  /// Cheap and idempotent, and called on every launch: a token that rotated
  /// while the app was closed is corrected here rather than at some
  /// unpredictable point in the future.
  void bindApi(MeridianApi? api) {
    if (api == null) {
      if (_api != null) unawaited(unregister());
      return;
    }
    if (identical(api, _api)) return;

    // Deferred, and for the same reason SettingsStore.bindApi defers: this is
    // called from a provider's update callback, which runs during build, and
    // notifying during build is an error in Flutter.
    scheduleMicrotask(() {
      if (identical(_api, api)) return;
      _api = api;
      unawaited(register());
    });
  }

  Future<void> register() async {
    final api = _api;
    if (api == null || _registered) return;
    _service.onIncoming(notifyListeners);

    try {
      final deviceId = await _service.register();
      if (_registered == (deviceId != null)) return;
      _registered = deviceId != null;
      notifyListeners();
    } on Exception {
      // Nothing here is worth showing the user. A phone that cannot register
      // still sends messages; it just stops being woken up.
      //
      // Deliberately broader than ApiException: this is housekeeping, and no
      // failure to do it should be able to interrupt a session. Anything the
      // network or a platform channel throws is of the same kind here.
    }
  }

  /// Forget this device, so it stops being notified for an account it has left.
  Future<void> unregister() async {
    _api = null;
    if (!_registered) return;
    _registered = false;
    try {
      await _service.unregister();
    } on Exception {
      // A sign-out must not fail because of a push token. The row is pruned by
      // last-seen eventually, and in the meantime the token belongs to an
      // account that no longer exists on this device.
    }
    notifyListeners();
  }

  /// Note that this device is in use.
  ///
  /// Called when a conversation opens. Without it the pruning job eventually
  /// deletes the phone somebody is currently holding, which works perfectly
  /// right up until they background the app for a week.
  Future<void> markSeen() async {
    if (!_registered) return;
    try {
      await _service.markSeen();
    } on Exception {
      // Best effort by design; see unregister.
    }
  }

  /// The conversation a tapped notification should open, if any.
  PushEnvelope? takePendingOpen() {
    final envelope = _service.lastOpened;
    _service.lastOpened = null;
    return envelope;
  }
}