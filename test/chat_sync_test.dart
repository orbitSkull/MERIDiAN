import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/data/chat_models.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/chat_sync.dart';

import 'support/fake_chat_api.dart';
import 'support/in_memory_chat_store.dart';

void main() {
  late InMemoryChatStore store;
  late FakeChatApi api;
  late ChatSync sync;

  setUp(() {
    store = InMemoryChatStore();
    api = FakeChatApi();
    sync = ChatSync(api: api, store: store);
  });

  List<ChatMessage> page(int fromSeq, int count, {int conversationId = 1}) {
    return [
      for (var i = 0; i < count; i++)
        serverMessage(
          id: fromSeq + i,
          seq: fromSeq + i,
          // Unique across conversations as well as within one: clientId is a
          // device-generated uuid, so two conversations can never share one,
          // and the local store indexes it globally.
          clientId: 'c$conversationId-${fromSeq + i}',
          body: 'm${fromSeq + i}',
          conversationId: conversationId,
        ),
    ];
  }

  group('fetching', () {
    test('a conversation lands in the store', () async {
      api.seed(1, page(1, 3));
      final outcome = await sync.syncConversation(1);
      expect(outcome.messages, 3);
      expect((await store.messages(1)).map((m) => m.body), ['m1', 'm2', 'm3']);
      expect(outcome.newestSeq, 3);
    });

    test('pages are walked backwards until the server says there is no more', () async {
      api.seed(1, page(1, 7));
      final outcome = await sync.syncConversation(1);
      // One page of 50 covers all 7, so nothing is left to page to.
      expect(outcome.pages, 1);
      expect((await store.messages(1)).map((m) => m.body),
          ['m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7']);
    });

    test('a long conversation stops at the page ceiling and says so', () async {
      api.seed(1, page(1, 1000));
      final outcome = await sync.syncConversation(1);
      expect(outcome.pages, ChatSync.maxPagesPerPass);
      expect(outcome.stoppedEarly, isTrue);
      expect(outcome.messages, ChatSync.maxPagesPerPass * ChatSync.pageSize);
    });

    test('going offline keeps what was already fetched', () async {
      api.seed(1, page(1, 1000));
      api.messagesError = ApiException('connection failed');
      api.failMessagesAfterCalls = 2;

      final outcome = await sync.syncConversation(1);

      expect(outcome.stoppedEarly, isTrue);
      expect(await store.messages(1), hasLength(ChatSync.pageSize));
    });

    test('an empty conversation is not an error', () async {
      final outcome = await sync.syncConversation(99);
      expect(outcome.messages, 0);
      expect(outcome.stoppedEarly, isFalse);
    });
  });

  group('nothing is ever deleted', () {
    test('a message the server no longer lists stays on the device', () async {
      api.seed(1, page(1, 5));
      await sync.syncConversation(1);
      expect(await store.messages(1), hasLength(5));

      // Retention has run: everything but the newest has aged out of the
      // server's window.
      api.expireAll(1);
      api.seed(1, page(5, 1));
      await sync.syncConversation(1);

      expect(await store.messages(1), hasLength(5),
          reason: 'the device is the archive; the server is a window');
    });

    test('an emptied server does not empty the conversation', () async {
      api.seed(1, page(1, 3));
      await sync.syncConversation(1);
      api.expireAll(1);
      await sync.syncConversation(1);
      expect(await store.messages(1), hasLength(3));
    });
  });

  group('expired messages', () {
    test('they are stored, marked, and not silently dropped', () async {
      api.seed(1, [
        serverMessage(id: 1, seq: 1, clientId: 'a', body: 'kept'),
        serverMessage(id: 2, seq: 2, clientId: 'b', body: '',
            expired: true, attachmentExpired: true),
      ]);

      await sync.syncConversation(1);

      final stored = await store.messages(1);
      expect(stored, hasLength(2));
      expect(stored.last.expired, isTrue);
      expect(stored.last.attachmentExpired, isTrue);
      expect(stored.last.body, isEmpty);
    });
  });

  group('ticks come from the server', () {
    test('a delivered receipt is not lost by a later sync', () async {
      api.seed(1, page(1, 1));
      await sync.syncConversation(1);
      expect((await store.messages(1)).single.state, MessageSendState.sent);

      api.seed(1, [
        serverMessage(id: 1, seq: 1, clientId: 'c1-1', body: 'm1',
            state: MessageSendState.delivered),
      ]);
      await sync.syncConversation(1);
      expect((await store.messages(1)).single.state, MessageSendState.delivered);
    });

    test('an optimistic bubble is replaced, not duplicated, by the sync', () async {
      await store.upsertMessages([
        ChatMessage(
          conversationId: 1,
          clientId: 'mine',
          body: 'optimistic',
          kind: 'text',
          senderId: 7,
          createdAt: DateTime.utc(2026, 3, 1),
          state: MessageSendState.sending,
        ),
      ]);

      api.seed(1, [serverMessage(id: 50, seq: 9, clientId: 'mine', body: 'optimistic')]);
      await sync.syncConversation(1);

      final stored = await store.messages(1);
      expect(stored, hasLength(1), reason: 'one message, not two bubbles');
      expect(stored.single.id, 50);
      expect(stored.single.state, MessageSendState.sent);
    });
  });

  group('syncAll', () {
    test('conversations and their messages are both written', () async {
      api.conversationList = [
        const ConversationSummary(id: 1, kind: 'direct', title: 'Sam', lastSeq: 2),
        const ConversationSummary(id: 2, kind: 'direct', title: 'Alex', lastSeq: 0),
      ];
      api.seed(1, page(1, 2, conversationId: 1));
      api.seed(2, page(1, 1, conversationId: 2));

      final outcome = await sync.syncAll();

      expect(outcome.conversations, 2);
      expect(await store.conversations(), hasLength(2));
      expect(await store.messages(1), hasLength(2));
      expect(await store.messages(2), hasLength(1));
    });
  });
}
