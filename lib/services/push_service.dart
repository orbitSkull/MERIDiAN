import 'dart:async';

// The constructor takes a public named argument and assigns it to a private
// field, which the initializing-formals lint reads as a mistake.
// ignore_for_file: prefer_initializing_formals

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'meridian_api.dart';

/// Telling the server which handset to ring.
///
/// An interface for the same reason the rest of the app's seams exist: Firebase
/// cannot be talked to from a widget test, and a registration flow that can only
/// be tested on a device is a registration flow that does not get tested.
///
/// The implementation is deliberately quiet about its own failures. A phone that
/// cannot register still sends messages; it just stops being woken up, and that
/// is not worth an error dialog over a conversation somebody is trying to have.
abstract class PushService {
  /// Ask for permission, get a token, and register it.
  ///
  /// Returns the device id the server assigned, or null if push is off, refused,
  /// or unavailable. Null is the normal answer on a device that has said no, and
  /// nothing downstream treats it as a failure.
  Future<int?> register();

  /// Stop this device being notified and tell the server to forget it.
  Future<void> unregister();

  /// Notify this device that the server considers it alive.
  ///
  /// Without it the pruning job eventually deletes the phone somebody is
  /// currently holding, which works perfectly right up until they background the
  /// app for a week.
  Future<void> markSeen();

  /// Called when a notification has arrived and [lastOpened] now points at a
  /// conversation somebody should be taken to.
  ///
  /// Not a payload argument on purpose: the only thing a caller does with a
  /// notification is look at [lastOpened] and take it if it is there, and
  /// passing the value as well would be two sources of truth for the same thing.
  void onIncoming(void Function() handler);

  /// The conversation a notification should open.
  PushEnvelope? lastOpened;
}

/// One notification, as the client receives it.
class PushEnvelope {
  const PushEnvelope({required this.conversationId, this.senderId});

  final int conversationId;
  final int? senderId;

  /// Read a data-only payload.
  ///
  /// FCM delivers everything as strings, including numbers, so every field is
  /// parsed here rather than trusted. A malformed payload must not crash the
  /// handler that runs while the app is in the foreground.
  static PushEnvelope? fromData(Map<String, dynamic> data) {
    final raw = data['conversation_id'];
    final id = raw is int
        ? raw
        : int.tryParse(raw?.toString() ?? '');
    if (id == null) return null;

    final sender = data['sender_id'];
    return PushEnvelope(
      conversationId: id,
      senderId: sender is int ? sender : int.tryParse(sender?.toString() ?? ''),
    );
  }
}

/// The real thing. Registers with Firebase, then tells the server about the
/// token it hands back.
class FcmPushService implements PushService {
  FcmPushService({required MeridianApi api}) : _api = api;

  final MeridianApi _api;

  FirebaseMessaging? _messaging;
  int? _deviceId;

  final List<void Function()> _incoming = [];

  @override
  PushEnvelope? lastOpened;

  /// Record a conversation and tell anybody listening.
  void _noteOpened(Map<String, dynamic> data) {
    final envelope = PushEnvelope.fromData(data);
    if (envelope == null) return;
    lastOpened = envelope;
    // Copied first: a handler is free to unsubscribe itself from inside the
    // call, and mutating the list mid-iteration would skip the next listener.
    for (final handler in List.of(_incoming)) {
      handler();
    }
  }

  Future<FirebaseMessaging> _instance() async {
    final existing = _messaging;
    if (existing != null) return existing;
    await Firebase.initializeApp();
    final messaging = FirebaseMessaging.instance;
    _messaging = messaging;
    return messaging;
  }

  @override
  Future<int?> register() async {
    try {
      final messaging = await _instance();

      // Asked for on Android 13+; a no-op below that, where the permission is
      // implied by the install.
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      // The *settings*, not the return of requestPermission. That call answers
      // whether the request itself worked; whether the user said no is only
      // visible here, and reading it from the wrong one is how a refused
      // permission silently carries on as though it had been granted.
      final settings = await messaging.getNotificationSettings();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        return null;
      }

      final token = await messaging.getToken();
      if (token == null) return null;

      final device = await _api.registerDevice(
        pushToken: token,
        platform: defaultTargetPlatform.name,
      );
      _deviceId = device.id;

      // A token can be rotated at any time -- an app update, a restore onto a new
      // phone, Firebase deciding to. This is the only way to find out, and
      // without it the device goes quiet and nothing explains why.
      //
      // Fired immediately as well as on refresh, so a token that rotated while
      // the app was closed is corrected on this launch rather than at some
      // unpredictable point in the future.
      unawaited(_registerToken(token));
      messaging.onTokenRefresh.listen((refreshed) {
        unawaited(_registerToken(refreshed));
      });

      // While the app is open the socket already delivers the message. These are
      // here so that a notification which arrived some other way, or was tapped
      // while the app was in the foreground, still opens the right
      // conversation.
      FirebaseMessaging.onMessage.listen(
        (message) => _noteOpened(message.data),
      );

      FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _noteOpened(message.data),
      );

      return _deviceId;
    } on FirebaseException {
      return null;
    } on ApiException {
      // The token is good but the server would not take it. Try again next
      // launch rather than showing the user anything: nothing has broken that
      // they can do something about.
      return null;
    }
  }

  Future<void> _registerToken(String? token) async {
    if (token == null) return;
    try {
      final device = await _api.registerDevice(
        pushToken: token,
        platform: defaultTargetPlatform.name,
      );
      _deviceId = device.id;
    } on ApiException {
      // A rotated token the server refused. The next full register will try
      // again, and until then this device simply does not get woken.
    }
  }

  @override
  Future<void> markSeen() async {
    final deviceId = _deviceId;
    if (deviceId == null) return;
    try {
      await _api.markDeviceSeen(deviceId);
    } on ApiException {
      // Best effort by design; see unregister.
    }
  }

  @override
  Future<void> unregister() async {
    final deviceId = _deviceId;
    _deviceId = null;
    if (deviceId == null) return;
    try {
      await _api.deleteDevice(deviceId);
    } on ApiException {
      // The token stays valid at Firebase, so failing to remove the row means
      // this phone could keep being told about messages. There is nothing to
      // show the user -- they are signing out either way, and a sign-out that
      // fails because of a push token is still a successful sign-out as far as
      // the account is concerned. The row is pruned by last-seen eventually.
    }
  }

  @override
  void onIncoming(void Function() handler) => _incoming.add(handler);
}

/// Push that does nothing.
///
/// Used by tests, and by any build without Firebase configured, so that
/// "notifications are off" is a value rather than a crash.
class NoopPushService implements PushService {
  NoopPushService();

  @override
  PushEnvelope? lastOpened;

  @override
  Future<int?> register() async => null;

  @override
  Future<void> unregister() async {}

  @override
  Future<void> markSeen() async {}

  @override
  void onIncoming(void Function() handler) {}
}