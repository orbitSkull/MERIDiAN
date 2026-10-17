import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/session_gate.dart';
import 'services/auth_service.dart';
import 'services/settings_store.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  // Read persisted preferences before the first frame. Doing this inside main
  // rather than after runApp avoids a flash of the wrong theme on launch,
  // which is what happened when the mode was never persisted at all.
  await AppThemeMode.load();
  final settings = await SettingsStore.load();

  runApp(MeridianApp(auth: AuthService(), settings: settings));
}

class MeridianApp extends StatelessWidget {
  const MeridianApp({super.key, required this.auth, required this.settings});

  final AuthService auth;
  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    // SettingsStore is above MaterialApp so both SessionGate and every screen
    // below it can read it. Theme stays a ValueListenableBuilder rather than a
    // provider consumer because AppThemeMode is a static, app-wide singleton
    // with no instance to pass down.
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: auth),
        // A proxy rather than a plain provider, because preferences only sync
        // while somebody is signed in. This is where the store learns about the
        // session: attached on sign-in, detached on sign-out, so a toggle
        // tapped after leaving the account is never pushed to whoever signs in
        // next.
        ChangeNotifierProxyProvider<AuthService, SettingsStore>(
          create: (_) => settings,
          update: (_, auth, store) {
            store!.bindApi(auth.isSignedIn ? auth.api : null);
            return store;
          },
        ),
      ],
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: AppThemeMode.notifier,
        builder: (context, mode, _) {
          return MaterialApp(
            title: 'MERIDiAN',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: mode,
            home: SessionGate(auth: auth),
          );
        },
      ),
    );
  }
}