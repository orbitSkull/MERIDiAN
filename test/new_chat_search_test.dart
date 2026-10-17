import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/models/settings.dart';
import 'package:meridian/models/user.dart';
import 'package:meridian/screens/home/new_chat_screen.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/meridian_api.dart';

/// Answers lookups from a script instead of the network.
class LookupApi implements MeridianApi {
  UserLookup answer = UserLookup.notFound;
  ApiException? failure;
  final List<String> asked = [];

  @override
  Future<UserLookup> lookupUser(String username) async {
    asked.add(username);
    final error = failure;
    if (error != null) throw error;
    return answer;
  }

  @override
  Future<UserProfile> me() async => throw UnimplementedError();

  @override
  Future<UserProfile> updateProfile({
    String? displayName,
    String? bio,
    String? avatarUrl,
    String? email,
  }) async => throw UnimplementedError();

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async => throw UnimplementedError();

  @override
  Future<List<DeviceSession>> sessions() async => throw UnimplementedError();

  @override
  Future<void> revokeSession(int sessionId) async => throw UnimplementedError();

  @override
  Future<void> revokeOtherSessions() async => throw UnimplementedError();

  @override
  Future<List<BlockedUser>> blockedUsers() async => throw UnimplementedError();

  @override
  Future<List<BlockedUser>> block(String username, {String? reason}) async =>
      throw UnimplementedError();

  @override
  Future<void> unblock(String username) async => throw UnimplementedError();

  @override
  Future<UserPreferences> preferences() async => throw UnimplementedError();

  @override
  Future<UserPreferences> updatePreferences(Map<String, bool> changes) async =>
      throw UnimplementedError();

  @override
  Future<String> saveUsername(String username) async =>
      throw UnimplementedError();
}

const _aarav = DirectoryUser(
  username: 'aarav.sharma',
  firstName: 'Aarav',
  surname: 'Sharma',
  role: 'student',
  collegeCode: 'MERIDIAN',
);

/// Types a handle and waits out the debounce plus the lookup.
Future<void> search(WidgetTester tester, String handle) async {
  await tester.enterText(find.byType(TextField).first, handle);
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

void main() {
  late LookupApi api;

  setUp(() => api = LookupApi());

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: NewChatScreen(api: api)));
    await tester.pumpAndSettle();
  }

  testWidgets('says what to do before anything is typed', (tester) async {
    await open(tester);

    expect(find.text('Find somebody by their handle'), findsOneWidget);
    expect(find.text('Message'), findsNothing);
  });

  testWidgets('an exact handle resolves to the person', (tester) async {
    api.answer = const UserLookup(found: true, user: _aarav);
    await open(tester);

    await search(tester, 'aarav.sharma');

    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.textContaining('@aarav.sharma'), findsOneWidget);
    expect(find.textContaining('Student'), findsOneWidget);
    expect(find.textContaining('MERIDIAN'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
  });

  testWidgets('uppercase is normalised before the request', (tester) async {
    api.answer = const UserLookup(found: true, user: _aarav);
    await open(tester);

    await search(tester, 'Aarav.Sharma');

    // Handles are lowercase. Asking with capitals would be answered from the
    // grammar without a query, so the person would never be found.
    expect(api.asked, ['aarav.sharma']);
    expect(find.text('Aarav Sharma'), findsOneWidget);
  });

  testWidgets('a miss says no account found, and blames nothing', (
    tester,
  ) async {
    await open(tester);

    await search(tester, 'nobody.here');

    expect(find.text('No account found'), findsOneWidget);
    // Must not imply the handle is free, because the endpoint answers a miss the
    // same way whether or not somebody holds it.
    expect(find.textContaining('available'), findsNothing);
    expect(find.text('Message'), findsNothing);
  });

  testWidgets('an invalid handle is not sent at all', (tester) async {
    await open(tester);

    // Too short, and containing a space.
    await search(tester, 'ab');
    expect(api.asked, isEmpty);

    // Well-formed but misspelt still goes, because the server has the final say
    // on what exists.
    await search(tester, 'not_a_person');
    expect(api.asked, ['not_a_person']);
  });

  testWidgets('the keyboard refuses characters a handle cannot contain', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(find.byType(TextField).first, 'aarav sharma!');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    // The formatter strips what a handle cannot contain, so the field ends up
    // holding the normalised handle and that is what gets looked up.
    expect(api.asked, ['aaravsharma']);
    expect(find.text('aaravsharma'), findsOneWidget);
  });

  testWidgets('editing past a result clears it', (tester) async {
    api.answer = const UserLookup(found: true, user: _aarav);
    await open(tester);
    await search(tester, 'aarav.sharma');
    expect(find.text('Aarav Sharma'), findsOneWidget);

    // Deleting to an invalid handle must not leave Aarav's name sitting under a
    // handle that no longer matches.
    await search(tester, 'aa');

    expect(find.text('Aarav Sharma'), findsNothing);
  });

  testWidgets('an unreachable server offers a retry', (tester) async {
    api.failure = const ApiException('Cannot reach the server');
    await open(tester);

    await search(tester, 'aarav.sharma');

    expect(find.text('Could not search'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    api.failure = null;
    api.answer = const UserLookup(found: true, user: _aarav);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Aarav Sharma'), findsOneWidget);
  });

  testWidgets('message says plainly that chat is not built', (tester) async {
    api.answer = const UserLookup(found: true, user: _aarav);
    await open(tester);
    await search(tester, 'aarav.sharma');

    await tester.tap(find.widgetWithText(FilledButton, 'Message'));
    await tester.pumpAndSettle();

    expect(find.textContaining('not built yet'), findsOneWidget);
  });
}
