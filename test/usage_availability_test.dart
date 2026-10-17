import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/token_store.dart';
import 'package:meridian/services/usage_username_availability.dart';

import 'support/fake_token_backend.dart';

/// Behaviour of the transport-backed availability checker.
///
/// The endpoint answers 200 whether or not the name is taken, on purpose, so
/// these tests pin down that `available` comes from the body and never from the
/// status code. Reading it from the status would reintroduce the enumeration
/// leak the endpoint exists to avoid.
///
/// The stub replaces the HTTP adapter rather than short-circuiting in
/// `onRequest`, for the same reason test_session_persistence.dart does it that
/// way: returning early would skip ApiClient's own interceptors, so the bearer
/// token would never be attached and the path under test would not be the one
/// that runs in production.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.body, {this.statusCode = 200});

  final Map<String, dynamic> body;
  final int statusCode;

  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(body)),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _clientWith(_StubAdapter adapter, {Map<String, String>? stored}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://stub.invalid/api/v1'));
  dio.httpClientAdapter = adapter;
  // TokenStore wraps a TokenBackend; the fake goes underneath it so the store
  // still owns the key names the production code reads.
  return ApiClient(
    tokens: TokenStore(backend: FakeTokenBackend(stored)),
    dio: dio,
  );
}

/// The token store's own key for the access token. Hard-coded here rather than
/// imported, because these tests should fail if that key ever changes, not
/// quietly follow it.
const _accessTokenKey = 'meridian.access_token';

void main() {
  test('reports a free name as available', () async {
    final adapter = _StubAdapter({
      'available': true,
      'well_formed': true,
      'suggestions': <String>[],
    });
    final result = await ApiUsernameAvailability(
      _clientWith(adapter),
    ).check('aarav.sharma');

    expect(result.available, isTrue);
    expect(result.suggestions, isEmpty);
  });

  test('reads available from the body, not the status', () async {
    final adapter = _StubAdapter(
      {
        'available': false,
        'well_formed': true,
        'suggestions': ['aarav.sharma.2', 'aarav.sharma.3'],
      },
      // The same 200 the server sends for a taken name. If the checker were
      // reading the status it would wrongly report this as available.
      statusCode: 200,
    );
    final result = await ApiUsernameAvailability(
      _clientWith(adapter),
    ).check('aarav.sharma');

    expect(result.available, isFalse);
    expect(result.suggestions, ['aarav.sharma.2', 'aarav.sharma.3']);
  });

  test('requests the endpoint the API actually serves', () async {
    final adapter = _StubAdapter({
      'available': true,
      'well_formed': true,
      'suggestions': <String>[],
    });
    await ApiUsernameAvailability(_clientWith(adapter)).check('aarav.sharma');

    // ApiClient requests paths without the prefix and Dio prepends the base
    // URL, which already ends in /api/v1. So the recorded path is the
    // unprefixed one and the base carries the version.
    expect(adapter.lastRequest?.path, '/users/username/check');
    expect(adapter.lastRequest?.baseUrl.toString(), endsWith('/api/v1'));
    expect(
      '${adapter.lastRequest?.baseUrl}${adapter.lastRequest?.path}',
      endsWith('/api/v1/users/username/check'),
    );
  });

  test('sends the username as a query parameter', () async {
    final adapter = _StubAdapter({
      'available': true,
      'well_formed': true,
      'suggestions': <String>[],
    });
    await ApiUsernameAvailability(_clientWith(adapter)).check('meera.iyer');

    expect(adapter.lastRequest?.queryParameters['username'], 'meera.iyer');
  });

  test('attaches the bearer token when one is stored', () async {
    final adapter = _StubAdapter({
      'available': true,
      'well_formed': true,
      'suggestions': <String>[],
    });
    await ApiUsernameAvailability(
      _clientWith(adapter, stored: {_accessTokenKey: 'test-token'}),
    ).check('aarav.sharma');

    expect(
      adapter.lastRequest?.headers['Authorization'],
      'Bearer test-token',
      reason: 'the checker is authenticated like every other call',
    );
  });

  test('omits the header when signed out', () async {
    // The availability endpoint is reachable without a session, so this must not
    // throw or block on a missing token.
    final adapter = _StubAdapter({
      'available': true,
      'well_formed': true,
      'suggestions': <String>[],
    });
    final result = await ApiUsernameAvailability(
      _clientWith(adapter),
    ).check('aarav.sharma');

    expect(result.available, isTrue);
    expect(adapter.lastRequest?.headers.containsKey('Authorization'), isFalse);
  });

  test('malformed input comes back as not available, not as an error', () async {
    final adapter = _StubAdapter({
      'available': false,
      'well_formed': false,
      'suggestions': <String>[],
    });
    final result = await ApiUsernameAvailability(
      _clientWith(adapter),
    ).check('ab');

    expect(result.available, isFalse);
  });

  group('tolerates a response that is not quite right', () {
    test('a missing suggestions field yields an empty list', () async {
      final result = await ApiUsernameAvailability(
        _clientWith(_StubAdapter({'available': true})),
      ).check('aarav.sharma');

      expect(result.available, isTrue);
      expect(result.suggestions, isEmpty);
    });

    test('a suggestions field of the wrong type yields an empty list', () async {
      final result = await ApiUsernameAvailability(
        _clientWith(
          _StubAdapter({'available': false, 'suggestions': 'not-a-list'}),
        ),
      ).check('aarav.sharma');

      expect(result.available, isFalse);
      expect(result.suggestions, isEmpty);
    });

    test('non-string entries are filtered out', () async {
      final result = await ApiUsernameAvailability(
        _clientWith(
          _StubAdapter({
            'available': false,
            'suggestions': ['aarav.sharma.2', 42, null, 'aarav.sharma.3'],
          }),
        ),
      ).check('aarav.sharma');

      expect(result.suggestions, ['aarav.sharma.2', 'aarav.sharma.3']);
    });
  });

  group('the local fake', () {
    test('mirrors the contract for the cases the screen depends on', () async {
      final fake = FakeUsernameAvailability(taken: const {'aarav.sharma'});

      final taken = await fake.check('aarav.sharma');
      expect(taken.available, isFalse);
      expect(taken.suggestions, isNotEmpty);

      final free = await fake.check('meera.iyer');
      expect(free.available, isTrue);
    });
  });
}