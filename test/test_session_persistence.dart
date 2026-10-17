import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/models/user.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/auth_service.dart';
import 'package:meridian/services/token_store.dart';

import 'support/fake_token_backend.dart';

/// Mocks at the transport layer rather than in an interceptor.
///
/// Returning a response from `onRequest` would short-circuit the request
/// before ApiClient's own `onRequest` runs, so no Authorization header is
/// ever attached and the 401 recovery path is never exercised. Swapping the
/// adapter keeps the full interceptor chain honest.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.respond);

  final Response Function(RequestOptions options) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final response = respond(options);
    final bytes = utf8.encode(jsonEncode(response.data));
    return ResponseBody.fromBytes(bytes, response.statusCode ?? 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_StubAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://stub.invalid/api/v1'));
  dio.httpClientAdapter = adapter;
  return dio;
}

/// An ApiClient that can never reach a server, like a device with no network.
ApiClient offlineClient(TokenStore tokens) {
  final dio = Dio(BaseOptions(baseUrl: 'http://offline.invalid/api/v1'));
  dio.httpClientAdapter = _ThrowingAdapter();
  return ApiClient(tokens: tokens, dio: dio);
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'simulated offline',
    );
  }

  @override
  void close({bool force = false}) {}
}

/// An ApiClient whose server answers [meStatusCode] to /auth/me and a token
/// pair to /auth/refresh, so the whole restore flow can be walked through.
ApiClient clientReturning(
  TokenStore tokens, {
  int meStatusCode = 200,
  Map<String, dynamic>? meBody,
  int refreshStatusCode = 200,
}) {
  final dio = _dioWith(
    _StubAdapter((options) {
      final isRefresh = options.path.contains('/auth/refresh');
      return Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: isRefresh ? refreshStatusCode : meStatusCode,
        data: isRefresh
            ? {'access_token': 'a2', 'refresh_token': 'r2'}
            : (meBody ?? userJson()),
      );
    }),
  );
  return ApiClient(tokens: tokens, dio: dio);
}

Map<String, dynamic> userJson() => {
  'id': 1,
  'role': 'student',
  'status': 'active',
  'first_name': 'Aarav',
  'surname': 'Sharma',
  'prn': '2024XXXX',
  'emp_id': null,
  'email': null,
  'college_code': 'MERIDIAN',
};

