@Tags(['live'])
library;

/// End-to-end contract test: exercises the real [ApiClient] against a running
/// MERIDiAN server, so request shapes and response parsing are verified rather
/// than assumed.
///
/// Skipped automatically when no server is reachable, so a plain `flutter test`
/// stays green without one. To run it:
///
///   # terminal 1 - point the server at the test database
///   cd .server
///   $env:DATABASE_URL = "mysql+pymysql://meridian:meridian@127.0.0.1:3306/meridian_test"
///   uv run alembic upgrade head
///   uv run uvicorn app.main:app --port 8000
///
///   # terminal 2
///   cd .project
///   flutter test --tags live

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/token_store.dart';

import 'support/fake_token_backend.dart';

const _baseUrl = String.fromEnvironment(
  'TEST_API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

Future<bool> _serverIsUp() async {
  try {
    final uri = Uri.parse(_baseUrl);
    final socket = await Socket.connect(
      uri.host,
      uri.port,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  late bool reachable;
  late ApiClient client;

  setUpAll(() async {
    reachable = await _serverIsUp();
    client = ApiClient(
      tokens: TokenStore(backend: FakeTokenBackend()),
      baseUrl: _baseUrl,
    );
  });

  test('server is reachable', () {
    // markTestSkipped does not abort the test body, so return explicitly.
    if (!reachable) {
      markTestSkipped('No MERIDiAN server at $_baseUrl');
      return;
    }
    expect(reachable, isTrue);
  });

  group('live auth contract', () {
    late String collegeCode;
    late String prn;

    setUpAll(() async {
      if (!reachable) return;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      // Colleges are operator-provisioned, not self-service, so this must
      // already exist. Run `uv run python -m app.scripts.seed` against the
      // test database first (see the header).
      collegeCode = 'MERIDIAN';
      prn = 'P$stamp';
      try {
        await client.register(
          collegeCode: collegeCode,
          role: 'student',
          firstName: 'Live',
          surname: 'Tester',
          prn: prn,
          password: 'LivePass123',
        );
      } on ApiException catch (e) {
        // Registration needs a provisioned college. Without one the test
        // cannot run, so surface it rather than failing obscurely later.
        fail('Registration failed: ${e.message}. Has the test DB been seeded?');
      }
    });

    test('login stores tokens and me() resolves the profile', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }

      await client.login(
        collegeCode: collegeCode,
        identifier: prn,
        password: 'LivePass123',
      );

      expect(await client.tokens.readAccessToken(), isNotNull);
      expect(await client.tokens.readRefreshToken(), isNotNull);

      final user = await client.me();
      expect(user.prn, prn);
      expect(user.role, 'student');
      expect(user.collegeCode, collegeCode);
    });

    test('refresh rotates the refresh token', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }

      final before = await client.tokens.readRefreshToken();
      expect(await client.tryRefresh(), isTrue);
      final after = await client.tokens.readRefreshToken();

      expect(before, isNotNull);
      expect(after, isNotNull);
      expect(after, isNot(before));
    });

    test('bad credentials surface as a 401 ApiException', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }

      await expectLater(
        client.login(
          collegeCode: collegeCode,
          identifier: prn,
          password: 'definitely-wrong',
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.isUnauthorized,
            'isUnauthorized',
            isTrue,
          ),
        ),
      );
    });
  });
}
