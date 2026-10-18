/// Renders the chat screens to PNG so they can actually be looked at.
///
/// Every other test in this suite asserts that a string or an icon exists in the
/// widget tree. None of them say whether the result looks like a messaging app,
/// which is a question only a picture answers. This writes pictures.
///
/// Run with:
///
///     flutter test test/ui_preview_test.dart --update-goldens
///
/// and read the PNGs in test/preview/. They are committed on purpose: a chat UI
/// that nobody has ever looked at is how it ends up with four-pixel spacing and
/// unreadable grey-on-grey.
@Tags(['preview'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/data/chat_models.dart';
import 'package:meridian/screens/home/chats_screen.dart';
import 'package:meridian/screens/home/conversation_controller.dart';
import 'package:meridian/screens/home/conversation_screen.dart';
import 'package:meridian/services/chat_environment.dart';
import 'package:meridian/services/chat_sync.dart';
import 'package:meridian/services/outbox.dart';
import 'package:meridian/services/realtime_client.dart';
import 'package:meridian/theme/app_theme.dart';

import 'support/fake_chat_api.dart';
import 'support/in_memory_chat_store.dart';

const int me = 7;
const int them = 9;

/// Loads real fonts so the renders show words instead of the test font's
/// filled rectangles, which would make a layout review impossible.
///
/// Both families matter. The text font, or every label is a row of black boxes.
/// And MaterialIcons, or every icon is a box -- including the send button, the
/// ticks and the expired-attachment marker, which are the things a visual
/// review is mostly about.
Future<void> loadRealFonts() async {
  final textCandidates = [
    r'C:\Windows\Fonts\segoeui.ttf',
    r'C:\Windows\Fonts\arial.ttf',
    '/System/Library/Fonts/Helvetica.ttc',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  ];

  Future<void> loadOne(String family, List<String> paths) async {
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      await loader.load();
      return;
    }
  }

  // Registered under 'Roboto' as well as the preview family. Flutter's test
  // binding resolves anything that does not name a family to Roboto, so this is
  // what stops a `TextStyle(color: error)` passed inline -- which carries no
  // fontFamily of its own -- from falling through to the test font and drawing
  // a row of black boxes.
  await loadOne('PreviewFont', textCandidates);
  await loadOne('Roboto', textCandidates);
  await loadOne(
    'MaterialIcons',
    [
      r'M:\tools\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    ],
  );
}

ThemeData _theme(Brightness brightness) {
  final base = brightness == Brightness.dark
      ? AppTheme.dark()
      : AppTheme.light();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewFont'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewFont'),
  );
}

ChatMessage _message({
  required int id,
  required int seq,
  required String body,
  int senderId = them,
  MessageSendState state = MessageSendState.sent,
  bool expired = false,
  bool attachmentExpired = false,
  int? attachmentId,
  DateTime? createdAt,
  int conversationId = 1,
}) {
  return ChatMessage(
    id: id,
    conversationId: conversationId,
    clientId: 'c$id',
    seq: seq,
    body: body,
    kind: 'text',
    senderId: senderId,
    createdAt: createdAt ?? DateTime.utc(2026, 3, 1, 9, seq),
    expiresAt: DateTime.utc(2026, 3, 29),
    expired: expired,
    attachmentExpired: attachmentExpired,
    attachmentId: attachmentId,
    state: state,
  );
}

Future<ConversationController> buildController(
  InMemoryChatStore store,
  FakeChatApi api,
) async {
  return ConversationController(
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
      clock: () => DateTime.utc(2026, 3, 1, 12),
    ),
    sync: ChatSync(api: api, store: store),
  );
}

