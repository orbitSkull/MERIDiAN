import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/data/chat_models.dart';
import 'package:meridian/services/chat_environment.dart';

import 'support/fake_chat_api.dart';
import 'support/in_memory_chat_store.dart';

void main() {
  group('ChatEnvironmentHolder', () {
    late InMemoryChatStore store;
    late FakeChatApi api;
    late ChatEnvironmentHolder holder;

    setUp(() {
      store = InMemoryChatStore();
      api = FakeChatApi();
      holder = ChatEnvironmentHolder(
        api: api,
        build: (api) => ChatEnvironment.forTesting(
          api: api,
          store: store,
          outbox: store,
        ),
      );
    });

    test('signing out empties the local chat database', () async {
      // The one thing standing between one person's conversations and whoever
      // signs in next on this device. Clearing tokens does not touch it.
      await store.upsertConversations([
        const ConversationSummary(id: 1, kind: 'direct', title: 'Sam'),
      ]);
      await store.upsertMessages([
        serverMessage(id: 1, seq: 1, clientId: 'a', body: 'something private'),
      ]);

      await holder.handleSignOut(FakeChatApi());

      expect(await store.messages(1), isEmpty);
      expect(await store.conversations(), isEmpty);
      expect(await store.count(), 0, reason: 'and no queued sends either');
    });

    test('signing out drops queued sends too', () async {
      // An outbox row is a message still owed to the server. Carrying it into
      // the next session would send somebody else's words under this account.
      await store.add(
        OutboxEntry(
          clientId: 'pending',
          conversationId: 1,
          body: 'never sent',
          createdAt: DateTime.utc(2026),
          attempts: 0,
          nextAttemptAt: DateTime.utc(2026),
        ),
      );

      await holder.handleSignOut(FakeChatApi());

      expect(await store.count(), 0);
    });

    test('the next session gets a fresh environment', () async {
      final before = holder.environment;
      await holder.handleSignOut(FakeChatApi());

      expect(
        identical(holder.environment, before),
        isFalse,
        reason: 'anything holding the old store would keep the previous user\'s '
            'messages reachable',
      );
    });

    test('a listener is told the environment changed', () async {
      var notified = 0;
      holder.addListener(() => notified++);

      await holder.handleSignOut(FakeChatApi());

      expect(notified, 1);
    });
  });
}