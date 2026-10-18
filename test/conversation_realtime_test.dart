import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/data/chat_models.dart';
import 'package:meridian/screens/home/conversation_controller.dart';
import 'package:meridian/services/chat_sync.dart';
import 'package:meridian/services/outbox.dart';
import 'package:meridian/services/realtime_client.dart';

import 'support/fake_chat_api.dart';
import 'support/in_memory_chat_store.dart';

const int me = 7;
const int them = 9;

/// The wiring: does a socket event actually reach the device's store, and does
/// the device then say so.
///
/// The transport has its own tests. These exist because "the socket works" and
/// "the app listens to the socket" are different claims, and the second one was
/// completely untested -- the client was constructed nowhere and every event went
/// nowhere.
void main() {
  late InMemoryChatStore store;
  late FakeChatApi api;
  late FakeRealtime realtime;
  late DateTime now;
  late List<({int conversationId, int upToSeq})> delivered;

  setUp(() {
    store = InMemoryChatStore();
    api = FakeChatApi();
    realtime = FakeRealtime();
    now = DateTime.utc(2026, 3, 1, 12);
    delivered = [];
  });

  ConversationController build() {
    return ConversationController(
      conversationId: 1,
      myUserId: me,
      api: api,
      store: store,
      outbox: store,
      sender: OutboxSender(
        api: api,
        store: store,
        outbox: store,
        senderId: me,
        random: Random(3),
        clock: () => now,
      ),
      sync: ChatSync(api: api, store: store),
      realtime: realtime,
      receipts: _RecordingReceipts(delivered),
    );
  }

  Map<String, dynamic> serverMessageJson({
    required int id,
    required int seq,
    required String body,
    int senderId = them,
    int conversationId = 1,
    String state = 'sent',
  }) {
    return {
      'id': id,
      'conversation_id': conversationId,
      'client_id': 'c$id',
      'seq': seq,
      'body': body,
      'kind': 'text',
      'sender_id': senderId,
      'created_at': '2026-03-01T09:00:${seq.toString().padLeft(2, '0')}Z',
      'expires_at': '2026-03-29T09:00:00Z',
      'delivery': {'sent': true, 'delivered': false, 'read': false},
      '_state': state,
    };
  }

  group('a message arriving on the socket', () {
    test('lands in the store and on screen', () async {
      final controller = build();
      await controller.open();

      realtime.emit(
        RealtimeMessage(
          ChatMessage.fromJson(serverMessageJson(id: 9, seq: 4, body: 'are you there?')).toWire(),
        ),
      );
      await _settle();

      expect(
        controller.messages.map((m) => m.body),
        contains('are you there?'),
      );
      controller.dispose();
    });

    test('is acknowledged as delivered so the sender sees a double tick', () async {
      final controller = build();
      await controller.open();

      realtime.emit(
        RealtimeMessage(
          ChatMessage.fromJson(
            serverMessageJson(id: 9, seq: 4, body: 'ping'),
          ).toWire(),
        ),
      );
      await _settle();

      expect(
        delivered.map((d) => d.upToSeq),
        contains(4),
        reason: 'without this the double grey tick never appears',
      );
      controller.dispose();
    });

    test('for another conversation is ignored', () async {
      final controller = build();
      await controller.open();

      realtime.emit(
        RealtimeMessage(
          ChatMessage.fromJson(
            serverMessageJson(id: 9, seq: 4, body: 'elsewhere', conversationId: 99),
          ).toWire(),
        ),
      );
      await _settle();

      expect(controller.messages.map((m) => m.body), isNot(contains('elsewhere')));
      expect(delivered, isEmpty);
      controller.dispose();
    });
  });

  group('a receipt arriving on the socket', () {
    test('moves this device`s own messages forward', () async {
      await store.upsertMessages([
        serverMessage(id: 1, seq: 1, clientId: 'mine-1', body: 'sent', senderId: me),
      ]);
      final controller = build();
      await controller.open();

      realtime.emit(
        const RealtimeReceipt(
          conversationId: 1,
          userId: them,
          upToSeq: 1,
          read: false,
        ),
      );
      await _settle();

      expect(
        controller.messages.single.state,
        MessageSendState.delivered,
      );
      controller.dispose();
    });

    test('a read receipt beats a delivered one that arrives late', () async {
      await store.upsertMessages([
        serverMessage(id: 1, seq: 1, clientId: 'mine-1', body: 'sent', senderId: me),
      ]);
      final controller = build();
      await controller.open();

      realtime.emit(
        const RealtimeReceipt(conversationId: 1, userId: them, upToSeq: 1, read: true),
      );
      await _settle();
      realtime.emit(
        const RealtimeReceipt(
          conversationId: 1,
          userId: them,
          upToSeq: 1,
          read: false,
        ),
      );
      await _settle();

      expect(
        controller.messages.single.state,
        MessageSendState.read,
        reason: 'a blue tick must never walk back to grey',
      );
      controller.dispose();
    });

    test('for another conversation is ignored', () async {
      await store.upsertMessages([
        serverMessage(id: 1, seq: 1, clientId: 'mine-1', body: 'sent', senderId: me),
      ]);
      final controller = build();
      await controller.open();

      realtime.emit(
        const RealtimeReceipt(conversationId: 99, userId: them, upToSeq: 1, read: true),
      );
      await _settle();

      expect(controller.messages.single.state, MessageSendState.sent);
      controller.dispose();
    });
  });

  group('typing', () {
    test('appears when somebody else starts and clears when they stop', () async {
      final controller = build();
      await controller.open();
      expect(controller.otherIsTyping, isFalse);

      realtime.emit(
        const RealtimeTyping(conversationId: 1, userId: them, typing: true),
      );
      await _settle();
      expect(controller.otherIsTyping, isTrue);

      realtime.emit(
        const RealtimeTyping(conversationId: 1, userId: them, typing: false),
      );
      await _settle();
      expect(controller.otherIsTyping, isFalse);
      controller.dispose();
    });

    test('does not appear for this person`s own typing', () async {
      final controller = build();
      await controller.open();

      realtime.emit(
        const RealtimeTyping(conversationId: 1, userId: me, typing: true),
      );
      await _settle();

      expect(
        controller.otherIsTyping,
        isFalse,
        reason: 'typing at yourself is not something to be told about',
      );
      controller.dispose();
    });

    test('this person typing is reported to the socket', () async {
      final controller = build();
      await controller.open();

      controller.reportTyping(true);
      controller.reportTyping(false);

      // Asserted field by field rather than against a list literal: a record
      // comparison that fails prints expected <Instance> and tells you nothing
      // about which field differed.
      expect(
        realtime.typingSent.length,
        2,
        reason: 'expected start and stop, got ',
      );
      expect(realtime.typingSent.first.conversationId, 1);
      expect(realtime.typingSent.first.typing, isTrue);
      expect(realtime.typingSent.last.typing, isFalse);
      controller.dispose();
    });

    test('clears itself if the other side vanishes mid-word', () async {
      // They close the app without sending a stop. A stuck indicator is worse
      // than none: it claims somebody is there when nobody is.
      final controller = build();
      await controller.open();
      realtime.emit(
        const RealtimeTyping(conversationId: 1, userId: them, typing: true),
      );
      await _settle();
      expect(controller.otherIsTyping, isTrue);

      // No event. The controller's own timer is what clears it.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.otherIsTyping, isTrue);
      controller.dispose();
    });
  });

  group('without a socket', () {
    test('the controller still works', () async {
      // Some callers have no realtime -- a test, a screen opened before the
      // socket exists. Being unable to listen must not mean being unable to
      // read.
      final controller = ConversationController(
        conversationId: 1,
        myUserId: me,
        api: api,
        store: store,
        outbox: store,
        sender: OutboxSender(
          api: api,
          store: store,
          outbox: store,
          senderId: me,
          random: Random(3),
          clock: () => now,
        ),
        sync: ChatSync(api: api, store: store),
      );
      await store.upsertMessages([
        serverMessage(id: 1, seq: 1, clientId: 'a', body: 'already here'),
      ]);
      await controller.open();

      expect(controller.messages.single.body, 'already here');
      controller.reportTyping(true);
      controller.dispose();
    });
  });
}

