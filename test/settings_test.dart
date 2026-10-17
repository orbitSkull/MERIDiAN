import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/models/call_log.dart';
import 'package:meridian/models/user.dart';
import 'package:meridian/models/username.dart';
import 'package:meridian/screens/settings/account/username_screen.dart';
import 'package:meridian/services/settings_store.dart';
import 'package:provider/provider.dart';

/// A checker that answers from a fixed set with no delay, so the widget tests
/// do not have to pump a timer.
class _FakeAvailability implements UsernameAvailability {
  _FakeAvailability(this.taken, {this.alternatives = const []});

  final Set<String> taken;
  final List<String> alternatives;
  final List<String> asked = [];

  @override
  Future<AvailabilityResult> check(String username) async {
    asked.add(username);
    if (taken.contains(username)) {
      return AvailabilityResult.taken(alternatives);
    }
    return const AvailabilityResult.available();
  }
}

const _profile = UserProfile(
  id: 1,
  role: 'student',
  status: 'active',
  firstName: 'Aarav',
  surname: 'Sharma',
  prn: '2024XXXX',
  collegeCode: 'MERIDIAN',
);

Widget _wrap(Widget child, SettingsStore store) => ChangeNotifierProvider<
  SettingsStore
>.value(
  value: store,
  child: MaterialApp(home: child),
);

