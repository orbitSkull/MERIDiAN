import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/models/settings.dart';
import 'package:meridian/models/user.dart';
import 'package:meridian/screens/home/new_chat_screen.dart';
import 'package:meridian/services/api_client.dart';

import 'support/stub_meridian_api.dart';

/// Answers searches from a script, and records what was asked.
///
/// Recording the queries is the point of half of these tests: the interesting
/// failures are the requests that should never have been made.
class SearchApi extends StubMeridianApi {
  UserSearch answer = UserSearch.empty;
  ApiException? failure;
  final List<String> asked = [];

  @override
  Future<UserSearch> searchUsers(String query) async {
    asked.add(query);
    final error = failure;
    if (error != null) throw error;
    return answer;
  }

  @override
  Future<UserLookup> lookupUser(String username) async => UserLookup.notFound;

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

const _kavya = DirectoryUser(
  username: 'k.aarav',
  firstName: 'Kavya',
  surname: 'Menon',
  role: 'faculty',
);

UserSearch _results(List<DirectoryUser> people, {bool truncated = false}) =>
    UserSearch(query: 'aar', results: people, truncated: truncated);

/// Types a query and waits out the debounce and the search.
Future<void> type(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

void main() {
  late SearchApi api;

  setUp(() => api = SearchApi());

  Future<void> open(WidgetTester tester, {String? myUsername}) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: NewChatScreen(api: api, myUsername: myUsername),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('says what to do before anything is typed', (tester) async {
    await open(tester);

    expect(find.text('Find somebody to message'), findsOneWidget);
    expect(find.text('At least 3 characters.'), findsOneWidget);
  });

  testWidgets('lists everybody whose handle contains the query', (
    tester,
  ) async {
    api.answer = _results([_aarav, _kavya]);
    await open(tester);

    // A partial query, matching in the middle of one handle and the start of
    // the other.
    await type(tester, 'aar');

    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('Kavya Menon'), findsOneWidget);
    expect(find.textContaining('@k.aarav'), findsOneWidget);
    expect(find.textContaining('Faculty'), findsOneWidget);
  });

  testWidgets('uppercase is normalised before the request', (tester) async {
    api.answer = _results([_aarav]);
    await open(tester);

    await type(tester, 'AAR');

    expect(api.asked, ['aar']);
  });

  testWidgets('a short query is never sent', (tester) async {
    await open(tester);

    await type(tester, 'a');
    expect(api.asked, isEmpty);

    await type(tester, 'aa');
    expect(api.asked, isEmpty, reason: 'two characters cannot be searched');

    // Three is the shortest the server answers, and the screen matches it.
    await type(tester, 'aar');
    expect(api.asked, ['aar']);
  });

  testWidgets('the keyboard refuses characters a handle cannot contain', (
    tester,
  ) async {
    await open(tester);

    await tester.enterText(find.byType(TextField).first, 'aar v!');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    // Normalised by the input formatter rather than rejected, so the person
    // does not have to know the rules.
    expect(api.asked, ['aarv']);
  });

  testWidgets('editing away from a result clears the list', (tester) async {
    api.answer = _results([_aarav, _kavya]);
    await open(tester);
    await type(tester, 'aar');
    expect(find.text('Aarav Sharma'), findsOneWidget);

    // Back below the minimum: the names must go rather than sit under a query
    // that no longer matches them.
    await type(tester, 'aa');

    expect(find.text('Aarav Sharma'), findsNothing);
    expect(find.text('Kavya Menon'), findsNothing);
  });

  testWidgets('you are not listed as somebody to message', (tester) async {
    api.answer = _results([_aarav, _kavya]);
    await open(tester, myUsername: 'aarav.sharma');

    await type(tester, 'aar');

    expect(find.text('Aarav Sharma'), findsNothing);
    expect(find.text('Kavya Menon'), findsOneWidget);
  });

  testWidgets('a query that only matches you says so', (tester) async {
    api.answer = _results([_aarav]);
    await open(tester, myUsername: 'aarav.sharma');

    await type(tester, 'aar');

    expect(find.text('That only matched you.'), findsOneWidget);
  });

  testWidgets('nobody found is a plain empty state', (tester) async {
    await open(tester);

    await type(tester, 'zzz');

    expect(find.text('Nobody found'), findsOneWidget);
    expect(find.textContaining('No username contains "zzz"'), findsOneWidget);
  });

  testWidgets('a capped result says the list is a page', (tester) async {
    // Otherwise twenty rows read as "these are the only twenty people".
    api.answer = _results([_aarav, _kavya], truncated: true);
    await open(tester);

    await type(tester, 'aar');

    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.textContaining('More people match'), findsOneWidget);
  });

  testWidgets('an uncapped result shows no such notice', (tester) async {
    api.answer = _results([_aarav, _kavya]);
    await open(tester);

    await type(tester, 'aar');

    expect(find.textContaining('More people match'), findsNothing);
  });

  testWidgets('an unreachable server offers a retry', (tester) async {
    api.failure = const ApiException('Cannot reach the server');
    await open(tester);

    await type(tester, 'aar');
    expect(find.text('Could not search'), findsOneWidget);

    api.failure = null;
    api.answer = _results([_aarav]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Aarav Sharma'), findsOneWidget);
  });

  testWidgets('tapping somebody says chat is not built', (tester) async {
    api.answer = _results([_aarav, _kavya]);
    await open(tester);
    await type(tester, 'aar');

    await tester.tap(find.text('Aarav Sharma'));
    await tester.pumpAndSettle();

    expect(find.textContaining('not built yet'), findsOneWidget);
  });
}
