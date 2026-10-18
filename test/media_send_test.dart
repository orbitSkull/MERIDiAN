import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/screens/home/conversation_controller.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/chat_sync.dart';
import 'package:meridian/services/outbox.dart';

import 'support/fake_chat_api.dart';
import 'support/in_memory_chat_store.dart';

const int me = 7;

/// Sending a photograph.
///
/// Two requests, in this order: the bytes, then the message that names them. The
/// ordering is the thing worth testing -- a client that sent the message first
/// has nothing to point at, and a client that uploaded but never sent leaves a
/// row nobody will ever read.
void main() {
  late InMemoryChatStore store;
  late FakeChatApi api;
  late ConversationController controller;

  setUp(() {
    store = InMemoryChatStore();
    api = FakeChatApi();
    controller = ConversationController(
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
      ),
      sync: ChatSync(api: api, store: store),
    );
  });

  final photo = [1, 2, 3, 4, 5];

  test('a photo with no caption is sent', () async {
    final failure = await controller.sendWithMedia(bytes: photo, mime: 'image/jpeg');

    expect(failure, isNull);
    expect(api.uploads, hasLength(1));
    expect(api.uploads.single.byteSize, photo.length);
    expect(api.sendCount, 1);
  });

  test('the message names the uploaded file', () async {
    await controller.sendWithMedia(bytes: photo, mime: 'image/jpeg');

    final sent = controller.messages.single;
    expect(sent.attachmentId, api.uploads.single.id);
    expect(sent.body, '');
    expect(sent.kind, 'media');
  });

  test('a caption travels with the photo', () async {
    await controller.sendWithMedia(
      bytes: photo,
      mime: 'image/jpeg',
      caption: 'the lab',
    );

    expect(controller.messages.single.body, 'the lab');
  });

  test('the photo shows up in the conversation', () async {
    await controller.sendWithMedia(bytes: photo, mime: 'image/jpeg');

    // Written through the store rather than spliced into the list, so it
    // survives a restart the same way a text message does.
    final stored = await store.messages(1);
    expect(stored.single.attachmentId, api.uploads.single.id);
  });

  test('a photo is not put in the outbox', () async {
    await controller.sendWithMedia(bytes: photo, mime: 'image/jpeg');

    // The outbox holds text and a client_id. A photo would need the bytes kept
    // on the device, and pretending otherwise is how a send silently never
    // arrives.
    expect(await store.count(), 0);
  });

  test('an upload that is refused explains itself', () async {
    api.uploadError = ApiException('nope', statusCode: 413);

    final failure = await controller.sendWithMedia(
      bytes: photo,
      mime: 'image/jpeg',
    );

    expect(failure, 'That file is too large to send.');
    expect(api.sendCount, 0);
  });

  test('an unsupported type is reported as such', () async {
    api.uploadError = ApiException('nope', statusCode: 415);

    final failure = await controller.sendWithMedia(
      bytes: photo,
      mime: 'application/pdf',
    );

    expect(failure, 'That kind of file cannot be sent in a chat.');
  });

  test('an expired file is reported as expired', () async {
    api.onSend = (conversationId, clientId, body) =>
        throw ApiException('gone', statusCode: 410);

    final failure = await controller.sendWithMedia(
      bytes: photo,
      mime: 'image/jpeg',
    );

    expect(failure, 'That photo has expired.');
  });

  test('two sends do not reuse one idempotency key', () async {
    await controller.sendWithMedia(bytes: photo, mime: 'image/jpeg');
    await controller.sendWithMedia(bytes: photo, mime: 'image/jpeg');

    // The same key twice would make the second send a no-op on the server, and
    // the person would watch a photograph they definitely sent disappear.
    expect(api.sendClientIds.toSet(), hasLength(2));
  });
}