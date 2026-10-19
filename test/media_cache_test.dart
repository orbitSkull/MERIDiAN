import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/data/chat_models.dart';
import 'package:meridian/data/media_cache.dart';
import 'package:meridian/services/api_client.dart';

import 'support/stub_meridian_api.dart';

/// A [MeridianApi] that hands back bytes, and a directory the cache can use.
///
/// The directory is redirected because the real one is the app's support
/// directory, which does not exist under a plain test runner and would otherwise
/// make every test here fail for a reason that has nothing to do with caching.
class _MediaApi extends StubMeridianApi {
  int linkCalls = 0;
  int fetchCalls = 0;

  /// Set to make the download fail, as no network would.
  ApiException? linkError;
  Object? fetchError;

  /// Null makes fetchBytes answer null, as an empty response would.
  Uint8List? payload = Uint8List.fromList([1, 2, 3, 4]);

  @override
  Future<MediaLink> mediaLink(int mediaId) async {
    linkCalls++;
    final failure = linkError;
    if (failure != null) throw failure;
    return MediaLink(url: 'https://fake.invalid/$mediaId', expiresInSeconds: 300);
  }

  @override
  Future<Uint8List?> fetchBytes(String url) async {
    fetchCalls++;
    final failure = fetchError;
    if (failure != null) throw failure;
    return payload;
  }
}

void main() {
  late Directory root;
  late _MediaApi api;
  late MediaCache cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('meridian_media_test');
    api = _MediaApi();
    cache = MediaCache(api, directory: root);
  });

  tearDown(() async {
    await cache.clear();
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('MediaCache', () {
    test('downloads once and answers from disk after that', () async {
      final first = await cache.file(7);
      expect(first, isNotNull);
      expect(await first!.readAsBytes(), [1, 2, 3, 4]);

      final second = await cache.file(7);
      expect(second?.path, first.path);

      // One download, two reads. The second is the entire point: it must not
      // need a network.
      expect(api.fetchCalls, 1);
    });

    test('a file on disk is found with no network at all', () async {
      await cache.file(7);

      // A fresh cache with an API that cannot answer anything. This is what
      // offline viewing actually looks like from the cache's point of view.
      final offline = MediaCache(_FailingApi());
      expect(offline.cachedFile(7), isNull);

      // ...but the original cache still has it, because it is on disk.
      expect(cache.cachedFile(7), isNotNull);
    });

    test('concurrent callers download once', () async {
      final results = await Future.wait([cache.file(7), cache.file(7), cache.file(7)]);

      expect(results.every((f) => f != null), isTrue);
      expect(api.fetchCalls, 1);
    });

    test('no network is remembered as "not now", not "never"', () async {
      api.linkError = ApiException('gone', statusCode: 503);

      expect(await cache.file(7), isNull);

      // Next time it tries again rather than showing a permanent placeholder:
      // a tunnel is not a broken photograph.
      api.linkError = null;
      expect(await cache.file(7), isNotNull);
      expect(api.fetchCalls, 1);
    });

    test('an empty download is not written as a file', () async {
      api.payload = null;
      expect(await cache.file(7), isNull);
      expect(cache.cachedFile(7), isNull);
    });

    test('forget deletes the file from disk', () async {
      final file = await cache.file(7);
      expect(file, isNotNull);

      cache.forget(7);

      expect(cache.cachedFile(7), isNull);
      expect(await file!.exists(), isFalse);
    });

    test('different files are cached separately', () async {
      final a = await cache.file(1);
      final b = await cache.file(2);

      expect(a?.path, isNot(b?.path));
      expect(api.fetchCalls, 2);
    });
  });
}

class _FailingApi extends StubMeridianApi {}