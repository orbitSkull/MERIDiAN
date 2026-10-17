import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
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
        return switch (status) {
          SessionStatus.signedIn ||
          SessionStatus.signedInOffline => HomeScreen(
            auth: widget.auth,
            // Read from the service rather than passed in: the cached profile
            // is restored during bootstrap, so by the time this builds it is
            // populated for both the online and the offline path. Null when
            // the cache was cleared or the token outlived the profile, and the
            // settings hub handles that by hiding the account rows.
            profile: widget.auth.user,
          ),
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
