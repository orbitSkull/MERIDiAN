import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/user.dart';
import '../../services/auth_service.dart';
import '../../services/meridian_api.dart';
import '../../services/settings_store.dart';
import '../../services/usage_username_availability.dart';
import '../onboarding_screen.dart';
import '../settings/account/account_settings_screen.dart';
import '../settings/app/app_settings_screen.dart';
import '../settings/backup/backup_screen.dart';
import '../settings/blocks/block_list_screen.dart';
import '../settings/calls/call_history_screen.dart';
import '../settings/web/web_connect_screen.dart';

/// Settings tab.
///
/// A hub: each of the six categories is a destination rather than a panel, so
/// the list stays scannable and each category owns its own sections.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.auth,
    required this.profile,
    this.usernameAvailability,
  });

  final AuthService auth;

  /// Null while signed out, in which case the account rows are not shown.
  final UserProfile? profile;

  /// Injected so the username screen can be exercised with a fake checker.
  final UsernameAvailability? usernameAvailability;

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  Future<void> _logout(BuildContext context, {String? reason}) async {
    // A password change has already ended every session server side, so there
    // is nothing to confirm and nothing to revoke: asking "Log out?" would be
    // asking permission to do something that already happened.
    if (reason == null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Log out?'),
          content: const Text(
            'You will need your college ID and password to sign back in.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Log out'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }

    // Revokes the refresh token server-side and clears local tokens. After a
    // password change that token is already dead, and logout is best-effort
    // about it, so this still lands on the login screen.
    await auth.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => OnboardingScreen(auth: auth)),
      (_) => false,
    );
    if (reason != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(reason)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = this.profile;
    final store = context.watch<SettingsStore>();
    final api = profile == null ? null : auth.api;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (profile != null) ...[
          _AccountSummary(
            profile: profile,
            onTap: () => _push(
              context,
              AccountSettingsScreen(
                profile: profile,
                api: api,
                usernameAvailability: usernameAvailability,
                // Re-read rather than trusting what the editor had on screen, so
                // the summary card and every other screen agree with the server.
                onProfileChanged: (_) => auth.refreshProfile(),
                onSignOutRequired: () => _logout(
                  context,
                  reason: 'Password changed. Sign in again.',
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        for (final entry in _categories)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ListTile(
                leading: Icon(entry.icon),
                title: Text(
                  entry.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  entry.subtitle(context, profile, store),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                onTap: () => _push(
                  context,
                  entry.build(context, profile, auth.api),
                ),
              ),
            ),
          ),
        if (store.syncError != null) ...[
          const SizedBox(height: 4),
          _SyncWarning(
            message: store.syncError!,
            onRetry: () => store.syncFromServer(),
          ),
        ],
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.logout_rounded, color: Colors.red),
            title: const Text(
              'Log out',
              style: TextStyle(fontWeight: FontWeight.w700, color: Colors.red),
            ),
            onTap: () => _logout(context),
          ),
        ),
      ],
    );
  }
}

/// Shown when the last preference change could not reach the server.
///
/// Said plainly rather than silently retrying: a switch that looks saved and is
/// not is the kind of thing a person only discovers on another device.
class _SyncWarning extends StatelessWidget {
  const _SyncWarning({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ListTile(
        leading: const Icon(Icons.cloud_off_rounded),
        title: const Text(
          'Not synced',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(message),
        trailing: TextButton(onPressed: onRetry, child: const Text('Retry')),
      ),
    );
  }
}

/// A category row on the hub.
///
/// [subtitle] takes the profile and settings so a row can report current state
/// instead of a fixed description, which is what makes the list worth reading
/// rather than skipping.
class _Category {
  const _Category({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.build,
  });

  final IconData icon;
  final String title;
  final String Function(BuildContext, UserProfile?, SettingsStore) subtitle;
  final Widget Function(BuildContext, UserProfile?, MeridianApi) build;
}

/// The categories, built against the signed-in API.
///
/// [build] takes the client so the account and block screens can really read
/// and write. They are given null when signed out and render a signed-out
/// notice instead of firing requests that would 401.
final List<_Category> _categories = [
  _Category(
    icon: Icons.person_outline_rounded,
    title: 'Account settings',
    subtitle: (context, profile, _) =>
        profile?.preferredName.isNotEmpty == true
        ? '${profile!.preferredName}${profile.hasUsername ? '  ·  @${profile.username}' : ''}'
        : 'Profile, username, security',
    build: (context, profile, api) => profile == null
        ? const _SignedOutNotice()
        : AccountSettingsScreen(profile: profile, api: api),
  ),
  _Category(
    icon: Icons.tune_rounded,
    title: 'App settings',
    subtitle: (context, _, store) => store.allNotificationsOff
        ? 'Theme and more — notifications are off'
        : 'Theme, notifications, privacy, storage',
    build: (context, _, _) => const AppSettingsScreen(),
  ),
  _Category(
    icon: Icons.call_outlined,
    title: 'Calls history',
    subtitle: (context, _, _) => 'Voice and video call log',
    build: (context, _, _) => const CallHistoryScreen(),
  ),
  _Category(
    icon: Icons.import_export_rounded,
    title: 'Export / Import chats',
    subtitle: (context, _, _) => 'Back up and restore conversations',
    build: (context, _, _) => const BackupScreen(),
  ),
  _Category(
    icon: Icons.block_outlined,
    title: 'Block list',
    subtitle: (context, _, _) => 'Manage blocked accounts',
    build: (context, profile, api) => profile == null
        ? const _SignedOutNotice()
        : BlockListScreen(api: api),
  ),
  _Category(
    icon: Icons.laptop_chromebook_outlined,
    title: 'Web connect',
    subtitle: (context, _, _) => 'Link this phone to a computer',
    build: (context, _, _) => const WebConnectScreen(),
  ),
];

class _AccountSummary extends StatelessWidget {
  const _AccountSummary({required this.profile, required this.onTap});

  final UserProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final initials = profile.fullName.trim().isEmpty
        ? '?'
        : profile.fullName
              .split(RegExp(r'\s+'))
              .where((part) => part.isNotEmpty)
              .take(2)
              .map((part) => part[0].toUpperCase())
              .join();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: Text(
                  initials,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.fullName.isEmpty
                          ? 'Your account'
                          : profile.fullName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (profile.hasUsername) '@${profile.username}',
                        if (profile.identifierLabel != null)
                          profile.identifierLabel!,
                      ].join('  ·  '),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignedOutNotice extends StatelessWidget {
  const _SignedOutNotice();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account settings')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              const Text(
                'Sign in to manage your account',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                'Your profile and settings need a signed-in session.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}