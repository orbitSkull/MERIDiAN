import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/services/push_registration.dart';
import 'package:meridian/services/push_service.dart';

import 'support/stub_meridian_api.dart';

/// Registering, and un-registering.
///
/// The rule these exist for: a Firebase token does not know whose it is. If the
/// device row survives a sign-out, the next person to sign in on a sold or
/// shared phone is woken up by the previous owner's messages, and nothing in
/// the app has any way to explain why.
class _FakePush implements PushService {
  int registerCalls = 0;
  int unregisterCalls = 0;
  int seenCalls = 0;
  Object? throwOnRegister;
  Object? throwOnUnregister;

  @override
  PushEnvelope? lastOpened;

  /// What register() hands back.
  int? deviceId = 1;

  @override
  Future<int?> register() async {
    registerCalls++;
    final failure = throwOnRegister;
    if (failure != null) throw failure;
    return deviceId;
  }

  @override
  Future<void> unregister() async {
    unregisterCalls++;
    final failure = throwOnUnregister;
    if (failure != null) throw failure;
  }

  @override
  Future<void> markSeen() async => seenCalls++;

  @override
  void onForegroundMessage(void Function(PushEnvelope) handler) {}
}

class _Api extends StubMeridianApi {}

/// Lets the deferred bind microtask run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('PushRegistration', () {
    test('signing in registers the device', () async {
      final push = _FakePush();
      final registration = PushRegistration(service: push);

      registration.bindApi(_Api());
      await _settle();

      expect(push.registerCalls, 1);
      expect(registration.isRegistered, isTrue);
    });

    test('signing out forgets the device', () async {
      final push = _FakePush();
      final registration = PushRegistration(service: push);

      registration.bindApi(_Api());
      await _settle();
      registration.bindApi(null);
      await _settle();

      // Without this the token stays valid at Firebase and keeps delivering.
      expect(push.unregisterCalls, 1);
      expect(registration.isRegistered, isFalse);
    });

    test('signing out and back in registers again', () async {
      final push = _FakePush();
      final registration = PushRegistration(service: push);

      registration.bindApi(_Api());
      await _settle();
      registration.bindApi(null);
      await _settle();
      registration.bindApi(_Api());
      await _settle();

      expect(push.registerCalls, 2);
      expect(push.unregisterCalls, 1);
    });

    test('nothing happens before there is a session', () async {
      final push = _FakePush();
      final registration = PushRegistration(service: push);

      registration.bindApi(null);
      await _settle();

      // Registering with no session would register against nobody.
      expect(push.registerCalls, 0);
    });

    test('a refused permission is not a failure', () async {
      final push = _FakePush()..deviceId = null;
      final registration = PushRegistration(service: push);

      registration.bindApi(_Api());
      await _settle();

      // Somebody who said no is not registered and is not retried in a loop.
      // Their chats work; they are simply not woken up.
      expect(registration.isRegistered, isFalse);
      expect(push.registerCalls, 1);
    });

    test('a server that refuses registration does not break sign-in', () async {
      final push = _FakePush()..throwOnRegister = Exception('503');
      final registration = PushRegistration(service: push);

      registration.bindApi(_Api());
      await _settle();

      expect(registration.isRegistered, isFalse);
    });

    test('a failed unregister does not break sign-out', () async {
      final push = _FakePush();
      final registration = PushRegistration(service: push);

      registration.bindApi(_Api());
      await _settle();

      push.throwOnUnregister = Exception('503');
      registration.bindApi(null);
      await _settle();

      // The person is signed out either way. Failing here would leave them
      // stuck on a screen they have already left.
      expect(registration.isRegistered, isFalse);
    });

    test('markSeen only speaks for a registered device', () async {
      final push = _FakePush();
      final registration = PushRegistration(service: push);

      await registration.markSeen();
      expect(push.seenCalls, 0);

      registration.bindApi(_Api());
      await _settle();
      await registration.markSeen();
      expect(push.seenCalls, 1);
    });

    test('a pending notification is taken exactly once', () async {
      final push = _FakePush();
      push.lastOpened = const PushEnvelope(conversationId: 42);
      final registration = PushRegistration(service: push);

      expect(registration.takePendingOpen()?.conversationId, 42);
      // Taking it clears it, so a second read does not reopen the same
      // conversation on the next frame.
      expect(registration.takePendingOpen(), isNull);
    });

    test('no service means nothing is registered', () async {
      final registration = PushRegistration();

      registration.bindApi(_Api());
      await _settle();

      expect(registration.isRegistered, isFalse);
    });
  });

  group('PushEnvelope', () {
    test('reads a well-formed payload', () {
      final envelope = PushEnvelope.fromData({
        'type': 'message',
        'conversation_id': '17',
        'sender_id': '9',
      });

      expect(envelope?.conversationId, 17);
      expect(envelope?.senderId, 9);
    });

    test('reads numbers that arrived as numbers', () {
      final envelope = PushEnvelope.fromData({'conversation_id': 17});
      expect(envelope?.conversationId, 17);
    });

    test('a payload with no conversation is ignored', () {
      // Thrown by the handler that runs in the foreground, where an exception
      // takes down whatever was mid-render.
      expect(PushEnvelope.fromData({'type': 'message'}), isNull);
      expect(PushEnvelope.fromData({'conversation_id': 'not a number'}), isNull);
      expect(PushEnvelope.fromData({}), isNull);
    });

    test('a missing sender is allowed', () {
      // A group notification says who, but a token-refresh or a future payload
      // might not, and an absent sender is not a reason to drop the whole thing.
      final envelope = PushEnvelope.fromData({'conversation_id': '17'});
      expect(envelope?.senderId, isNull);
    });
  });
}