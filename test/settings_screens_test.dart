import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:meridian/models/settings.dart';
import 'package:meridian/models/user.dart';
import 'package:meridian/screens/settings/account/account_settings_screen.dart';
import 'package:meridian/screens/settings/account/email_screen.dart';
import 'package:meridian/screens/settings/account/password_screen.dart';
import 'package:meridian/screens/settings/account/profile_editor_screen.dart';
import 'package:meridian/screens/settings/account/sessions_screen.dart';
import 'package:meridian/screens/settings/blocks/block_list_screen.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/meridian_api.dart';
import 'package:meridian/services/settings_store.dart';

import 'support/stub_meridian_api.dart';

/// Scriptable [MeridianApi] for widget tests.
///
/// Lets a test decide what the screen will be told, including failures, so the
/// interesting paths -- a rejected save, an unreachable server, a device with
/// no label -- can be driven without a server.
class ScriptedApi extends StubMeridianApi {
  UserProfile profile = _profile();
  List<DeviceSession> storedSessions = const [];
  List<BlockedUser> storedBlocked = const [];

  ApiException? failSessions;
  ApiException? failBlocks;
  ApiException? failUpdateProfile;
  ApiException? failPassword;
  ApiException? failBlock;
  ApiException? failLookup;

  /// What [lookupUser] answers, and the last handle it was asked about.
  UserLookup? lookupAnswer;
  String? lastLookup;

  final List<Map<String, String?>> profileWrites = [];
  final List<int> revoked = [];
  int revokeOthersCalls = 0;
  int passwordChanges = 0;
  final List<String> unblocked = [];
  String? savedUsername;

  @override
  Future<UserProfile> me() async => profile;

  @override
  Future<UserProfile> updateProfile({
    String? displayName,
    String? bio,
    String? avatarUrl,
    String? email,
  }) async {
    final failure = failUpdateProfile;
    if (failure != null) throw failure;
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
  }) async {
    final failure = failPassword;
    if (failure != null) throw failure;
    passwordChanges++;
  }

  @override
  Future<List<DeviceSession>> sessions() async {
    final failure = failSessions;
    if (failure != null) throw failure;
    return storedSessions;
  }

  @override
  Future<void> revokeSession(int sessionId) async => revoked.add(sessionId);

  @override
  Future<void> revokeOtherSessions() async => revokeOthersCalls++;

  @override
  Future<List<BlockedUser>> blockedUsers() async {
    final failure = failBlocks;
    if (failure != null) throw failure;
    return storedBlocked;
  }

  @override
  Future<List<BlockedUser>> block(String username, {String? reason}) async {
    final failure = failBlock;
    if (failure != null) throw failure;
    return storedBlocked = [
      ...storedBlocked,
      BlockedUser(
        username: username,
        firstName: 'Someone',
        surname: 'Else',
        reason: reason,
        blockedAt: DateTime.now().toUtc(),
      ),
    ];
  }

  @override
  Future<void> unblock(String username) async => unblocked.add(username);

  @override
  Future<UserPreferences> preferences() async => const UserPreferences();

  @override
  Future<UserPreferences> updatePreferences(Map<String, bool> changes) async =>
      const UserPreferences();

  @override
  Future<String> saveUsername(String username) async {
    savedUsername = username;
    return username;
  }

  @override
  Future<UserLookup> lookupUser(String username) async {
    final failure = failLookup;
    if (failure != null) throw failure;
    lastLookup = username;
    return lookupAnswer ?? UserLookup.notFound;
  }

  @override
  Future<UserSearch> searchUsers(String query) async =>
      throw UnimplementedError();
}

UserProfile _profile() => const UserProfile(
  id: 7,
  role: 'student',
  status: 'active',
  firstName: 'Aarav',
  surname: 'Sharma',
  username: 'aarav.sharma',
  displayName: 'Aarav S.',
  email: 'aarav@example.edu',
  collegeCode: 'MERIDIAN',
);

/// Wraps a screen in the minimum MaterialApp a ListView and AppBar need.
///
/// A SettingsStore is always provided, in memory and unsynced. The block list
/// reads blocking preferences from it, and a screen that throws
/// ProviderNotFoundException in a test tells you nothing about the screen.
Widget host(Widget child) => ChangeNotifierProvider<SettingsStore>.value(
  value: SettingsStore.inMemory(),
  child: MaterialApp(home: child),
);

/// Runs a widget test on a tall surface.
///
/// The default test window is 800x600, which is shorter than a phone. Every
/// screen here is a ListView, so the save button lands below the fold, taps miss
/// silently, and the test fails for a reason that has nothing to do with the
/// screen. Resizing once here beats a `scrollUntilVisible` in every test, and
/// keeps the assertions about behaviour rather than about scrolling.
void screenTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await body(tester);
  });
}

