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
    // 60 seconds, not 2. A free instance that has gone to sleep takes about a
    // minute to wake, and the probe's own connection is often what wakes it. A
    // short timeout reports the server as unreachable when it is merely asleep,
    // and the whole contract silently skips.
    final socket = await Socket.connect(
      uri.host,
      uri.port,
      timeout: const Duration(seconds: 60),
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

  /// The settings contract, on its own account.
  ///
  /// Separate from the auth group because these tests mutate state: a profile
  /// patch, a preference change and a block all leave marks, and running them
  /// against the same account as the auth tests would make the order of tests
  /// decide what passes.
  group('live settings contract', () {
    late ApiClient settingsClient;
    late String settingsPrn;

    setUpAll(() async {
      if (!reachable) return;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      settingsPrn = 'S$stamp';
      settingsClient = ApiClient(
        tokens: TokenStore(backend: FakeTokenBackend()),
        baseUrl: _baseUrl,
      );
      await settingsClient.register(
        collegeCode: 'MERIDIAN',
        role: 'student',
        firstName: 'Sett',
        surname: 'Tester',
        prn: settingsPrn,
        password: 'SettingsPass123',
      );
      // Register does not issue a session; sign-in does. Asserting otherwise is
      // what made this fixture read a token that was never there.
      await settingsClient.login(
        collegeCode: 'MERIDIAN',
        identifier: settingsPrn,
        password: 'SettingsPass123',
      );
    });

    test('me carries the handle and the editable fields', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }
      final user = await settingsClient.me();
      // /auth/me has no username, so reading the richer endpoint is what makes
      // the handle available without a second request.
      expect(user.hasUsername, isTrue);
      expect(user.prn, settingsPrn);
      expect(user.emailVerified, isFalse);
    });

    test('preferences default on and patch one field at a time', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }
      final before = await settingsClient.preferences();
      expect(before.pushEnabled, isTrue);
      expect(before.readReceipts, isTrue);

      final after = await settingsClient.updatePreferences({
        'push_enabled': false,
      });
      expect(after.pushEnabled, isFalse);
      // The other eleven must survive a one-key patch.
      expect(after.readReceipts, isTrue);
      expect(after.notifyCalls, isTrue);

      // Put it back, so a re-run does not accumulate changes.
      await settingsClient.updatePreferences({'push_enabled': true});
    });

    test('a profile patch stores the display name', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }
      final updated = await settingsClient.updateProfile(
        displayName: 'Sett T.',
        bio: 'live contract',
      );
      expect(updated.displayName, 'Sett T.');
      expect(updated.bio, 'live contract');

      final reread = await settingsClient.me();
      expect(reread.displayName, 'Sett T.');
    });

    test('an email set here reads back, unverified', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final updated = await settingsClient.updateProfile(
        email: 'sett$stamp@example.edu',
      );
      // The handler used to drop the address and still answer 200, so the
      // response is what has to be checked, not the status.
      expect(updated.email, isNotNull);
      expect(updated.email, isNotEmpty);
      expect(updated.emailVerified, isFalse);
    });

    test('the session list marks exactly one device as current', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }
      final sessions = await settingsClient.sessions();
      expect(sessions, isNotEmpty);
      expect(sessions.where((s) => s.isCurrent).length, 1);
      // Every device reports when it was last used, which is what makes the list
      // answer "which of these is still alive". It was null for every row until
      // rotation started moving the timestamp.
      expect(
        sessions.every((s) => s.lastUsedAt != null),
        isTrue,
        reason: 'a session with no last-used time cannot be judged idle',
      );
    });

    test('blocking yourself reports an empty list rather than an error', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }
      final me = await settingsClient.me();
      final blocked = await settingsClient.block(me.username);
      expect(blocked, isEmpty);
      // Still not blocked: the list the endpoint returns is the authority.
      expect(await settingsClient.blockedUsers(), isEmpty);
    });

    test('unblocking an unknown handle is not an error', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }
      await settingsClient.unblock('nobody.here');
    });

    test('a username change returns the handle the server settled on', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }
      // Move to a fresh handle rather than changing back and forth: the server
      // rate limits changes to once a week.
      final handle = 'contract${DateTime.now().microsecondsSinceEpoch % 100000}';
      expect(await settingsClient.saveUsername(handle), handle);
      expect((await settingsClient.me()).username, handle);

      // And the lookup that the new-chat screen depends on can find it again.
      final found = await settingsClient.lookupUser(handle);
      expect(found.found, isTrue);
      expect(found.user?.username, handle);
    });

    test('an unknown handle answers the same shape, with no user', () async {
      if (!reachable) {
        markTestSkipped('No server');
        return;
      }
      final missing = await settingsClient.lookupUser(
        'nobody.${DateTime.now().microsecondsSinceEpoch % 100000}',
      );
      // The endpoint answers a miss identically whatever the reason, which is
      // what stops this from being a way to test who is registered.
      expect(missing.found, isFalse);
      expect(missing.user, isNull);
    });
  });
}