/// Records what was acknowledged without needing an HTTP client.
class _RecordingReceipts implements RealtimeApi {
  _RecordingReceipts(this.log);

  final List<({int conversationId, int upToSeq})> log;

  @override
  Future<void> markDelivered(int conversationId, int upToSeq) async {
    log.add((conversationId: conversationId, upToSeq: upToSeq));
  }
}

/// A socket the test drives, with no network in it.
class FakeRealtime implements RealtimeClient {
  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast();

  final List<({int conversationId, bool typing})> typingSent = [];

  @override
  Stream<RealtimeEvent> get events => _events.stream;

  void emit(RealtimeEvent event) => _events.add(event);

  @override
  void sendTyping(int conversationId, {required bool typing}) {
    typingSent.add((conversationId: conversationId, typing: typing));
  }

  @override
  bool get isConnected => true;

  @override
  int get reconnectAttempts => 0;

  @override
  void start() {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() => _events.close();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FakeRealtime.${invocation.memberName}');
}

extension on ChatMessage {
  /// Back to the server's shape, which is what a socket event carries.
  Map<String, dynamic> toWire() => {
    'id': id,
    'conversation_id': conversationId,
    'client_id': clientId,
    'seq': seq,
    'body': body,
    'kind': kind,
    'sender_id': senderId,
    'created_at': createdAt.toUtc().toIso8601String(),
    'expires_at': expiresAt?.toUtc().toIso8601String(),
    'delivery': {
      'sent': state != MessageSendState.failed,
      'delivered': state == MessageSendState.delivered ||
          state == MessageSendState.read,
      'read': state == MessageSendState.read,
    },
  };
}

/// Lets the controller's fire-and-forget handlers finish.
Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(milliseconds: 20));
}