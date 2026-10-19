import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/session_gate.dart';
import 'services/auth_service.dart';
import 'services/chat_environment.dart';
import 'services/chat_lifecycle.dart';
import 'services/connectivity_monitor.dart';
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
  final connectivity = ConnectivityMonitor()..start();
  // Before runApp rather than from a provider callback: the monitor has to be
  // answering requests from the very first one, which happens during the
  // session restore below.
  auth.api.useConnectivityMonitor(connectivity);
runApp(
    MeridianApp(
      auth: auth,
      settings: settings,
      connectivity: connectivity,
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
    required this.connectivity,
    required this.chat,
  });

  final AuthService auth;
  final SettingsStore settings;
  final ConnectivityMonitor connectivity;
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
        // One answer to "can we reach the network", fed by the outcome of real
        // requests rather than by the radio, which reports a bar of signal
        // behind a lift door as a perfectly good connection.
        ChangeNotifierProvider<ConnectivityMonitor>.value(value: connectivity),
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
            home: ChatLifecycleObserver(child: SessionGate(auth: auth)),
          );
        },
      ),
    );
  }
}