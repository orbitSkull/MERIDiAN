import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/data/chat_models.dart';
import 'package:meridian/screens/home/conversation_controller.dart';
import 'package:meridian/screens/home/conversation_screen.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/chat_sync.dart';
import 'package:meridian/services/outbox.dart';

import 'support/fake_chat_api.dart';
import 'support/in_memory_chat_store.dart';

const int me = 7;
const int them = 9;

void main() {
  late InMemoryChatStore store;
  late FakeChatApi api;
  late DateTime now;
  late Future<ConversationController> Function() build;

  setUp(() {
    store = InMemoryChatStore();
    api = FakeChatApi();
    now = DateTime.utc(2026, 3, 1, 12);

    build = () async {
      final sender = OutboxSender(
        api: api,
        store: store,
        outbox: store,
        senderId: me,
        random: Random(7),
        clock: () => now,
      );
      final controller = ConversationController(
        conversationId: 1,
        api: api,
        store: store,
        outbox: store,
        sender: sender,
        sync: ChatSync(api: api, store: store),
      );
      return controller;
    };
  });

  Future<void> pump(WidgetTester tester, ConversationController controller) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationScreen(controller: controller, myUserId: me),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('rendering', () {
    testWidgets('an empty conversation explains itself', (tester) async {
      await pump(tester, await build());

      expect(find.text('No messages yet'), findsOneWidget);
      expect(
        find.textContaining('stored on your device'),
        findsOneWidget,
        reason: 'the offline promise should be stated, not implied',
      );
    });

    testWidgets('messages render oldest at the top, newest at the bottom',
        (tester) async {
      await store.upsertMessages([
        serverMessage(id: 1, seq: 1, clientId: 'a', body: 'first', senderId: them),
        serverMessage(id: 2, seq: 2, clientId: 'b', body: 'second', senderId: them),
      ]);

      await pump(tester, await build());

      final first = tester.getTopLeft(find.text('first')).dy;
      final second = tester.getTopLeft(find.text('second')).dy;
      expect(first, lessThan(second));
    });

    testWidgets('own messages are on the right, other people on the left',
        (tester) async {
      await store.upsertMessages([
        serverMessage(id: 1, seq: 1, clientId: 'a', body: 'mine', senderId: me),
        serverMessage(id: 2, seq: 2, clientId: 'b', body: 'theirs', senderId: them),
      ]);

      await pump(tester, await build());

      final screen = tester.getSize(find.byType(ConversationScreen)).width;
      expect(tester.getCenter(find.text('mine')).dx, greaterThan(screen / 2));
      expect(tester.getCenter(find.text('theirs')).dx, lessThan(screen / 2));
    });
  });

  group('expiry', () {
    testWidgets('an expired message says so instead of showing nothing',
        (tester) async {
      await store.upsertMessages([
        serverMessage(id: 1, seq: 1, clientId: 'a', body: '', expired: true),
      ]);

      await pump(tester, await build());

      expect(find.text('This message has expired'), findsOneWidget);
    });

    testWidgets('an expired attachment is distinguishable from no attachment',
        (tester) async {
      await store.upsertMessages([
        serverMessage(
          id: 1,
          seq: 1,
          clientId: 'a',
          body: 'look',
          attachmentExpired: true,
        ),
      ]);

      await pump(tester, await build());

      expect(find.text('look'), findsOneWidget);
      expect(find.text('Attachment expired'), findsOneWidget);
    });
  });

  group('ticks', () {
    testWidgets('a sending message shows a clock, not a tick', (tester) async {
      // One grey tick for something the other person cannot see yet would be a
      // lie about a message that has not left the device.
      await store.upsertMessages([
        ChatMessage(
          conversationId: 1,
          clientId: 'pending',
          body: 'on its way',
          kind: 'text',
          senderId: me,
          createdAt: now,
          state: MessageSendState.sending,
        ),
      ]);

      await pump(tester, await build());

      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
    });

    testWidgets('read and delivered are distinguishable', (tester) async {
      await store.upsertMessages([
        serverMessage(
          id: 1,
          seq: 1,
          clientId: 'a',
          body: 'delivered',
          senderId: me,
          state: MessageSendState.delivered,
        ),
        serverMessage(
          id: 2,
          seq: 2,
          clientId: 'b',
          body: 'read',
          senderId: me,
          state: MessageSendState.read,
        ),
      ]);

      await pump(tester, await build());

      expect(find.bySemanticsLabel('Delivered'), findsOneWidget);
      expect(find.bySemanticsLabel('Read'), findsOneWidget);
      // Different colours, so the two are told apart at a glance.
      final delivered = tester.widget<Icon>(
        find.descendant(
          of: find.bySemanticsLabel('Delivered'),
          matching: find.byType(Icon),
        ),
      );
      final read = tester.widget<Icon>(
        find.descendant(
          of: find.bySemanticsLabel('Read'),
          matching: find.byType(Icon),
        ),
      );
      expect(delivered.color, isNot(read.color));
    });
  });

  group('sending', () {
    testWidgets('a typed message appears before the network answers', (tester) async {
      final controller = await build();
      await pump(tester, controller);

      // The request is held open. Asserting "the bubble is there" while the
      // send is still in flight is the actual guarantee -- asserting it before
      // the flush happens only tests that a timer had not fired yet.
      final gate = Completer<ChatMessage>();
      api.onSend = (c, clientId, body) => gate.future;

      await tester.enterText(find.byType(TextField), 'hello there');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      expect(find.text('hello there'), findsOneWidget);
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget,
          reason: 'still in flight, so still a clock and not a tick');

      gate.complete(
        serverMessage(id: 5, seq: 5, clientId: api.sendClientIds.single, body: 'hello there'),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('an empty message is not sent', (tester) async {
      final controller = await build();
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(api.sendCount, 0);
    });

    testWidgets('the composer clears after sending', (tester) async {
      final controller = await build();
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('going offline leaves the message on screen', (tester) async {
      final controller = await build();
      await pump(tester, controller);
      api.onSend = (c, clientId, body) async =>
          throw ApiException('connection failed');

      await tester.enterText(find.byType(TextField), 'in a lift');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(find.text('in a lift'), findsOneWidget);
      expect(find.text('Not sent · Retry'), findsNothing,
          reason: 'it will be retried, so it is not a failed message yet');
    });
  });

  group('failure', () {
    testWidgets('a blocked send offers a retry and a discard', (tester) async {
      final controller = await build();
      await pump(tester, controller);
      api.onSend = (c, clientId, body) async =>
          throw ApiException('You cannot message this person', statusCode: 403);

      await tester.enterText(find.byType(TextField), 'blocked');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(find.text('blocked'), findsOneWidget,
          reason: 'the words must survive a refusal');
      expect(find.text('Not sent · Retry'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
    });

    testWidgets('retrying reuses the same client id', (tester) async {
      final controller = await build();
      await pump(tester, controller);
      api.onSend = (c, clientId, body) async =>
          throw ApiException('blocked', statusCode: 403);

      await tester.enterText(find.byType(TextField), 'blocked');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      final firstId = api.sendClientIds.single;

      await tester.tap(find.text('Not sent · Retry'));
      await tester.pumpAndSettle();

      // The server may have accepted it already; a lost response looks exactly
      // like a failure. Reusing the id turns a possible duplicate into a no-op.
      expect(api.sendClientIds.toSet(), {firstId});
    });
  });
}