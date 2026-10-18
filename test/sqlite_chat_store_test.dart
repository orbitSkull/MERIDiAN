import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/data/chat_models.dart';
import 'package:meridian/data/sqlite_chat_store.dart';

import 'support/ffi_database.dart';

const int me = 7;
const int them = 9;

ChatMessage message({
  int? id,
  int? seq,
  required String clientId,
  required String body,
  int conversationId = 1,
  int senderId = me,
  DateTime? createdAt,
  MessageSendState state = MessageSendState.sent,
  bool expired = false,
  bool attachmentExpired = false,
  int? attachmentId,
}) {
  return ChatMessage(
    id: id,
    conversationId: conversationId,
    clientId: clientId,
    seq: seq,
    body: body,
    kind: 'text',
    senderId: senderId,
    createdAt: createdAt ?? DateTime.utc(2026, 1, 1).add(Duration(seconds: seq ?? 0)),
    expiresAt: DateTime.utc(2026, 2, 1),
    attachmentId: attachmentId,
    expired: expired,
    attachmentExpired: attachmentExpired,
    state: state,
  );
}

void main() {
  late SqliteChatStore store;
  late Future<void> Function() cleanup;

  setUp(() async {
    final opened = await openTestChatStore();
    store = opened.store;
    cleanup = opened.cleanup;
  });

  tearDown(() async {
    await cleanup();
  });

  group('storage', () {
    test('a message round trips', () async {
      await store.upsertMessages([
        message(id: 100, seq: 1, clientId: 'c1', body: 'hello'),
      ]);

      final loaded = await store.messages(1);
      expect(loaded, hasLength(1));
      expect(loaded.single.body, 'hello');
      expect(loaded.single.id, 100);
      expect(loaded.single.seq, 1);
      expect(loaded.single.state, MessageSendState.sent);
    });

    test('booleans survive as booleans and not as 0 and 1', () async {
      await store.upsertMessages([
        message(
          id: 1,
          seq: 1,
          clientId: 'c1',
          body: '',
          expired: true,
          attachmentExpired: true,
          attachmentId: 55,
        ),
      ]);

      final loaded = (await store.messages(1)).single;
      expect(loaded.expired, isTrue);
      expect(loaded.attachmentExpired, isTrue);
      expect(loaded.attachmentId, 55);
      expect(loaded.body, isEmpty);
    });

    test('the schema has every column the queries filter on', () async {
      // Written after the schema shipped without conversation_id, which broke
      // every single query and was invisible until this ran against real
      // SQLite. A hand-written fake would never have noticed.
      await store.upsertMessages([
        message(id: 1, seq: 1, clientId: 'c1', body: 'x'),
      ]);
      final rows = await store.messages(1);
      expect(rows, hasLength(1));
    });
  });

  group('two id spaces', () {
    test('an unsent message and a synced one can hold the same server id', () async {
      // The reason row_id and server_id are separate. The unsent message took
      // local row 1; if server_id were the primary key, a synced message with
      // server id 1 would replace it.
      await store.upsertMessages([
        message(clientId: 'unsent', body: 'still going', state: MessageSendState.sending),
      ]);
      await store.upsertMessages([
        message(id: 1, seq: 1, clientId: 'synced', body: 'already there'),
      ]);

      final loaded = await store.messages(1);
      expect(loaded, hasLength(2), reason: 'the unsent message must survive');
      expect(loaded.map((m) => m.body), containsAll(['still going', 'already there']));
    });

    test('several unsent messages all have a null server id', () async {
      // A UNIQUE index treats NULLs as distinct, so this does not collide. If
      // the index were on a non-null placeholder instead, the second send would
      // fail outright.
      await store.upsertMessages([
        message(clientId: 'a', body: 'one', state: MessageSendState.sending),
        message(clientId: 'b', body: 'two', state: MessageSendState.sending),
        message(clientId: 'c', body: 'three', state: MessageSendState.sending),
      ]);

      expect((await store.messages(1)).where((m) => m.id == null), hasLength(3));
    });

    test('the server answer replaces the optimistic row rather than joining it', () async {
      await store.upsertMessages([
        message(clientId: 'c1', body: 'hi', state: MessageSendState.sending),
      ]);
      await store.upsertMessages([
        message(id: 42, seq: 3, clientId: 'c1', body: 'hi'),
      ]);

      final loaded = await store.messages(1);
      expect(loaded, hasLength(1), reason: 'one message, not two');
      expect(loaded.single.id, 42);
      expect(loaded.single.seq, 3);
      expect(loaded.single.state, MessageSendState.sent);
    });
  });

  group('ordering and paging', () {
    test('a conversation opens on the newest page, oldest first within it', () async {
      for (var i = 0; i < 6; i++) {
        await store.upsertMessages([
          message(id: 100 + i, seq: i + 1, clientId: 'c$i', body: 'm$i'),
        ]);
      }

      final page = await store.messages(1, limit: 4);
      expect(page.map((m) => m.body), ['m2', 'm3', 'm4', 'm5']);
    });

    test('beforeSeq walks backwards with no gap and no repeat', () async {
      for (var i = 0; i < 6; i++) {
        await store.upsertMessages([
          message(id: 100 + i, seq: i + 1, clientId: 'c$i', body: 'm$i'),
        ]);
      }

      final first = await store.messages(1, limit: 4);
      final second = await store.messages(1, limit: 4, beforeSeq: first.first.seq);

      expect(second.map((m) => m.body), ['m0', 'm1']);
      expect(
        [...second.map((m) => m.body), ...first.map((m) => m.body)],
        ['m0', 'm1', 'm2', 'm3', 'm4', 'm5'],
      );
    });

    test('an unsent message sits at the bottom, not above older ones', () async {
      // A conversation renders oldest first, so a message just typed belongs at
      // the end. The trap is a device whose clock is a second behind the
      // server's, which would sort a pending bubble *above* an older message
      // and make it look as though history were rewriting itself.
      await store.upsertMessages([
        message(id: 1, seq: 1, clientId: 'a', body: 'old'),
      ]);
      await store.upsertMessages([
        message(
          clientId: 'pending',
          body: 'typed just now',
          state: MessageSendState.sending,
          // Deliberately earlier than the received message: the ordering must
          // come from the pending state, not from the clock.
          createdAt: DateTime.utc(2020),
        ),
      ]);

      final loaded = await store.messages(1);
      expect(loaded.first.body, 'old');
      expect(loaded.last.body, 'typed just now');
    });

    test('conversations do not leak into each other', () async {
      await store.upsertMessages([
        message(id: 1, seq: 1, clientId: 'a', body: 'mine', conversationId: 1),
        message(id: 2, seq: 1, clientId: 'b', body: 'theirs', conversationId: 2),
      ]);

      expect((await store.messages(1)).map((m) => m.body), ['mine']);
      expect((await store.messages(2)).map((m) => m.body), ['theirs']);
    });
  });

  group('conversations', () {
    test('re-syncing a conversation does not delete its messages', () async {
      // The trap this guards: conversations are upserted with REPLACE, and
      // REPLACE deletes the conflicting row. With a cascading foreign key from
      // messages, re-syncing a conversation whose title had changed would delete
      // the user's entire history.
      await store.upsertConversations([
        const ConversationSummary(id: 1, kind: 'direct', title: 'Sam'),
      ]);
      await store.upsertMessages([
        message(id: 1, seq: 1, clientId: 'a', body: 'first'),
        message(id: 2, seq: 2, clientId: 'b', body: 'second'),
      ]);

      await store.upsertConversations([
        const ConversationSummary(id: 1, kind: 'direct', title: 'Samuel'),
      ]);

      expect(await store.messages(1), hasLength(2));
      expect((await store.conversation(1))?.title, 'Samuel');
    });

    test('the list is newest conversation first', () async {
      await store.upsertConversations([
        const ConversationSummary(
          id: 1,
          kind: 'direct',
          lastMessageAt: null,
        ),
        ConversationSummary(
          id: 2,
          kind: 'direct',
          lastMessageAt: DateTime.utc(2026, 5, 1),
        ),
      ]);

      final listed = await store.conversations();
      expect(listed.map((c) => c.id), [2, 1]);
    });
  });

  group('send lifecycle', () {
    test('markSent reconciles the optimistic row', () async {
      await store.upsertMessages([
        message(clientId: 'c1', body: 'hi', state: MessageSendState.sending),
      ]);

      await store.markSent(
        clientId: 'c1',
        id: 77,
        seq: 4,
        state: MessageSendState.sent,
      );

      final loaded = (await store.messages(1)).single;
      expect(loaded.id, 77);
      expect(loaded.seq, 4);
      expect(loaded.state, MessageSendState.sent);
      expect(loaded.failureReason, isNull);
    });

    test('markFailed records why, and a later success clears it', () async {
      await store.upsertMessages([
        message(clientId: 'c1', body: 'hi', state: MessageSendState.sending),
      ]);
      await store.markFailed(clientId: 'c1', reason: 'offline');

      var loaded = (await store.messages(1)).single;
      expect(loaded.state, MessageSendState.failed);
      expect(loaded.canRetry, isTrue);
      expect(loaded.failureReason, 'offline');

      await store.markSent(clientId: 'c1', id: 5, seq: 1, state: MessageSendState.sent);
      loaded = (await store.messages(1)).single;
      expect(loaded.failureReason, isNull, reason: 'a stale error would scare the user');
    });

    test('messageByClientId finds the reconciliation target', () async {
      await store.upsertMessages([
        message(clientId: 'unique-one', body: 'hi'),
      ]);
      expect((await store.messageByClientId('unique-one'))?.body, 'hi');
      expect(await store.messageByClientId('nothing'), isNull);
    });
  });

  group('outbox', () {
    OutboxEntry entry(String clientId, {required DateTime nextAttemptAt, int attempts = 0}) {
      return OutboxEntry(
        clientId: clientId,
        conversationId: 1,
        body: 'body $clientId',
        createdAt: DateTime.utc(2026, 1, 1),
        attempts: attempts,
        nextAttemptAt: nextAttemptAt,
      );
    }

    test('only due entries come back', () async {
      final now = DateTime.utc(2026, 1, 2);
      await store.add(entry('due', nextAttemptAt: now));
      await store.add(entry('later', nextAttemptAt: now.add(const Duration(minutes: 5))));

      final due = await store.due(now);
      expect(due.map((e) => e.clientId), ['due']);
    });

    test('the oldest deadline comes first', () async {
      final now = DateTime.utc(2026, 1, 2);
      await store.add(entry('second', nextAttemptAt: now));
      await store.add(entry('first', nextAttemptAt: now.subtract(const Duration(minutes: 1))));

      expect((await store.due(now)).map((e) => e.clientId), ['first', 'second']);
    });

    test('defer counts the attempt and pushes the next one out', () async {
      final now = DateTime.utc(2026, 1, 2);
      await store.add(entry('c1', nextAttemptAt: now));

      await store.defer(
        'c1',
        error: 'offline',
        nextAttemptAt: now.add(const Duration(seconds: 5)),
      );

      final updated = await store.byClientId('c1');
      expect(updated?.attempts, 1);
      expect(updated?.lastError, 'offline');
      expect(await store.due(now), isEmpty, reason: 'backoff must actually hold it back');
      expect(await store.due(now.add(const Duration(seconds: 6))), hasLength(1));
    });

    test('resolve removes the entry', () async {
      await store.add(entry('c1', nextAttemptAt: DateTime.utc(2026)));
      await store.resolve('c1');
      expect(await store.count(), 0);
    });

    test('deferring something that is gone is harmless', () async {
      await store.defer('never-existed', error: 'x', nextAttemptAt: DateTime.now());
      expect(await store.count(), 0);
    });
  });

  group('clear', () {
    test('sign out leaves nothing behind', () async {
      await store.upsertConversations([const ConversationSummary(id: 1, kind: 'direct')]);
      await store.upsertMessages([message(id: 1, seq: 1, clientId: 'a', body: 'secret')]);
      await store.add(
        OutboxEntry(
          clientId: 'pending',
          conversationId: 1,
          body: 'unsent',
          createdAt: DateTime.utc(2026),
          attempts: 0,
          nextAttemptAt: DateTime.utc(2026),
        ),
      );

      await store.clear();

      expect(await store.messages(1), isEmpty);
      expect(await store.conversations(), isEmpty);
      expect(await store.count(), 0);
    });
  });
}