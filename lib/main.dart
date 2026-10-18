import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/session_gate.dart';
import 'services/auth_service.dart';
import 'services/chat_environment.dart';
import 'services/push_registration.dart';
import 'services/push_service.dart';
import 'services/settings_store.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  // Read persisted preferences before the first frame. Doing this inside main
  // rather than after runApp avoids a flash of the wrong theme on launch,
  // which is what happened when the mode was never persisted at all.
  await AppThemeMode.load();
  final settings = await SettingsStore.load();

  final auth = AuthService();
  runApp(
    MeridianApp(
      auth: auth,
      settings: settings,
      // Built once here rather than per screen: the store is a database on
      // disk, and a second one per conversation would be a second chat history.
      chat: ChatEnvironmentHolder(api: auth.api),
    ),
  );
}

class MeridianApp extends StatelessWidget {
  const MeridianApp({
    super.key,
    required this.auth,
    required this.settings,
    required this.chat,
  });

  final AuthService auth;
  final SettingsStore settings;
  final ChatEnvironmentHolder chat;

  @override
  Widget build(BuildContext context) {
    // SettingsStore is above MaterialApp so both SessionGate and every screen
    // below it can read it. Theme stays a ValueListenableBuilder rather than a
    // provider consumer because AppThemeMode is a static, app-wide singleton
    // with no instance to pass down.
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthService>.value(value: auth),
        // Above MaterialApp so every chat screen below can reach the store,
        // and so sign-out has one place to wipe another person's messages.
        ChangeNotifierProvider<ChatEnvironmentHolder>.value(value: chat),
        // Push registration follows the session for the same reason: a Firebase
        // token survives a sign-out, so without this a sold phone would keep
        // telling the next owner about the previous owner's messages.
        //
        // Seeded with the real service here rather than inside the widget,
        // because main is the one place that is allowed to touch Firebase.
        ChangeNotifierProxyProvider<AuthService, PushRegistration>(
          create: (_) => PushRegistration(
            service: FcmPushService(api: auth.api),
          ),
          update: (_, auth, push) {
            push!.bindApi(auth.isSignedIn ? auth.api : null);
            return push;
          },
        ),
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