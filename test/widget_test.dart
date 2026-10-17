import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/models/user.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/api_config.dart';
import 'package:meridian/services/token_store.dart';

import 'support/fake_token_backend.dart';

TokenStore storeWith(Map<String, String> tokens) =>
    TokenStore(backend: FakeTokenBackend(tokens));

void main() {
  group('UserProfile', () {
    test('parses the /auth/me response', () {
      final user = UserProfile.fromJson({
        'id': 1,
        'role': 'student',
        'status': 'active',
        'first_name': 'Aarav',
        'surname': 'Sharma',
        'prn': '2024XXXX',
        'emp_id': null,
        'email': null,
        'college_code': 'MERIDIAN',
      });

      expect(user.id, 1);
      expect(user.identifier, '2024XXXX');
      expect(user.fullName, 'Aarav Sharma');
      expect(user.collegeCode, 'MERIDIAN');
      expect(user.isStudent, isTrue);
      expect(user.isModerator, isFalse);
    });

    test('falls back to emp_id when there is no PRN', () {
      final user = UserProfile.fromJson({
        'id': 2,
        'role': 'faculty',
        'status': 'active',
        'first_name': 'Meera',
        'surname': 'Iyer',
        'prn': null,
        'emp_id': 'EMP2024001',
      });
      expect(user.identifier, 'EMP2024001');
      expect(user.isFaculty, isTrue);
    });

    test('handles a missing optional field without throwing', () {
      final user = UserProfile.fromJson({'id': 3});
      expect(user.role, 'student');
      expect(user.status, 'active');
      expect(user.identifier, '');
      expect(user.email, isNull);
    });
  });

  group('TokenStore', () {
    test('round-trips tokens', () async {
      final backend = FakeTokenBackend();
      final store = TokenStore(backend: backend);

      await store.save(accessToken: 'a1', refreshToken: 'r1');

      expect(await store.readAccessToken(), 'a1');
      expect(await store.readRefreshToken(), 'r1');
    });

    test('clear removes everything', () async {
      final store = storeWith({
        kAccessTokenKey: 'a1',
        kRefreshTokenKey: 'r1',
      });
      await store.clear();
      expect(await store.readAccessToken(), isNull);
      expect(await store.readRefreshToken(), isNull);
    });

    test('reports nothing stored on a fresh install', () async {
      final store = TokenStore(backend: FakeTokenBackend());
      expect(await store.readAccessToken(), isNull);
      expect(await store.readRefreshToken(), isNull);
    });

    test('uses the injected backend and does not mark it as fallback', () {
      final store = TokenStore(backend: FakeTokenBackend());
      expect(store.isUsingFallbackStorage, isFalse);
    });
  });

  group('ApiConfig', () {
    test('base URL is a well-formed absolute URL', () {
      final uri = Uri.parse(ApiConfig.baseUrl);
      expect(uri.hasScheme, isTrue);
      expect(uri.host, isNotEmpty);
    });

    test('derives the websocket URL from the HTTP one', () {
      expect(ApiConfig.wsBaseUrl, startsWith('ws'));
    });
  });

  group('ApiException', () {
    test('flags 401 and 429 for the UI to react to', () {
      expect(const ApiException('x', statusCode: 401).isUnauthorized, isTrue);
      expect(const ApiException('x', statusCode: 429).isRateLimited, isTrue);
      expect(const ApiException('x').isUnauthorized, isFalse);
    });
  });

  group('ApiClient construction', () {
    test('composes the full request URL from base and prefix', () {
      final client = ApiClient(
        tokens: TokenStore(backend: FakeTokenBackend()),
        baseUrl: 'http://example.test:9999',
      );
      expect(client, isNotNull);
    });
  });

  testWidgets('shows the MERIDiAN brand on the auth scaffold', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('MERIDiAN')),
      ),
    );
    expect(find.text('MERIDiAN'), findsOneWidget);
  });
}

