import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/data/chat_models.dart';
import 'package:meridian/data/media_cache.dart';
import 'package:meridian/services/api_client.dart';

import 'support/stub_meridian_api.dart';

class _MediaApi extends StubMeridianApi {
  int calls = 0;

  /// Seconds each issued link lasts for. Zero issues a link that is already
  /// spent, which is how the refetch path is exercised without waiting.
  int linkLifespan = 300;

  /// Set to make the next call fail.
  ApiException? failWith;

  /// Resolves the link only once released, so a burst of callers can be made to
  /// overlap instead of being hoped to.
  Completer<void>? gate;

  @override
  Future<MediaLink> mediaLink(int mediaId) async {
    calls++;
    final gate = this.gate;
    if (gate != null) await gate.future;
    final failure = failWith;
    if (failure != null) throw failure;
    return MediaLink(
      url: 'https://fake.invalid/$mediaId?call=$calls',
      expiresInSeconds: linkLifespan,
    );
  }
}

void main() {
  group('MediaCache', () {
    test('asks once and reuses the link while it lasts', () async {
      final api = _MediaApi();
      final cache = MediaCache(api);

      expect(await cache.urlFor(7), 'https://fake.invalid/7?call=1');
      expect(await cache.urlFor(7), 'https://fake.invalid/7?call=1');
      expect(api.calls, 1);
    });

    test('asks again once the link is spent', () async {
      final api = _MediaApi()..linkLifespan = 0;
      final cache = MediaCache(api);

      await cache.urlFor(7);
      await cache.urlFor(7);

      // A link issued with no life left is not a usable link, so holding it
      // would be holding something that has already died.
      expect(api.calls, 2);
    });

    test('overlapping callers make one request, not one each', () async {
      final api = _MediaApi()..gate = Completer<void>();
      final cache = MediaCache(api);

      final first = cache.urlFor(7);
      final second = cache.urlFor(7);
      final third = cache.urlFor(7);

      api.gate!.complete();
      final urls = await Future.wait([first, second, third]);

      expect(urls, everyElement('https://fake.invalid/7?call=1'));
      expect(api.calls, 1);
    });

    test('a refusal is not cached, so a dropped link is retried', () async {
      final api = _MediaApi()..failWith = ApiException('gone', statusCode: 410);
      final cache = MediaCache(api);

      expect(await cache.urlFor(7), isNull);

      api.failWith = null;
      expect(await cache.urlFor(7), isNotNull);
      expect(api.calls, 2);
    });

    test('clear drops every link', () async {
      final api = _MediaApi();
      final cache = MediaCache(api);

      await cache.urlFor(7);
      cache.clear();
      await cache.urlFor(7);

      expect(api.calls, 2);
    });

    test('different files are cached separately', () async {
      final api = _MediaApi();
      final cache = MediaCache(api);

      expect(await cache.urlFor(1), 'https://fake.invalid/1?call=1');
      expect(await cache.urlFor(2), 'https://fake.invalid/2?call=2');
      expect(await cache.urlFor(1), 'https://fake.invalid/1?call=1');
    });
  });

  group('conversation membership', () {
    ConversationSummary summaryWith(List<Map<String, dynamic>> members) {
      return ConversationSummary.fromJson({
        'id': 1,
        'kind': 'group',
        'title': 'Algorithms',
        'members': members,
      });
    }

    test('reads a roster and finds the owner', () {
      final conversation = summaryWith([
        {'user_id': 1, 'username': 'ada', 'role': 'owner'},
        {'user_id': 2, 'username': 'bob', 'role': 'member'},
      ]);

      expect(conversation.isGroup, isTrue);
      expect(conversation.members, hasLength(2));
      expect(conversation.owner?.userId, 1);
      expect(conversation.owner?.isOwner, isTrue);
    });

    test('an empty roster is empty, not broken', () {
      final conversation = summaryWith(const []);
      expect(conversation.members, isEmpty);
      expect(conversation.owner, isNull);
    });

    test('a direct conversation has no members and is not a group', () {
      final conversation = ConversationSummary.fromJson({
        'id': 2,
        'kind': 'direct',
        'title': 'Ada Lovelace',
      });
      expect(conversation.isGroup, isFalse);
      expect(conversation.members, isEmpty);
    });

    test('a label prefers the display name over the handle', () {
      expect(
        const ConversationMember(
          userId: 1,
          username: 'ada',
          displayName: 'Ada Lovelace',
        ).label,
        'Ada Lovelace',
      );
    });

    test('a label falls back to the handle when no name was set', () {
      expect(
        const ConversationMember(userId: 1, username: 'ada').label,
        '@ada',
      );
      // Whitespace is not a name.
      expect(
        const ConversationMember(
          userId: 1,
          username: 'ada',
          displayName: '   ',
        ).label,
        '@ada',
      );
    });
  });

  group('media upload reply', () {
    test('reads what the server says it stored', () {
      final upload = MediaUpload.fromJson({
        'id': 12,
        'kind': 'image',
        'mime': 'image/jpeg',
        'byte_size': 4096,
        'expires_at': '2026-10-25T00:00:00Z',
      });

      expect(upload.id, 12);
      expect(upload.kind, 'image');
      expect(upload.byteSize, 4096);
    });

    test('carries no path back to the bytes', () {
      // The whole point of the change: the reply must not be usable to fetch a
      // file without going through the membership check.
      final upload = MediaUpload.fromJson({
        'id': 12,
        'kind': 'image',
        'mime': 'image/jpeg',
        'byte_size': 4096,
        'expires_at': '2026-10-25T00:00:00Z',
        // Even if a server ever sent one, the model has nowhere to put it.
        'upload_path': 'conversations/7/media/12.jpg',
      });

      expect(upload.toString(), isNot(contains('upload_path')));
    });
  });
}