void main() {
  group('offline session persistence', () {
    // This is the reported bug: close the app while offline, reopen it, and
    // the user must still be signed in.
    test('stays signed in when reopened with no connectivity', () async {
      final backend = FakeTokenBackend({
        kAccessTokenKey: 'access-1',
        kRefreshTokenKey: 'refresh-1',
        kCachedUserKey: jsonEncode(userJson()),
      });
      final auth = AuthService(
        tokenStore: TokenStore(backend: backend),
      );
      // Replace the real client with one that always fails to connect.
      AuthService(client: offlineClient(auth.tokens), tokenStore: auth.tokens);

      final offlineAuth = AuthService(
        client: offlineClient(TokenStore(backend: backend)),
        tokenStore: TokenStore(backend: backend),
      );

      final status = await offlineAuth.restoreSession();

      expect(status, SessionStatus.signedInOffline);
      expect(offlineAuth.user, isNotNull);
      expect(offlineAuth.user!.prn, '2024XXXX');
      expect(offlineAuth.isOffline, isTrue);

      // Critically, the tokens are untouched.
      expect(backend.values[kAccessTokenKey], 'access-1');
      expect(backend.values[kRefreshTokenKey], 'refresh-1');
      expect(backend.clearCount, 0);
    });

    test('reports signedOut when offline with nothing cached', () async {
      final backend = FakeTokenBackend({
        kAccessTokenKey: 'access-1',
        kRefreshTokenKey: 'refresh-1',
      });
      final auth = AuthService(
        client: offlineClient(TokenStore(backend: backend)),
        tokenStore: TokenStore(backend: backend),
      );

      final status = await auth.restoreSession();

      expect(status, SessionStatus.signedOut);
      // Still must not have thrown the session away.
      expect(backend.clearCount, 0);
      expect(backend.values[kAccessTokenKey], 'access-1');
    });

    test('reconnecting later resolves the session without re-login', () async {
      final backend = FakeTokenBackend({
        kAccessTokenKey: 'access-1',
        kRefreshTokenKey: 'refresh-1',
        kCachedUserKey: jsonEncode(userJson()),
      });
      final tokens = TokenStore(backend: backend);

      // Launch while offline.
      final offlineAuth = AuthService(
        client: offlineClient(tokens),
        tokenStore: tokens,
      );
      expect(await offlineAuth.restoreSession(), SessionStatus.signedInOffline);

      // Next launch, online.
      final onlineAuth = AuthService(
        client: clientReturning(tokens),
        tokenStore: tokens,
      );
      expect(await onlineAuth.restoreSession(), SessionStatus.signedIn);
      expect(onlineAuth.isOffline, isFalse);
    });

test('rejected access token is recovered by refreshing', () async {
      // A 401 on /auth/me alone is NOT a sign-out: the interceptor refreshes
      // and replays, so the session survives. The stub returns 200 on the
      // replay, which is what a real server does after a valid refresh.
      final backend = FakeTokenBackend({
        kAccessTokenKey: 'access-1',
        kRefreshTokenKey: 'refresh-1',
        kCachedUserKey: jsonEncode(userJson()),
      });
      final tokens = TokenStore(backend: backend);

      // 401 only for the first /auth/me; the replay after refresh succeeds.
      var meCalls = 0;
      final dio = Dio(BaseOptions(baseUrl: 'http://stub.invalid/api/v1'));
      dio.httpClientAdapter = _StubAdapter((options) {
        if (options.path.contains('/auth/refresh')) {
          return Response<Map<String, dynamic>>(
            requestOptions: options,
            data: {'access_token': 'a2', 'refresh_token': 'r2'},
          );
        }
        meCalls++;
        return Response<Map<String, dynamic>>(
          requestOptions: options,
          statusCode: meCalls == 1 ? 401 : 200,
          data: userJson(),
        );
      });

      final auth = AuthService(
        client: ApiClient(tokens: tokens, dio: dio),
        tokenStore: tokens,
      );

      expect(await auth.restoreSession(), SessionStatus.signedIn);
      expect(backend.values[kAccessTokenKey], 'a2');
    });

    test('a server that always 401s does not loop forever', () async {
      // Regression: the interceptor used to refresh and replay indefinitely,
      // hanging the app and burning battery. It must give up after one retry.
      final backend = FakeTokenBackend({
        kAccessTokenKey: 'access-1',
        kRefreshTokenKey: 'refresh-1',
        kCachedUserKey: jsonEncode(userJson()),
      });
      final tokens = TokenStore(backend: backend);
      var meCalls = 0;
      var refreshCalls = 0;

      final dio = Dio(BaseOptions(baseUrl: 'http://stub.invalid/api/v1'));
      dio.httpClientAdapter = _StubAdapter((options) {
        if (options.path.contains('/auth/refresh')) {
          refreshCalls++;
          return Response<Map<String, dynamic>>(
            requestOptions: options,
            data: {'access_token': 'a$refreshCalls', 'refresh_token': 'r$refreshCalls'},
          );
        }
        meCalls++;
        return Response<Map<String, dynamic>>(
          requestOptions: options,
          statusCode: 401,
          data: {'detail': 'nope'},
        );
      });

      final auth = AuthService(
        client: ApiClient(tokens: tokens, dio: dio),
        tokenStore: tokens,
      );

      // Completes (rather than timing out) and ends signed out.
      expect(await auth.restoreSession(), SessionStatus.signedOut);
      // At most: original + one replay. Never unbounded.
      expect(meCalls, lessThanOrEqualTo(2));
    });

    test('signs out when the server rejects both tokens', () async {
      final backend = FakeTokenBackend({
        kAccessTokenKey: 'access-1',
        kRefreshTokenKey: 'refresh-1',
        kCachedUserKey: jsonEncode(userJson()),
      });
final auth = AuthService(
        client: clientReturning(
          TokenStore(backend: backend),
          meStatusCode: 401,
          refreshStatusCode: 401,
        ),
        tokenStore: TokenStore(backend: backend),
      );

      final status = await auth.restoreSession();

      expect(status, SessionStatus.signedOut);
      expect(backend.values, isEmpty);
      expect(backend.clearCount, greaterThan(0));
    });

    test('no stored credentials means signed out', () async {
      final backend = FakeTokenBackend();
      final auth = AuthService(
        client: clientReturning(TokenStore(backend: backend)),
        tokenStore: TokenStore(backend: backend),
      );
      expect(await auth.restoreSession(), SessionStatus.signedOut);
    });

    test('a corrupt cached profile is discarded, not fatal', () async {
      final backend = FakeTokenBackend({
        kAccessTokenKey: 'a',
        kRefreshTokenKey: 'r',
        kCachedUserKey: '{not valid json',
      });
      final auth = AuthService(
        client: offlineClient(TokenStore(backend: backend)),
        tokenStore: TokenStore(backend: backend),
      );

      // Falls back to signedOut but must not throw.
      expect(await auth.restoreSession(), SessionStatus.signedOut);
    });
  });

  group('ApiException.isOffline', () {
    test('distinguishes unreachable from rejected', () {
      expect(
        const ApiException('Cannot reach the server. Check your connection.')
            .isOffline,
        isTrue,
      );
      expect(
        const ApiException('Invalid or expired token.', statusCode: 401)
            .isOffline,
        isFalse,
      );
      expect(
        const ApiException('Server error', statusCode: 500).isOffline,
        isFalse,
      );
    });
  });

  group('UserProfile caching', () {
    test('toJson round-trips through fromJson', () {
      final original = UserProfile.fromJson(userJson());
      final restored = UserProfile.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.prn, original.prn);
      expect(restored.collegeCode, original.collegeCode);
      expect(restored.fullName, original.fullName);
    });
  });
}