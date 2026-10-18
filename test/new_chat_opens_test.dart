import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/models/settings.dart';
import 'package:meridian/screens/home/conversation_controller.dart';
import 'package:meridian/screens/home/conversation_screen.dart';
import 'package:meridian/screens/home/new_chat_screen.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/chat_environment.dart';
import 'package:meridian/services/chat_sync.dart';
import 'package:meridian/services/outbox.dart';

import 'support/fake_chat_api.dart';
import 'support/in_memory_chat_store.dart';

const int me = 7;

void main() {
  late InMemoryChatStore store;
  late FakeChatApi api;
  late DateTime now;

  setUp(() {
    store = InMemoryChatStore();
    api = FakeChatApi();
    now = DateTime.utc(2026, 3, 1, 12);
  });

  ConversationController controller() => ConversationController(
    conversationId: 1,
    api: api,
    store: store,
    outbox: store,
    sender: OutboxSender(
      api: api,
      store: store,
      outbox: store,
      senderId: me,
      random: Random(1),
      clock: () => now,
    ),
    sync: ChatSync(api: api, store: store),
  );

  Future<void> pump(WidgetTester tester, ConversationController c) async {
    await tester.pumpWidget(
      MaterialApp(home: ConversationScreen(controller: c, myUserId: me)),
    );
    await tester.pumpAndSettle();
  }

  group('paging back', () {
    testWidgets('scrolling to the top asks for older messages', (tester) async {
      // A listener on the conversation controller fires when the data changes,
      // never while the user scrolls. Registering the scroll check there meant
      // older messages could never be reached no matter how far up they dragged.
      for (var i = 1; i <= 60; i++) {
        await store.upsertMessages([
          serverMessage(id: i, seq: i, clientId: 'c$i', body: 'message $i'),
        ]);
      }
      api.seed(1, [
        serverMessage(id: 0, seq: 0, clientId: 'c0', body: 'the oldest one'),
      ]);

      final c = controller();
      await pump(tester, c);
      expect(c.canLoadOlder, isTrue, reason: 'a full page means there may be more');

      final before = api.messagesCalls;
      // reversed list: offset 0 is the oldest end, so drag *down* to reach it.
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();

      expect(
        api.messagesCalls,
        greaterThan(before),
        reason: 'scrolling must actually trigger a fetch',
      );
    });

    testWidgets('a short conversation does not offer to page back',
        (tester) async {
      await store.upsertMessages([
        serverMessage(id: 1, seq: 1, clientId: 'a', body: 'only one'),
      ]);

      final c = controller();
      await pump(tester, c);

      expect(c.canLoadOlder, isFalse);
      expect(find.text('Beginning of the conversation'), findsOneWidget);
    });
  });

  group('starting a chat from search', () {
    Future<void> pumpSearch(WidgetTester tester) async {
      // Stands in for the ChatEnvironmentHolder the screen reads out of the
      // provider. Only the store, the api and the sync engine are exercised.
      // The real environment over an in-memory store, rather than a stand-in.
      final chat = ChatEnvironment.forTesting(api: api, store: store, outbox: store);
      await tester.pumpWidget(
        MaterialApp(
          home: NewChatScreen(api: api, chat: chat, myUserId: me, myUsername: 'me'),
        ),
      );
    }

    testWidgets('tapping somebody opens a conversation rather than a notice',
        (tester) async {
      api.searchResults = [
        DirectoryUser(
          id: 9,
          username: 'sam',
          firstName: 'Sam',
          surname: 'Okafor',
          role: 'student',
        ),
      ];

      await pumpSearch(tester);
      await tester.enterText(find.byType(TextField), 'sam');
      // The search is debounced, so this has to outlast it.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
            // Not find.text('sam'): that matches the *search field's* EditableText,
      // whose controller holds the query, so the tap lands on the input and
      // nothing is ever opened.
      await tester.tap(find.textContaining('@sam'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('is not built yet'),
        findsNothing,
        reason: 'there is a message backend behind this now',
      );
      expect(api.openedDirectFor, 9);
      expect(await store.conversations(), hasLength(1));
    });

    testWidgets('a blocked person is told rather than shown a broken chat',
        (tester) async {
      api.searchResults = [
        DirectoryUser(
          id: 9,
          username: 'blocked',
          firstName: 'B',
          surname: 'Locked',
          role: 'student',
        ),
      ];
      api.openDirectError = ApiException('no', statusCode: 403);

      await pumpSearch(tester);
      await tester.enterText(find.byType(TextField), 'blocked');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
            await tester.tap(find.textContaining('@blocked'));
      await tester.pumpAndSettle();

      expect(find.textContaining('cannot start a chat'), findsOneWidget);
      expect(await store.conversations(), isEmpty);
    });
  });
}
