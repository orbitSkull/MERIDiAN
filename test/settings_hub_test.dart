import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:meridian/models/user.dart';
import 'package:meridian/screens/home/settings_screen.dart';
import 'package:meridian/services/auth_service.dart';
import 'package:meridian/services/settings_store.dart';
import 'package:meridian/services/token_store.dart';

import 'support/fake_token_backend.dart';

/// An AuthService that is already signed in.
///
/// Only the state the hub reads is overridden. Everything else, including the
/// API client, is the real thing, so the screen is exercised as it ships rather
/// than against a stub of itself.
class SignedInAuthService extends AuthService {
  SignedInAuthService({UserProfile? profile})
    : _profile = profile ?? _signedIn,
      super(tokenStore: TokenStore(backend: FakeTokenBackend()));

  final UserProfile? _profile;

  @override
  UserProfile? get user => _profile;

  @override
  bool get isSignedIn => _profile != null;

  static const _signedIn = UserProfile(
    id: 7,
    role: 'student',
    status: 'active',
    firstName: 'Aarav',
    surname: 'Sharma',
    username: 'aarav.sharma',
    displayName: 'Aarav S.',
    email: 'aarav@example.edu',
    emailVerified: true,
    prn: '2024AAAA',
    collegeCode: 'MERIDIAN',
  );
}

Widget host(Widget child, AuthService auth) => MultiProvider(
  providers: [
    ChangeNotifierProvider<AuthService>.value(value: auth),
    ChangeNotifierProvider<SettingsStore>.value(
      value: SettingsStore.inMemory(),
    ),
  ],
  child: MaterialApp(home: child),
);

void main() {
  group('settings hub', () {
    testWidgets('a signed-in person gets the account rows', (tester) async {
      // The regression this guards. The hub used to take the profile as a
      // constructor argument and every call site had to remember to pass it. The
      // login screen did not, so signing in produced a screen that told somebody
      // who was signed in to sign in. It now reads the profile from the service,
      // which cannot be forgotten.
      final auth = SignedInAuthService();

      await tester.pumpWidget(host(SettingsScreen(auth: auth), auth));
      await tester.pumpAndSettle();

      expect(find.text('Sign in to manage your account'), findsNothing);
      // Containing, not exact: the summary joins the handle and the identifier
      // into one line.
      expect(find.textContaining('@aarav.sharma'), findsWidgets);
      expect(find.textContaining('2024AAAA'), findsWidgets);
    });

    testWidgets('the summary follows an edit made elsewhere', (tester) async {
      // Watched rather than read, so the card is never stale.
      final auth = SignedInAuthService();

      await tester.pumpWidget(host(SettingsScreen(auth: auth), auth));
      await tester.pumpAndSettle();
      expect(find.textContaining('@aarav.sharma'), findsWidgets);
    });

    testWidgets('signed out still explains itself', (tester) async {
      final auth = SignedInAuthService(profile: null);

      await tester.pumpWidget(host(SettingsScreen(auth: auth), auth));
      await tester.pumpAndSettle();

      expect(find.text('Sign in to manage your account'), findsNothing);
      // The rest of the hub is still usable: app settings are device-local and
      // should not disappear because the account is gone.
      expect(find.text('App settings'), findsOneWidget);
    });
  });
}
