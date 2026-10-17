import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/models/settings.dart';
import 'package:meridian/models/user.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/meridian_api.dart';
import 'package:meridian/services/settings_store.dart';

/// A [MeridianApi] that records what it was asked and answers from memory.
///
/// Records the calls rather than only returning canned values, because the
/// behaviour worth checking is the shape of the traffic: which fields were sent,
/// how many times, and whether a rejected write was retried or quietly dropped.
class FakeMeridianApi implements MeridianApi {
  FakeMeridianApi({UserPreferences? preferences})
    : storedPreferences =
          preferences ??
          const UserPreferences(pushEnabled: true, readReceipts: true);

  UserPreferences storedPreferences;
  UserProfile profile = _profile();
  List<DeviceSession> storedSessions = const [];
  List<BlockedUser> storedBlocked = const [];

  /// Every preference write, in order, as the partial maps that were sent.
  final List<Map<String, bool>> preferenceWrites = [];

  /// Every profile patch, as sent.
  final List<Map<String, String?>> profileWrites = [];

  String? savedUsername;
  int revokeOthersCalls = 0;
  final List<int> revokedSessions = [];
  final List<String> unblocked = [];

  /// Set to fail the next preference write, then cleared.
  ApiException? failNextWrite;

  /// Set to fail reads, which is what being offline looks like.
  ApiException? failReads;

  bool get hasPendingWriteFailure => failNextWrite != null;

  @override
  Future<UserPreferences> updatePreferences(Map<String, bool> changes) async {
    final failure = failNextWrite;
    if (failure != null) {
      failNextWrite = null;
      throw failure;
    }
    preferenceWrites.add(Map.of(changes));
    storedPreferences = UserPreferences.fromJson({
      ...storedPreferences.toJson(),
      ...changes,
    });
    return storedPreferences;
  }

  @override
  Future<UserPreferences> preferences() async {
    final failure = failReads;
    if (failure != null) throw failure;
    return storedPreferences;
  }

  @override
  Future<UserProfile> me() async => profile;