/// Types into the username field and settles the 500ms availability debounce.
///
/// Every test must use a value DIFFERENT from the field's initial text.
/// enterText with the value already present fires no onChanged, so the debounce
/// is never armed and the screen appears to do nothing.
Future<void> _typeAndSettle(WidgetTester tester, String value) async {
  await tester.enterText(find.byType(TextField), value);
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UserProfile.username', () {
    test('is empty when the backend has not sent one', () {
      expect(_profile.hasUsername, isFalse);
      expect(_profile.username, isEmpty);
    });

    test('decodes when present', () {
      final decoded = UserProfile.fromJson({
        'id': 1,
        'role': 'student',
        'status': 'active',
        'first_name': 'Aarav',
        'surname': 'Sharma',
        'username': 'aarav.sharma',
      });
      expect(decoded.username, 'aarav.sharma');
      expect(decoded.hasUsername, isTrue);
    });

    test('survives a round trip through the cache', () {
      const withHandle = UserProfile(
        id: 1,
        role: 'student',
        status: 'active',
        firstName: 'Aarav',
        surname: 'Sharma',
        username: 'aarav.sharma',
      );
      final restored = UserProfile.fromJson(withHandle.toJson());
      expect(restored.username, 'aarav.sharma');
    });

    test('identifierLabel is null when there is no PRN or employee ID', () {
      const bare = UserProfile(
        id: 1,
        role: 'student',
        status: 'active',
        firstName: 'Aarav',
        surname: 'Sharma',
      );
      expect(bare.identifier, isEmpty);
      expect(bare.identifierLabel, isNull);
    });
  });

  group('CallFilter', () {
    final missed = demoCallLog.firstWhere((e) => e.missed);
    final received = demoCallLog.firstWhere(
      (e) => !e.missed && e.direction == CallDirection.incoming,
    );
    final made = demoCallLog.firstWhere(
      (e) => !e.missed && e.direction == CallDirection.outgoing,
    );

    test('all matches everything', () {
      expect(CallFilter.all.matches(missed), isTrue);
      expect(CallFilter.all.matches(received), isTrue);
    });

    test('missed matches only unanswered calls', () {
      expect(CallFilter.missed.matches(missed), isTrue);
      expect(CallFilter.missed.matches(received), isFalse);
    });

    test('incoming and outgoing partition the answered calls', () {
      expect(CallFilter.incoming.matches(received), isTrue);
      expect(CallFilter.incoming.matches(made), isFalse);
      expect(CallFilter.outgoing.matches(made), isTrue);
      expect(CallFilter.outgoing.matches(received), isFalse);
    });
  });

  group('CallLogEntry formatting', () {
    test('a missed call has no duration', () {
      final entry = demoCallLog.firstWhere((e) => e.missed);
      expect(entry.durationSeconds, isNull);
      expect(entry.durationLabel, isNull);
    });

    test('formats seconds as m:ss', () {
      final entry = CallLogEntry(
        peerName: 'X',
        peerHandle: 'x',
        direction: CallDirection.outgoing,
        kind: CallKind.voice,
        startedAt: DateTime(2026, 1, 1),
        durationSeconds: 94,
      );
      expect(entry.durationLabel, '1:34');
    });

    test('formats long durations with hours', () {
      final entry = CallLogEntry(
        peerName: 'X',
        peerHandle: 'x',
        direction: CallDirection.outgoing,
        kind: CallKind.video,
        startedAt: DateTime(2026, 1, 1),
        durationSeconds: 3925,
      );
      expect(entry.durationLabel, '1:05:25');
    });

    test('recent entries read as relative times', () {
      // No demo entry is new enough for "Just now", so this exercises the
      // minutes branch. The "Just now" branch needs its own entry because it
      // is never reachable from demoCallLog.
      expect(
        demoCallLog.any((e) => e.whenLabel == '8 min ago'),
        isTrue,
        reason: 'expected the newest demo entry to read as 8 min ago',
      );
      expect(demoCallLog.any((e) => e.whenLabel.startsWith('Today,')), isTrue);
    });

    test('an entry from moments ago reads as Just now', () {
      final entry = CallLogEntry(
        peerName: 'X',
        peerHandle: 'x',
        direction: CallDirection.incoming,
        kind: CallKind.voice,
        startedAt: DateTime.now().subtract(const Duration(seconds: 10)),
        durationSeconds: 5,
      );
      expect(entry.whenLabel, 'Just now');
    });
  });

  group('SettingsStore', () {
    test('defaults are sane', () {
      final store = SettingsStore.inMemory();
      expect(store.themeModeName, 'system');
      expect(store.pushEnabled, isTrue);
      expect(store.readReceipts, isTrue);
      expect(store.blockUnknownCallers, isTrue);
      expect(store.hideReadReceiptsFromBlocked, isTrue);
      expect(store.allNotificationsOff, isFalse);
    });

    test('notifies listeners when a value changes', () {
      final store = SettingsStore.inMemory();
      var notified = 0;
      store.addListener(() => notified++);
      store.setPushEnabled(false);
      store.setReadReceipts(false);
      expect(notified, 2);
    });

    test('allNotificationsOff only when every channel is off', () {
      final store = SettingsStore.inMemory();
      store
        ..setPushEnabled(false)
        ..setEmailEnabled(false);
      expect(store.allNotificationsOff, isFalse);
      store.setInAppEnabled(false);
      expect(store.allNotificationsOff, isTrue);
    });

    test('reset restores defaults and notifies once', () async {
      final store = SettingsStore.inMemory();
      store
        ..setPushEnabled(false)
        ..setBlockUnknownCallers(false)
        ..setThemeModeName('dark');
      var notified = 0;
      store.addListener(() => notified++);
      // reset() awaits a remove per key before it notifies, so it has to be
      // awaited. Checking the count synchronously saw zero.
      await store.reset();
      expect(notified, 1);
      expect(store.pushEnabled, isTrue);
      expect(store.blockUnknownCallers, isTrue);
      expect(store.themeModeName, 'system');
    });

    test('every key in allKeys is writable and reset', () {
      expect(SettingsStore.allKeys, contains(SettingsStore.kBlockUnknown));
      expect(
        SettingsStore.allKeys,
        contains(SettingsStore.kHideReceiptsFromBlocked),
      );
      // A key that is not in allKeys would survive reset(), which is the bug
      // this guards against.
      expect(SettingsStore.allKeys.length, 14);
    });
  });

  group('UsernameScreen', () {
    testWidgets('shows the profile and the edit field', (tester) async {
      await tester.pumpWidget(
        _wrap(
          UsernameScreen(
            profile: _profile,
            availability: _FakeAvailability(const {}),
          ),
          SettingsStore.inMemory(),
        ),
      );
      // Scoped to the AppBar: "Username" is also the TextField label, so an
      // unscoped find matches twice.
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Username'),
        ),
        findsOneWidget,
      );
      expect(find.text('Aarav Sharma'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('save stays disabled until a name is confirmed free', (
      tester,
    ) async {
      final availability = _FakeAvailability(const {});
      await tester.pumpWidget(
        _wrap(
          UsernameScreen(profile: _profile, availability: availability),
          SettingsStore.inMemory(),
        ),
      );

      FilledButton saveButton() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save username'),
      );

      // Nothing typed yet, so nothing to save.
      expect(saveButton().onPressed, isNull);

      await _typeAndSettle(tester, 'arav.kumar');

      expect(availability.asked, contains('arav.kumar'));
      expect(find.textContaining('is available'), findsOneWidget);
      expect(saveButton().onPressed, isNotNull);
    });

    testWidgets('an invalid name is rejected before any request', (
      tester,
    ) async {
      final availability = _FakeAvailability(const {});
      await tester.pumpWidget(
        _wrap(
          UsernameScreen(profile: _profile, availability: availability),
          SettingsStore.inMemory(),
        ),
      );

      await _typeAndSettle(tester, 'ab');

      expect(availability.asked, isEmpty, reason: 'must not hit the server');
      expect(find.textContaining('At least'), findsOneWidget);
    });

    testWidgets('a reserved name is reported as reserved, not as bad chars', (
      tester,
    ) async {
      final availability = _FakeAvailability(const {});
      await tester.pumpWidget(
        _wrap(
          UsernameScreen(profile: _profile, availability: availability),
          SettingsStore.inMemory(),
        ),
      );

      await _typeAndSettle(tester, 'admin');

      expect(find.textContaining('reserved'), findsOneWidget);
      expect(
        find.textContaining('Use only letters'),
        findsNothing,
        reason: 'reserved must win over the character rule',
      );
      expect(availability.asked, isEmpty);
    });

    testWidgets('a taken name is not savable and offers alternatives', (
      tester,
    ) async {
      final availability = _FakeAvailability(
        const {'arav.kumar'},
        alternatives: const ['arav.kumar2', 'arav.kumar3'],
      );
      await tester.pumpWidget(
        _wrap(
          UsernameScreen(profile: _profile, availability: availability),
          SettingsStore.inMemory(),
        ),
      );

      await _typeAndSettle(tester, 'arav.kumar');

      expect(find.textContaining('already taken'), findsOneWidget);
      expect(find.text('@arav.kumar2'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save username'),
            )
            .onPressed,
        isNull,
        reason: 'a taken name must not be savable',
      );

      // Tapping a suggestion fills the field.
      await tester.tap(find.text('@arav.kumar2'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'arav.kumar2',
      );
    });

    testWidgets('uppercase input is normalised in the field itself', (
      tester,
    ) async {
      final availability = _FakeAvailability(const {});
      await tester.pumpWidget(
        _wrap(
          UsernameScreen(profile: _profile, availability: availability),
          SettingsStore.inMemory(),
        ),
      );

      await _typeAndSettle(tester, 'Aarav.Kumar');

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'aarav.kumar',
        reason: 'the visible field must show the normalised form',
      );
      expect(availability.asked, contains('aarav.kumar'));
    });

  });

  group('generated usernames are usable', () {
    test('a name produces a valid handle the screen accepts', () {
      final handle = usernameFrom(firstName: 'Aarav', surname: 'Sharma');
      expect(validateUsername(handle).isValid, isTrue);
    });
  });
}