void main() {
  setUpAll(loadRealFonts);

  // Material shadows are drawn as a hard ring rather than a soft blur in
  // golden captures, which makes the FAB look like it has a black outline. If
  // that is all it is, it should not be reported as a bug.
  setUp(() {
    debugDisableShadows = true;
    addTearDown(() => debugDisableShadows = false);
  });

  /// A conversation with everything the UI can be in at once: a long message
  /// from the other person, several short ones in a row, a read receipt, a
  /// photo whose bytes have gone, and a send that failed.
  List<ChatMessage> busyConversation() {
    final base = DateTime.utc(2026, 3, 1, 9, 0);
    return [
      _message(
        id: 1,
        seq: 1,
        body: 'Morning — did the library booking go through?',
        createdAt: base,
      ),
      _message(
        id: 2,
        seq: 2,
        body: 'Yes, got it.',
        createdAt: base.add(const Duration(minutes: 1)),
      ),
      _message(
        id: 3,
        seq: 3,
        body: 'Are you free at 2?',
        createdAt: base.add(const Duration(minutes: 2)),
      ),
      _message(
        id: 4,
        seq: 4,
        body: 'I can do 2. Library or the cafe?',
        senderId: me,
        state: MessageSendState.read,
        createdAt: base.add(const Duration(minutes: 3)),
      ),
      _message(
        id: 5,
        seq: 5,
        body: 'Library. Bringing the notes from last week.',
        createdAt: base.add(const Duration(minutes: 4)),
      ),
      _message(
        id: 6,
        seq: 6,
        body: 'Look at this',
        senderId: me,
        state: MessageSendState.delivered,
        createdAt: base.add(const Duration(minutes: 5)),
      ),
      _message(
        id: 7,
        seq: 7,
        body: '',
        senderId: them,
        attachmentExpired: true,
        attachmentId: 31,
        createdAt: base.add(const Duration(minutes: 6)),
      ),
      _message(
        id: 8,
        seq: 8,
        body: 'This one aged out of the server.',
        expired: true,
        createdAt: base.add(const Duration(minutes: 7)),
      ),
      ChatMessage(
        conversationId: 1,
        clientId: 'failed',
        body: 'On my way now',
        kind: 'text',
        senderId: me,
        createdAt: base.add(const Duration(minutes: 8)),
        state: MessageSendState.failed,
        failureReason: 'offline',
      ),
    ];
  }

  Future<void> capture(
    WidgetTester tester,
    String name,
    Widget widget,
    Size size,
  ) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = size * 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(debugShowCheckedModeBanner: false, theme: _theme(Brightness.light), home: widget),
    );
    // Let the controller's async open and any spinner's animation settle to a
    // frame that represents the steady state.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/$name.png'),
    );
  }

  testWidgets('conversation, light', (tester) async {
    final store = InMemoryChatStore();
    final api = FakeChatApi();
    await store.upsertConversations([
      const ConversationSummary(id: 1, kind: 'direct', title: 'Sam Okafor'),
    ]);
    await store.upsertMessages(busyConversation());

    await capture(
      tester,
      'conversation_light',
      ConversationScreen(controller: await buildController(store, api), myUserId: me),
      const Size(390, 844),
    );
  });

  testWidgets('conversation, dark', (tester) async {
    final store = InMemoryChatStore();
    final api = FakeChatApi();
    await store.upsertConversations([
      const ConversationSummary(id: 1, kind: 'direct', title: 'Sam Okafor'),
    ]);
    await store.upsertMessages(busyConversation());

    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(780, 1688);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.dark),
        home: ConversationScreen(
          controller: await buildController(store, api),
          myUserId: me,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/conversation_dark.png'),
    );
  });

  testWidgets('empty conversation', (tester) async {
    final store = InMemoryChatStore();
    final api = FakeChatApi();
    await store.upsertConversations([
      const ConversationSummary(id: 1, kind: 'direct', title: 'Sam Okafor'),
    ]);

    await capture(
      tester,
      'conversation_empty',
      ConversationScreen(controller: await buildController(store, api), myUserId: me),
      const Size(390, 844),
    );
  });

  testWidgets('conversation list', (tester) async {
    final store = InMemoryChatStore();
    final api = FakeChatApi();
        // Real timestamps: with every lastMessageAt null the list falls back to
    // ordering by descending id, which is arbitrary and hid whether the row
    // times and the sort were doing anything.
    final now = DateTime.now();
    api.conversationList = [
      ConversationSummary(id: 1, kind: 'direct', title: 'Sam Okafor', unreadCount: 2, preview: 'Library. Bringing the notes from last week.', lastMessageAt: now.subtract(const Duration(minutes: 4))),
      ConversationSummary(id: 2, kind: 'group', title: 'Project Team', unreadCount: 5, preview: 'Ana: pushed the updated spec', lastMessageAt: now.subtract(const Duration(minutes: 52))),
      ConversationSummary(id: 3, kind: 'direct', title: 'Dr Amara Bello', preview: 'See you at 2.', lastMessageAt: now.subtract(const Duration(days: 1, hours: 3))),
      ConversationSummary(id: 4, kind: 'direct', title: 'Ravi Menon', preview: null, lastMessageAt: now.subtract(const Duration(days: 3))),
      ConversationSummary(id: 5, kind: 'direct', title: 'Chen Wei', preview: 'Thanks!', lastMessageAt: now.subtract(const Duration(days: 12))),
    ];
    api.seed(1, []);
    api.seed(2, []);

    await capture(
      tester,
      'chat_list',
      ChatsScreen(
        api: api,
        chat: ChatEnvironment.forTesting(api: api, store: store, outbox: store),
        myUserId: me,
        myUsername: 'me',
      ),
      const Size(390, 844),
    );
  });

  testWidgets('conversation with somebody typing', (tester) async {
    // The one part of this screen that depends on an animation running at the
    // right moment. It returns early when nobody is typing, so the "nobody is
    // typing" case is the one already covered by the other previews -- this is
    // for the case where it is visible.
    final store = InMemoryChatStore();
    final api = FakeChatApi();
    await store.upsertConversations([
      const ConversationSummary(id: 1, kind: 'direct', title: 'Sam Okafor'),
    ]);
    await store.upsertMessages(busyConversation());

    final controller = await buildController(store, api);
    await controller.open();
    // From somebody else: the controller ignores its own typing notices, which is
    // the only state a user ever actually sees this in.
    unawaited(
      controller.debugReceive(
        const RealtimeTyping(conversationId: 1, userId: 9, typing: true),
      ),
    );

    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(780, 1688);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        home: ConversationScreen(controller: controller, myUserId: me),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/conversation_typing.png'),
    );
    controller.dispose();
  });
}