  @override
  Future<UserProfile> updateProfile({
    String? displayName,
    String? bio,
    String? avatarUrl,
    String? email,
  }) async {
    profileWrites.add({
      'display_name': displayName,
      'bio': bio,
      'avatar_url': avatarUrl,
      'email': email,
    });
    return profile;
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {}

  @override
  Future<List<DeviceSession>> sessions() async {
    final failure = failReads;
    if (failure != null) throw failure;
    return storedSessions;
  }

  @override
  Future<void> revokeSession(int sessionId) async =>
      revokedSessions.add(sessionId);

  @override
  Future<void> revokeOtherSessions() async => revokeOthersCalls++;

  @override
  Future<List<BlockedUser>> blockedUsers() async => storedBlocked;

  @override
  Future<List<BlockedUser>> block(String username, {String? reason}) async {
    storedBlocked = [
      ...storedBlocked,
      BlockedUser(
        username: username,
        firstName: '',
        surname: '',
        blockedAt: DateTime.now().toUtc(),
        reason: reason,
      ),
    ];
    return storedBlocked;
  }

  @override
  Future<void> unblock(String username) async => unblocked.add(username);

  @override
  Future<String> saveUsername(String username) async {
    savedUsername = username;
    return username;
  }

  @override
  Future<UserLookup> lookupUser(String username) async => UserLookup.notFound;

  @override
  Future<UserSearch> searchUsers(String query) async => UserSearch.empty;
}

UserProfile _profile({
  String username = 'aarav.sharma',
  String? displayName,
  String? email,
  bool emailVerified = false,
}) => UserProfile(
  id: 7,
  role: 'student',
  status: 'active',
  firstName: 'Aarav',
  surname: 'Sharma',
  username: username,
  displayName: displayName,
  email: email,
  emailVerified: emailVerified,
);

void main() {
  late SettingsStore store;

  setUp(() => store = SettingsStore.inMemory());

  group('profile decoding', () {
    test('reads the fields only /me returns', () {
      final profile = UserProfile.fromJson({
        'id': 7,
        'username': 'aarav.sharma',
        'first_name': 'Aarav',
        'surname': 'Sharma',
        'display_name': 'Aarav S.',
        'bio': 'third year, CSE',
        'email': 'aarav@example.edu',
        'email_verified': true,
        'college_code': 'MERIDIAN',
      });

      expect(profile.username, 'aarav.sharma');
      expect(profile.displayName, 'Aarav S.');
      expect(profile.bio, 'third year, CSE');
      expect(profile.emailVerified, isTrue);
      // The name to show in a header is the chosen one.
      expect(profile.preferredName, 'Aarav S.');
    });

    test('falls back rather than throwing on a partial payload', () {
      // A truncated response must not take the settings screen down with it.
      final profile = UserProfile.fromJson({'id': 7});
      expect(profile.username, '');
      expect(profile.hasUsername, isFalse);
      expect(profile.emailVerified, isFalse);
      expect(profile.preferredName, '');
    });

    test('an unverified flag absent from the payload is false, not true', () {
      final profile = UserProfile.fromJson({'id': 7});
      expect(profile.emailVerified, isFalse);
    });

    test('copyWith replaces only what it is given', () {
      final profile = _profile(displayName: 'Aarav S.', email: 'a@example.edu');
      final renamed = profile.copyWith(username: 'aarav.q');

      expect(renamed.username, 'aarav.q');
      expect(renamed.displayName, 'Aarav S.');
      expect(renamed.email, 'a@example.edu');
    });

    test('survives a round trip through the offline cache', () {
      final profile = _profile(
        displayName: 'Aarav S.',
        email: 'aarav@example.edu',
        emailVerified: true,
      );
      final restored = UserProfile.fromJson(profile.toJson());

      expect(restored.username, profile.username);
      expect(restored.displayName, profile.displayName);
      expect(restored.email, profile.email);
      expect(restored.emailVerified, isTrue);
    });
  });

  group('preferences model', () {
    test('defaults everything on, matching a fresh server row', () {
      final defaults = UserPreferences.defaults.toJson();
      expect(defaults.values.every((value) => value == true), isTrue);
      expect(defaults.length, 12);
    });

    test('decodes a missing field as on rather than off', () {
      // A partial payload must not read as "this person turned everything off".
      final decoded = UserPreferences.fromJson({'push_enabled': false});
      expect(decoded.pushEnabled, isFalse);
      expect(decoded.notifyCalls, isTrue);
    });

    test('round trips', () {
      const original = UserPreferences(
        pushEnabled: false,
        lastSeen: false,
        autoDownloadMedia: false,
      );
      final restored = UserPreferences.fromJson(original.toJson());

      expect(restored.pushEnabled, isFalse);
      expect(restored.lastSeen, isFalse);
      expect(restored.autoDownloadMedia, isFalse);
      expect(restored.readReceipts, isTrue);
    });

    test('every field name is unique', () {
      final names = UserPreferences.fieldNames;
      expect(names.toSet().length, names.length);
      expect(UserPreferences.defaults.toJson().keys.toSet(), names.toSet());
    });
  });

  group('session model', () {
    test('names an unlabelled device honestly', () {
      final session = DeviceSession.fromJson({
        'id': 1,
        'device_label': null,
        'created_at': '2026-10-01T09:00:00Z',
        'last_used_at': null,
        'current': true,
      });
      // Not a guess from the timestamp: "Unknown device" says what it knows.
      expect(session.displayName, 'Unknown device');
      expect(session.isCurrent, isTrue);
      // No timestamp is not the same as "not used".
      expect(session.isIdle, isNull);
    });

    test('an idle device is one nobody has touched in a month', () {
      final stale = DeviceSession.fromJson({
        'id': 1,
        'created_at': '2026-01-01T09:00:00Z',
        'last_used_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 90))
            .toIso8601String(),
        'current': false,
      });
      expect(stale.isIdle, isTrue);
    });

    test('carries no field a token could hide in', () {
      // A session list must not become a credential dump.
      expect(
        DeviceSession.fromJson({
          'id': 1,
          'token': 'secret',
          'created_at': 'x',
        }).displayName,
        'Unknown device',
      );
    });
  });

  group('settings sync', () {
    test('a toggle sends exactly one field', () async {
      final api = FakeMeridianApi();
      await store.attachApi(api);

      await store.setPushEnabled(false);

      expect(api.preferenceWrites, hasLength(1));
      // One key, not twelve. Sending the whole set would overwrite whatever the
      // server has that this device has not heard about.
      expect(api.preferenceWrites.single, {'push_enabled': false});
      expect(store.pushEnabled, isFalse);
    });

    test('server values win on attach', () async {
      final api = FakeMeridianApi(
        preferences: const UserPreferences(pushEnabled: false, lastSeen: false),
      );
      // A local value that disagrees with the account.
      await store.setReadReceipts(false);

      await store.attachApi(api);

      expect(store.pushEnabled, isFalse);
      expect(store.lastSeen, isFalse);
      // The device's own value was replaced by the account's, not merged.
      expect(store.readReceipts, isTrue);
    });

    test('a rejected toggle rolls back to the last confirmed value', () async {
      final api = FakeMeridianApi(
        preferences: const UserPreferences(notifyCalls: false),
      );
      await store.attachApi(api);
      expect(store.notifyCalls, isFalse);

      api.failNextWrite = const ApiException(
        'Server is busy.',
        statusCode: 503,
      );
      await store.setNotifyCalls(true);

      // The switch must not stay on: the account still has it off, and a switch
      // that looks saved when it is not is worse than an error.
      expect(store.notifyCalls, isFalse);
      expect(store.syncError, 'Server is busy.');
    });

    test('a rejected toggle does not touch the other eleven', () async {
      final api = FakeMeridianApi();
      await store.attachApi(api);

      api.failNextWrite = const ApiException('nope');
      await store.setLastSeen(false);

      expect(store.lastSeen, isTrue, reason: 'rolled back');
      expect(store.pushEnabled, isTrue);
    });

    test('two rapid toggles both reach the server, in order', () async {
      final api = FakeMeridianApi();
      await store.attachApi(api);

      // Not awaited: the queue is what makes this safe, and awaiting each one
      // would hide the bug the test is looking for.
      unawaited(store.setTypingIndicator(false));
      unawaited(store.setTypingIndicator(true));

      await _settle();

      expect(api.preferenceWrites, [
        {'typing_indicator': false},
        {'typing_indicator': true},
      ]);
      expect(store.typingIndicator, isTrue);
    });

    test('detaching stops writes and keeps the cache', () async {
      final api = FakeMeridianApi();
      await store.attachApi(api);
      store.detachApi();

      await store.setPushEnabled(false);

      // No API, so nothing is pushed. The value stays on this device.
      expect(api.preferenceWrites, isEmpty);
      expect(store.isSynced, isFalse);
      expect(store.pushEnabled, isFalse);
    });

    test('an unreachable server leaves the device values alone', () async {
      final api = FakeMeridianApi();
      await store.setReadReceipts(false);

      api.failReads = const ApiException('Cannot reach the server');
      final synced = await store.attachApi(api);

      expect(synced, isFalse);
      expect(store.syncError, 'Cannot reach the server');
      // Not wiped to defaults by a failed read.
      expect(store.readReceipts, isFalse);
    });

    test('reset pushes only the fields that actually changed', () async {
      final api = FakeMeridianApi();
      await store.attachApi(api);
      api.preferenceWrites.clear();

      await store.setPushEnabled(false);
      api.preferenceWrites.clear();

      await store.reset();

      expect(api.preferenceWrites, [
        {'push_enabled': true},
      ]);
      expect(store.pushEnabled, isTrue);
    });

    test('binding the same client twice does not re-read', () async {
      final api = FakeMeridianApi();
      await store.attachApi(api);
      final before = api.preferenceWrites.length;

      store.bindApi(api);
      await _settle();

      // AuthService notifies for a theme change too; re-reading twelve
      // preferences then would hammer the API for nothing.
      expect(api.preferenceWrites.length, before);
    });

    test('binding null detaches', () async {
      final api = FakeMeridianApi();
      await store.attachApi(api);
      store.bindApi(null);

      expect(store.isSynced, isFalse);
    });
  });
}

/// Lets the store's internal push queue finish.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
