import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/chat_environment.dart';
import '../services/push_registration.dart';
import '../theme/app_theme.dart';
import 'home/conversation_controller.dart';
import 'home/conversation_screen.dart';
import 'home/home_screen.dart';
import 'onboarding_screen.dart';

/// Decides the first screen at launch.
///
/// Restores any persisted session before showing anything, so a returning
/// user goes straight to the home screen rather than the login form.
class SessionGate extends StatefulWidget {
  final AuthService auth;

  const SessionGate({super.key, required this.auth});

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  late Future<SessionStatus> _bootstrap = widget.auth.restoreSession();

  /// The status the chat environment was last opened for, so a rebuild does not
  /// open it twice and two statuses do not race.
  SessionStatus? _openedFor;

  /// Watched so a notification tapped while the app is already open still opens
  /// its conversation, not just the cold-start case.
  PushRegistration? _push;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final push = context.read<PushRegistration>();
    if (identical(push, _push)) return;
    _push?.removeListener(_onPush);
    _push = push..addListener(_onPush);
  }

  @override
  void dispose() {
    _push?.removeListener(_onPush);
    super.dispose();
  }

  void _onPush() => _openPendingConversation();

  /// Open whatever conversation a tapped notification pointed at.
  ///
  /// Take-then-navigate rather than navigate-then-clear, so a rebuild mid-push
  /// cannot open the same conversation twice.
  void _openPendingConversation() {
    final push = _push;
    if (push == null || !mounted) return;
    final envelope = push.takePendingOpen();
    if (envelope == null) return;

    final chat = context.read<ChatEnvironmentHolder>().environment;
    final myUserId = widget.auth.user?.id;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          controller: ConversationController(
            conversationId: envelope.conversationId,
            myUserId: myUserId,
            api: chat.api,
            store: chat.store,
            outbox: chat.outbox,
            sender: chat.senderFor(myUserId ?? 0),
            sync: chat.sync,
            realtime: chat.realtime,
          ),
          myUserId: myUserId,
        ),
      ),
    );
  }

  void _retry() {
    setState(() {
      _bootstrap = widget.auth.restoreSession();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SessionStatus>(
      future: _bootstrap,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _SplashScreen();
        }

        if (snapshot.hasError) {
          return _StartupError(onRetry: _retry);
        }

        final status = snapshot.data!;

        // Open the store and start the live socket whenever there is a session,
        // exactly once per status. The store has to be open before any socket
        // event can write into it, and the socket has to be started by somebody
        // who knows there is a session -- otherwise it spends its life
        // reconnecting to a server that will not accept it.
        if (status != _openedFor) {
          _openedFor = status;
          if (status == SessionStatus.signedIn ||
              status == SessionStatus.signedInOffline) {
            context
                .read<ChatEnvironmentHolder>()
                .environment
                .open()
                .catchError((Object error) {
                  // A database that will not open is fatal for chat, but not
                  // for the app: the user can still read their profile and
                  // change settings. Logged rather than fatal on purpose.
                  debugPrint('Could not open the chat store: $error');
});
          }

          // A notification tapped before there was a session -- the common case,
          // since a notification is what wakes the phone up in the first place.
          // Only once per status, and after the environment is opened, because
          // the controller below needs a store to read the conversation from.
          _openPendingConversation();
        }

        return switch (status) {
          SessionStatus.signedIn ||
          SessionStatus.signedInOffline => HomeScreen(auth: widget.auth),
          SessionStatus.signedOut => OnboardingScreen(auth: widget.auth),
        };
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'MERIDiAN',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                color: AppColors.primary,
              ),
            ),
            SizedBox(height: 24),
            SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  final VoidCallback onRetry;

  const _StartupError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                size: 48,
                color: AppColors.subtext,
              ),
              const SizedBox(height: 16),
              Text(
                'Cannot reach MERIDiAN',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Check your connection and try again.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.subtext,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(180, 48),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
