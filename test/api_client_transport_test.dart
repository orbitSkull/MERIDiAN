import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/token_store.dart';

import 'support/fake_token_backend.dart';

/// A [HttpClientAdapter] that answers every request with one canned reply.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.status, this.body);

  final int status;
  final Object? body;

  int requests = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final payload = jsonEncode(body);
    return ResponseBody.fromString(
      payload,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

/// The real [ApiClient], over a real Dio, against a stubbed socket.
///
/// This exists because of a bug no other test could have found. Every other test
/// in the suite hands a widget a fake API, so the one thing that is actually in
/// production -- Dio's interceptor chain -- was never exercised. An interceptor
/// that forgot to call `handler.next()` swallowed every response in the app, and
/// sign-in and registration spun on their buttons forever, while 280 tests
/// passed.
///
/// The lesson encoded here: an interceptor that observes a request is part of
/// what makes a request work, not merely something that watches it.
void main() {
  test('a request completes and the interceptor chain keeps going', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
    dio.httpClientAdapter = _StubAdapter(200, <Object>[]);

    final client = ApiClient(
      tokens: TokenStore(backend: FakeTokenBackend()),
      dio: dio,
      baseUrl: 'https://example.invalid',
    );

    // conversations() is a plain authenticated GET.
    final result = await client
        .conversations()
        .timeout(const Duration(seconds: 5));

    expect(result, isEmpty);
  });

  test('a failing request still completes rather than hanging', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
    dio.httpClientAdapter = _StubAdapter(500, {'detail': 'boom'});

    final client = ApiClient(
      tokens: TokenStore(backend: FakeTokenBackend()),
      dio: dio,
      baseUrl: 'https://example.invalid',
    );

    // The point is that it throws rather than never returning.
    await expectLater(
      client.conversations().timeout(const Duration(seconds: 5)),
      throwsA(isA<ApiException>()),
    );
  });
}