void main() {
  group('profile editor', () {
    screenTest('save is disabled until something changes', (tester) async {
      final api = ScriptedApi();
      await tester.pumpWidget(
        host(ProfileEditorScreen(api: api, profile: _profile())),
      );

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save changes'),
      );
      expect(button.onPressed, isNull);

      await tester.enterText(
        find.widgetWithText(TextField, 'Display name'),
        'Aarav Sharma',
      );
      await tester.pump();

      final enabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save changes'),
      );
      expect(enabled.onPressed, isNotNull);
    });

    screenTest('sends the three fields the form owns, and not the email', (
      tester,
    ) async {
      final api = ScriptedApi();
      await tester.pumpWidget(
        host(ProfileEditorScreen(api: api, profile: _profile())),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Bio'),
        'third year, CSE',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
      await tester.pumpAndSettle();

      final write = api.profileWrites.single;
      expect(write['bio'], 'third year, CSE');
      // The other two belong to this form and travel as loaded, so a bio edit
      // cannot blank the display name.
      expect(write['display_name'], 'Aarav S.');
      expect(write['avatar_url'], '');
      // The email is not this form's business. Sending it here would let a
      // profile edit overwrite the address with a stale copy.
      expect(write['email'], isNull);
    });

    screenTest('a cleared bio is sent as empty rather than omitted', (
      tester,
    ) async {
      final api = ScriptedApi();
      final withBio = UserProfile(
        id: 7,
        role: 'student',
        status: 'active',
        firstName: 'Aarav',
        surname: 'Sharma',
        bio: 'old bio',
      );
      await tester.pumpWidget(
        host(ProfileEditorScreen(api: api, profile: withBio)),
      );

      await tester.enterText(find.widgetWithText(TextField, 'Bio'), '');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
      await tester.pumpAndSettle();

      // Empty means "clear this" to the API. Null would mean "leave it alone".
      expect(api.profileWrites.single['bio'], '');
    });

    screenTest('a rejected save shows the reason and stays open', (
      tester,
    ) async {
      final api = ScriptedApi()
        ..failUpdateProfile = const ApiException(
          'Cannot reach the server',
          statusCode: null,
        );
      await tester.pumpWidget(
        host(ProfileEditorScreen(api: api, profile: _profile())),
      );

      await tester.enterText(find.widgetWithText(TextField, 'Bio'), 'hello');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
      await tester.pumpAndSettle();

      // Still on the form, with the person's text intact.
      expect(find.text('Cannot reach the server'), findsOneWidget);
      expect(find.text('Bio'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save changes'), findsOneWidget);
    });

    screenTest('the legal name is shown but not editable', (tester) async {
      await tester.pumpWidget(
        host(ProfileEditorScreen(api: ScriptedApi(), profile: _profile())),
      );

      expect(find.text('Legal name'), findsOneWidget);
      expect(find.text('Aarav Sharma'), findsOneWidget);
      expect(find.text('@aarav.sharma'), findsOneWidget);
    });
  });

  group('sessions', () {
    screenTest('lists devices and marks the current one', (tester) async {
      final api = ScriptedApi()
        ..storedSessions = [
          DeviceSession(
            id: 1,
            deviceLabel: 'This phone',
            createdAt: DateTime.now().toUtc(),
            lastUsedAt: DateTime.now().toUtc(),
            isCurrent: true,
          ),
          DeviceSession(
            id: 2,
            deviceLabel: 'Old laptop',
            createdAt: DateTime.now().toUtc().subtract(
              const Duration(days: 40),
            ),
            lastUsedAt: DateTime.now().toUtc().subtract(
              const Duration(days: 10),
            ),
          ),
        ];

      await tester.pumpWidget(host(SessionsScreen(api: api)));
      await tester.pumpAndSettle();

      expect(find.text('This phone'), findsOneWidget);
      expect(find.text('Old laptop'), findsOneWidget);
      // The current device says so, and the idle one says how long ago.
      expect(find.textContaining('This device'), findsOneWidget);
      expect(find.textContaining('10 days ago'), findsOneWidget);
    });

    screenTest('an unlabelled device is not given an invented name', (
      tester,
    ) async {
      final api = ScriptedApi()
        ..storedSessions = [
          DeviceSession(
            id: 1,
            createdAt: DateTime.now().toUtc(),
            isCurrent: true,
          ),
        ];
      await tester.pumpWidget(host(SessionsScreen(api: api)));
      await tester.pumpAndSettle();

      expect(find.text('Unknown device'), findsOneWidget);
    });

    screenTest('revoking asks first and can be cancelled', (tester) async {
      final api = ScriptedApi()
        ..storedSessions = [
          DeviceSession(
            id: 2,
            deviceLabel: 'Old laptop',
            createdAt: DateTime.now().toUtc(),
          ),
        ];
      await tester.pumpWidget(host(SessionsScreen(api: api)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sign out this device'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out this device?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Nothing was revoked, because the person said no.
      expect(api.revoked, isEmpty);
    });

    screenTest('revoking after confirming calls the API', (tester) async {
      final api = ScriptedApi()
        ..storedSessions = [
          DeviceSession(
            id: 2,
            deviceLabel: 'Old laptop',
            createdAt: DateTime.now().toUtc(),
          ),
        ];
      await tester.pumpWidget(host(SessionsScreen(api: api)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sign out this device'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(api.revoked, [2]);
    });

    screenTest('sign out other devices reports when there are none', (
      tester,
    ) async {
      final api = ScriptedApi()
        ..storedSessions = [
          DeviceSession(
            id: 1,
            deviceLabel: 'This phone',
            createdAt: DateTime.now().toUtc(),
            isCurrent: true,
          ),
        ];
      await tester.pumpWidget(host(SessionsScreen(api: api)));
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Sign out other devices'),
      );
      await tester.pumpAndSettle();

      expect(find.text('No other devices are signed in.'), findsOneWidget);
      expect(api.revokeOthersCalls, 0);
    });

    screenTest('an unreachable server offers a retry', (tester) async {
      final api = ScriptedApi()
        ..failSessions = const ApiException('Cannot reach the server');
      await tester.pumpWidget(host(SessionsScreen(api: api)));
      await tester.pumpAndSettle();

      expect(find.text('Cannot reach the server'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      api.failSessions = null;
      api.storedSessions = [
        DeviceSession(
          id: 1,
          deviceLabel: 'This phone',
          createdAt: DateTime.now().toUtc(),
          isCurrent: true,
        ),
      ];
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('This phone'), findsOneWidget);
    });
  });

  group('password', () {
    screenTest('submit needs all three fields and a match', (tester) async {
      await tester.pumpWidget(host(PasswordScreen(api: ScriptedApi())));

      FilledButton button() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Change password'),
      );
      expect(button().onPressed, isNull);

      await tester.enterText(
        find.widgetWithText(TextField, 'Current password'),
        'CorrectHorse123',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'New password'),
        'AnotherPass123',
      );
      await tester.pump();
      // Mismatched confirmation.
      expect(button().onPressed, isNull);

      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm new password'),
        'AnotherPass123',
      );
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });

    screenTest('reusing the current password is refused', (tester) async {
      await tester.pumpWidget(host(PasswordScreen(api: ScriptedApi())));
      await tester.enterText(
        find.widgetWithText(TextField, 'Current password'),
        'CorrectHorse123',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'New password'),
        'CorrectHorse123',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm new password'),
        'CorrectHorse123',
      );
      await tester.pump();

      expect(find.text('That is your current password.'), findsOneWidget);
    });

    screenTest('a short password is refused before any request', (
      tester,
    ) async {
      final api = ScriptedApi();
      await tester.pumpWidget(host(PasswordScreen(api: api)));
      await tester.enterText(
        find.widgetWithText(TextField, 'Current password'),
        'CorrectHorse123',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'New password'),
        'short',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm new password'),
        'short',
      );
      await tester.pump();

      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(api.passwordChanges, 0);
    });

    screenTest('a wrong current password shows the server message', (
      tester,
    ) async {
      final api = ScriptedApi()
        ..failPassword = const ApiException(
          'Your current password is incorrect.',
          statusCode: 403,
        );
      await tester.pumpWidget(host(PasswordScreen(api: api)));

      await tester.enterText(
        find.widgetWithText(TextField, 'Current password'),
        'wrong',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'New password'),
        'AnotherPass123',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm new password'),
        'AnotherPass123',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Change password'));
      await tester.pumpAndSettle();

      expect(find.text('Your current password is incorrect.'), findsOneWidget);
    });

    screenTest('success tells the caller, because every session is gone', (
      tester,
    ) async {
      final api = ScriptedApi();
      var changed = false;
      await tester.pumpWidget(
        host(PasswordScreen(api: api, onPasswordChanged: () => changed = true)),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Current password'),
        'CorrectHorse123',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'New password'),
        'AnotherPass123',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Confirm new password'),
        'AnotherPass123',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Change password'));
      await tester.pumpAndSettle();

      expect(api.passwordChanges, 1);
      // Without this the app would keep a session the server has already ended.
      expect(changed, isTrue);
    });
  });

  group('email', () {
    screenTest('says plainly that confirmation is not happening yet', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(EmailScreen(api: ScriptedApi(), profile: _profile())),
      );

      expect(find.textContaining('not being sent yet'), findsOneWidget);
      // And offers no button that would claim otherwise.
      expect(find.text('Send verification email'), findsNothing);
    });

    screenTest('an unverified address is labelled as such', (tester) async {
      await tester.pumpWidget(
        host(EmailScreen(api: ScriptedApi(), profile: _profile())),
      );
      expect(find.text('Not confirmed.'), findsOneWidget);
    });

    screenTest('saves a new address', (tester) async {
      final api = ScriptedApi();
      await tester.pumpWidget(host(EmailScreen(api: api, profile: _profile())));

      await tester.enterText(
        find.widgetWithText(TextField, 'Email address'),
        'new@example.edu',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save address'));
      await tester.pumpAndSettle();

      expect(api.profileWrites.single['email'], 'new@example.edu');
    });

    screenTest('an obviously wrong address cannot be saved', (tester) async {
      final api = ScriptedApi();
      await tester.pumpWidget(host(EmailScreen(api: api, profile: _profile())));

      await tester.enterText(
        find.widgetWithText(TextField, 'Email address'),
        'not-an-email',
      );
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save address'),
      );
      expect(button.onPressed, isNull);
      expect(api.profileWrites, isEmpty);
    });
  });

  group('block list', () {
    screenTest('an empty list says so and offers the action', (tester) async {
      await tester.pumpWidget(host(BlockListScreen(api: ScriptedApi())));
      await tester.pumpAndSettle();

      expect(find.text('Nobody is blocked'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Block someone'),
        findsOneWidget,
      );
    });

    screenTest('lists blocked people with handle and reason', (tester) async {
      final api = ScriptedApi()
        ..storedBlocked = [_blocked('spam.bot', 'Spam', 'Bot', reason: 'Spam')];
      await tester.pumpWidget(host(BlockListScreen(api: api)));
      await tester.pumpAndSettle();

      expect(find.text('Spam Bot'), findsOneWidget);
      expect(find.textContaining('@spam.bot'), findsOneWidget);
      expect(find.textContaining('Spam'), findsWidgets);
    });

    screenTest('unblocking calls the API rather than only the list', (
      tester,
    ) async {
      final api = ScriptedApi()
        ..storedBlocked = [_blocked('spam.bot', 'Spam', 'Bot')];
      await tester.pumpWidget(host(BlockListScreen(api: api)));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Unblock'));
      await tester.pumpAndSettle();

      expect(api.unblocked, ['spam.bot']);
    });

    screenTest('adding someone through the sheet', (tester) async {
      final api = ScriptedApi();
      await tester.pumpWidget(host(BlockListScreen(api: api)));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Block someone'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Username'),
        'noisy.person',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();

      expect(find.text('Spam'), findsNothing);
      expect(api.storedBlocked.single.username, 'noisy.person');
    });

    screenTest('an unreachable server offers a retry', (tester) async {
      final api = ScriptedApi()
        ..failBlocks = const ApiException('Cannot reach the server');
      await tester.pumpWidget(host(BlockListScreen(api: api)));
      await tester.pumpAndSettle();

      expect(find.text('Cannot reach the server'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('account hub', () {
    screenTest('shows the handle and the editable rows', (tester) async {
      await tester.pumpWidget(
        host(AccountSettingsScreen(profile: _profile(), api: ScriptedApi())),
      );
      await tester.pumpAndSettle();

      expect(find.text('@aarav.sharma'), findsWidgets);
      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Change password'), findsOneWidget);
      expect(find.text('Active sessions'), findsOneWidget);
    });

    screenTest('verified-only rows are not tappable', (tester) async {
      await tester.pumpWidget(
        host(AccountSettingsScreen(profile: _profile(), api: ScriptedApi())),
      );
      await tester.pumpAndSettle();

      // College and role are fixed at registration, so they carry no chevron.
      final college = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('College'),
          matching: find.byType(ListTile),
        ),
      );
      expect(college.onTap, isNull);
    });

    screenTest('deactivate and delete are labelled, not half-built', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(AccountSettingsScreen(profile: _profile(), api: ScriptedApi())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Deactivate account'), findsOneWidget);
      expect(find.text('Delete account'), findsOneWidget);
      expect(find.text('Soon'), findsNWidgets(2));
    });
  });
}

/// A blocked person with a fixed timestamp, so list ordering is not at the
/// mercy of when the test happens to run.
BlockedUser _blocked(
  String username,
  String firstName,
  String surname, {
  String? reason,
}) => BlockedUser(
  username: username,
  firstName: firstName,
  surname: surname,
  reason: reason,
  blockedAt: DateTime.utc(2026, 1, 1),
);
