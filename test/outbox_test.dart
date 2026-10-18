import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/data/chat_models.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/outbox.dart';

import 'support/fake_chat_api.dart';
import 'support/in_memory_chat_store.dart';

void main() {
  group('ChatMessage.fromJson', () {
    test('reads the server shape', () {
      final message = ChatMessage.fromJson({
        'id': 42,
        'conversation_id': 7,
        'client_id': 'abc',
        'seq': 5,
        'body': 'hello',
        'kind': 'text',
        'sender_id': 9,
        'created_at': '2026-03-01T10:00:00Z',
        'expires_at': '2026-03-29T10:00:00Z',
        'delivery': {'sent': true, 'delivered': true, 'read': false},
      });

      expect(message.id, 42);
      expect(message.seq, 5);
      expect(message.state, MessageSendState.delivered);
      expect(message.createdAt.isUtc, isTrue);
      expect(message.expiresAt!.isAfter(message.createdAt), isTrue);
    });

    test('read wins over delivered regardless of what else is set', () {
      // Two of somebody's devices racing can produce this. The tick must not go
      // backwards because a read receipt arrived before a delivery receipt.
      final message = ChatMessage.fromJson({
        'id': 1,
        'conversation_id': 1,
        'client_id': 'a',
        'seq': 1,
        'body': '',
        'kind': 'text',
        'sender_id': 1,
        'created_at': '2026-03-01T10:00:00Z',
        'expires_at': '2026-03-29T10:00:00Z',
        'delivery': {'sent': true, 'delivered': false, 'read': true},
      });
      expect(message.state, MessageSendState.read);
    });

    test('an expired message keeps its shape and says so', () {
      // The body is empty and must stay empty; what matters is that the row
      // still describes a message in the right place.
      final message = ChatMessage.fromJson({
        'id': 1,
        'conversation_id': 7,
        'client_id': 'a',
        'seq': 1,
        'body': '',
        'kind': 'text',
        'sender_id': 1,
        'created_at': '2026-03-01T10:00:00Z',
        'expires_at': '2026-03-29T10:00:00Z',
        'expired': true,
        'attachment_expired': true,
        'attachment_id': 55,
        'delivery': {'sent': true},
      });

      expect(message.expired, isTrue);
      expect(message.attachmentExpired, isTrue);
      expect(message.attachmentId, 55, reason: 'the client needs it to say "expired"');
    });

    test('a payload without the expiry fields is treated as live', () {
      // A server that predates the field is not an expired message, and
      // defaulting to expired would blank every conversation on upgrade.
      final message = ChatMessage.fromJson({
        'id': 1,
        'conversation_id': 1,
        'client_id': 'a',
        'seq': 1,
        'body': 'hi',
        'kind': 'text',
        'sender_id': 1,
        'created_at': '2026-03-01T10:00:00Z',
        'expires_at': '2026-03-29T10:00:00Z',
      });

      expect(message.expired, isFalse);
      expect(message.attachmentExpired, isFalse);
    });

    test('a missing delivery block does not become a delivered tick', () {
      final message = ChatMessage.fromJson({
        'id': 1,
        'conversation_id': 1,
        'client_id': 'a',
        'seq': 1,
        'body': 'hi',
        'kind': 'text',
        'sender_id': 1,
        'created_at': '2026-03-01T10:00:00Z',
        'expires_at': '2026-03-29T10:00:00Z',
      });

      expect(message.state, MessageSendState.sent);
    });

    test('a payload without conversation_id is rejected', () {
      // Defaulting this to 0 would file the message in a conversation that does
      // not exist, where nothing can show it: a chat that silently stops
      // updating, with no error anywhere.
      expect(
        () => ChatMessage.fromJson({
          'id': 1,
          'client_id': 'a',
          'seq': 1,
          'body': 'hi',
          'kind': 'text',
          'sender_id': 1,
          'created_at': '2026-03-01T10:00:00Z',
          'expires_at': '2026-03-29T10:00:00Z',
        }),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('backoff', () {
    test('grows and then stops growing', () {
      expect(OutboxEntry.backoffFor(0), Duration.zero);
      expect(OutboxEntry.backoffFor(1), const Duration(seconds: 5));
      expect(OutboxEntry.backoffFor(2), const Duration(seconds: 10));
      expect(OutboxEntry.backoffFor(3), const Duration(seconds: 20));
      expect(OutboxEntry.backoffFor(20), const Duration(seconds: 300));
    });

    test('never exceeds the cap however many attempts there have been', () {
      for (var attempts = 1; attempts < 50; attempts++) {
        expect(
          OutboxEntry.backoffFor(attempts).inSeconds,
          lessThanOrEqualTo(300),
          reason: 'attempt $attempts',
        );
      }
    });
  });

  group('OutboxSender', () {
    late InMemoryChatStore store;
    late FakeChatApi api;
    late DateTime now;

    setUp(() {
      store = InMemoryChatStore();
      api = FakeChatApi();
      now = DateTime.utc(2026, 3, 1, 12);
    });

    OutboxSender build({Random? random}) {
      return OutboxSender(
        api: api,
        store: store,
        outbox: store,
        senderId: 7,
        random: random ?? Random(1234),
        clock: () => now,
      );
    }

    test('a send shows up immediately and is not sent yet', () async {
      final sender = build();
      final message = await sender.send(1, 'hello');

      expect(message.state, MessageSendState.sending);
      expect((await store.messages(1)).single.body, 'hello');
      expect(api.sendCount, 0, reason: 'the UI must not wait for the network');
      expect(await store.count(), 1);
    });

    test('client ids are unique and uuid shaped', () async {
      final sender = build();
      final ids = <String>{};
      for (var i = 0; i < 50; i++) {
        ids.add((await sender.send(1, 'm$i')).clientId);
      }
      expect(ids, hasLength(50));
      for (final id in ids) {
        expect(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
              .hasMatch(id),
          isTrue,
          reason: '$id is not a v4 uuid',
        );
      }
    });

    test('a flush reconciles the bubble and empties the outbox', () async {
      final sender = build();
      final sent = await sender.send(1, 'hello');
      api.onSend = (conversationId, clientId, body) async => serverMessage(
        id: 99,
        seq: 3,
        clientId: clientId,
        body: body,
      );

      final report = await sender.flush();

      expect(report.sent, 1);
      expect(await store.count(), 0);

      final stored = (await store.messages(1)).single;
      expect(stored.id, 99);
      expect(stored.seq, 3);
      expect(stored.state, MessageSendState.sent);
      expect(stored.clientId, sent.clientId, reason: 'same message, reconciled');
      expect(stored.body, 'hello');
    });

    test('a retry reuses the same client id, so the server deduplicates', () async {
      final sender = build();
      final sent = await sender.send(1, 'hello');
      api.onSend = (conversationId, clientId, body) async =>
          throw ApiException('offline');

      await sender.flush();
      final seen = api.sendClientIds.single;

      now = now.add(const Duration(minutes: 10));
      api.onSend = (conversationId, clientId, body) async => serverMessage(
        id: 100,
        seq: 4,
        clientId: clientId,
        body: body,
      );
      await sender.flush();

      expect(seen, sent.clientId);
      expect(api.sendClientIds.toSet(), {sent.clientId});
      expect((await store.messages(1)).single.id, 100);
    });

    test('a failure backs off instead of retrying in a loop', () async {
      final sender = build();
      await sender.send(1, 'hello');
      api.onSend = (conversationId, clientId, body) async =>
          throw ApiException('offline');

      final report = await sender.flush();

      expect(report.deferred, 1);
      expect(report.offline, isTrue);
      expect(await store.count(), 1, reason: 'still owed to the server');
      expect(
        (await store.messages(1)).single.state,
        MessageSendState.sending,
        reason: 'a message that will be retried is not a failed message',
      );
      expect(await store.due(now), isEmpty, reason: 'backoff must hold it back');
    });

    test('jitter spreads retries but never moves one earlier', () async {
      final delays = <Duration>{};
      for (final seed in [1, 2, 3, 4, 5, 6, 7, 8]) {
        final sender = build(random: Random(seed));
        // Keyed off the message sent in *this* iteration. Reading it off
        // api.sendClientIds would keep returning the first entry ever sent,
        // whose nextAttemptAt is already fixed from the first iteration.
        final message = await sender.send(1, 'hello');
        api.onSend = (conversationId, clientId, body) async =>
            throw ApiException('offline');
        await sender.flush();
        final entry = await store.byClientId(message.clientId);
        delays.add(entry!.nextAttemptAt.difference(now));
      }

      expect(delays.length, greaterThan(1), reason: 'identical backoffs are a herd');
      for (final delay in delays) {
        expect(
          delay.inMilliseconds,
          greaterThanOrEqualTo(OutboxEntry.backoffFor(1).inMilliseconds * 0.7),
        );
        expect(delay, lessThanOrEqualTo(const Duration(seconds: 7)));
      }
    });

    test('a blocked send is failed rather than retried forever', () async {
      // 403 is the server refusing because the recipient blocked the sender.
      // Retrying that every five minutes forever leaves a ghost in the outbox
      // and a retry button that can never work.
      final sender = build();
      await sender.send(1, 'hello');
      api.onSend = (conversationId, clientId, body) async =>
          throw ApiException('You cannot message this person', statusCode: 403);

      final report = await sender.flush();

      expect(report.abandoned, 1);
      expect(await store.count(), 0);

      final stored = (await store.messages(1)).single;
      expect(stored.state, MessageSendState.failed);
      expect(stored.canRetry, isTrue);
      expect(stored.body, 'hello', reason: 'the body stays so it can be retried');
    });

    test('a 401 is retried, not abandoned', () async {
      // The session expired and the client will refresh it. Throwing the
      // message away here would lose somebody's words because their token was
      // old, which is the worst possible reason to lose a message.
      final sender = build();
      await sender.send(1, 'hello');
      api.onSend = (conversationId, clientId, body) async =>
          throw ApiException('expired', statusCode: 401);

      final report = await sender.flush();

      expect(report.abandoned, 0);
      expect(report.deferred, 1);
      expect(await store.count(), 1);
    });

    test('giving up keeps the message and offers a retry', () async {
      final sender = build();
      await sender.send(1, 'hello');
      api.onSend = (conversationId, clientId, body) async =>
          throw ApiException('offline');

      // Run past the attempt ceiling.
      for (var i = 0; i < OutboxEntry.maxAttempts; i++) {
        await sender.flush();
        final entry = await store.byClientId((await store.messages(1)).single.clientId);
        if (entry == null) break;
        now = entry.nextAttemptAt.add(const Duration(seconds: 1));
      }

      final stored = (await store.messages(1)).single;
      expect(stored.state, MessageSendState.failed);
      expect(stored.body, 'hello');
      expect(await store.count(), 0);
    });

    test('concurrent flushes share one pass', () async {
      final sender = build();
      await sender.send(1, 'one');
      await sender.send(1, 'two');
      api.onSend = (conversationId, clientId, body) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return serverMessage(id: 1, seq: 1, clientId: clientId, body: body);
      };

      final results = await Future.wait([sender.flush(), sender.flush()]);

      // Two flushes over the same rows would send each message twice.
      expect(api.sendCount, 2);
      expect(results[0].sent, 2);
      expect(results[1].sent, 2, reason: 'the second caller joined the first');
    });

    test('one bad message does not stop the rest of the queue', () async {
      final sender = build();
      await sender.send(1, 'good one');
      await sender.send(1, 'blocked one');
      api.onSend = (conversationId, clientId, body) async {
        if (body == 'blocked one') {
          throw ApiException('blocked', statusCode: 403);
        }
        return serverMessage(id: 5, seq: 5, clientId: clientId, body: body);
      };

      final report = await sender.flush();

      expect(report.sent, 1);
      expect(report.abandoned, 1);

      // By body rather than by state order: display order is by sequence, and
      // the blocked message never got one, so asserting positions here would be
      // asserting the sort order rather than the behaviour.
      final byBody = {for (final m in await store.messages(1)) m.body: m.state};
      expect(byBody['good one'], MessageSendState.sent);
      expect(byBody['blocked one'], MessageSendState.failed);
    });
  });
}
