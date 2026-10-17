import 'package:flutter/material.dart';

import '../../../models/user.dart';
import '../../../services/meridian_api.dart';
import '../../../services/usage_username_availability.dart';
import '../widgets/settings_tile.dart';
import 'email_screen.dart';
import 'password_screen.dart';
import 'profile_editor_screen.dart';
import 'sessions_screen.dart';
import 'username_screen.dart';

/// Account settings.
///
/// Every row here that can be changed opens a screen that really changes it.
/// The rows that cannot -- college, role, identifier -- are shown without a
/// chevron, because a row that looks tappable and opens a dead end is worse
/// than one that plainly is not.
class AccountSettingsScreen extends StatelessWidget {
  const AccountSettingsScreen({
    super.key,
    required this.profile,
    this.api,
    this.usernameAvailability,
    this.onProfileChanged,
    this.onSignOutRequired,
  });

  final UserProfile profile;

  /// Null only in tests that do not exercise the editable rows.
  final MeridianApi? api;

  final UsernameAvailability? usernameAvailability;

  /// Called with the fresh profile after an edit, so the caller can update the
  /// cached one. Without it the screen would show the new value and the rest of
  /// the app would still show the old one.
  final ValueChanged<UserProfile>? onProfileChanged;

  /// Called after a password change, because the server has ended every session
  /// and the app has to send the person back to the login screen.
  final VoidCallback? onSignOutRequired;

  /// Opens a screen and hands back whatever it returns.
  ///
  /// The edit screens pop with the updated profile rather than writing to a
  /// shared store themselves, so there is one place where a successful edit
  /// becomes visible.
  Future<void> _pushEdit(
    BuildContext context,
    Widget Function(MeridianApi api, UserProfile profile) builder,
  ) async {
    final api = this.api;
    if (api == null) return;
    final updated = await Navigator.of(context).push<UserProfile>(
      MaterialPageRoute<UserProfile>(
        builder: (_) => builder(api, profile),
      ),
    );
    if (updated != null) onProfileChanged?.call(updated);
  }

  @override
  Widget build(BuildContext context) {
    // A local rather than this.api, so it can be promoted to non-null inside the
    // closures below. A field is not promoted, so every one of them would
    // otherwise need its own null check.
    final api = this.api;

    return SettingsScaffold(
      title: 'Account settings',
      children: [
        _ProfileCard(profile: profile),
        const SizedBox(height: 20),
        SettingsSection(
          title: 'Profile',
          children: [
            SettingsTile(
              icon: Icons.face_outlined,
              title: 'Profile',
              subtitle: profile.displayName == null
                  ? 'Photo, display name, bio'
                  : 'Display name, bio and photo',
              onTap: () => _pushEdit(
                context,
                (api, current) =>
                    ProfileEditorScreen(api: api, profile: current),
              ),
            ),
            SettingsTile(
              icon: Icons.alternate_email_rounded,
              title: 'Username',
              subtitle: profile.hasUsername
                  ? '@${profile.username}'
                  : 'Not set yet',
              onTap: api == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => UsernameScreen(
                          profile: profile,
                          availability: usernameAvailability,
                          api: api,
                          onUsernameChanged: (username) => onProfileChanged
                              ?.call(profile.copyWith(username: username)),
                        ),
                      ),
                    ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Academic',
          footer:
              'Your college, role and ID are verified during registration and '
              'cannot be changed here.',
          children: [
            SettingsTile(
              icon: Icons.badge_outlined,
              title: profile.isFaculty ? 'Employee ID' : 'Academic ID',
              value: profile.identifierLabel ?? 'Not set',
              trailing: profile.identifierLabel == null
                  ? null
                  : const _VerifiedChip(),
            ),
            SettingsTile(
              icon: Icons.account_balance_outlined,
              title: 'College',
              value: profile.collegeCode ?? 'Not set',
            ),
            SettingsTile(
              icon: Icons.workspace_premium_outlined,
              title: 'Role',
              value: _roleLabel(profile.role),
            ),
          ],
        ),
        SettingsSection(
          title: 'Email',
          children: [
            SettingsTile(
              icon: Icons.mail_outline_rounded,
              title: 'Email address',
              value: profile.email ?? 'Not set',
              subtitle: profile.email == null
                  ? 'Add one to secure your account'
                  : null,
              trailing: profile.email == null
                  ? const Icon(Icons.chevron_right_rounded, size: 20)
                  : profile.emailVerified
                  ? const _VerifiedChip()
                  : const _UnverifiedChip(),
              onTap: () => _pushEdit(
                context,
                (api, current) => EmailScreen(api: api, profile: current),
              ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Security',
          children: [
            SettingsTile(
              icon: Icons.lock_outline_rounded,
              title: 'Change password',
              onTap: api == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<bool>(
                        builder: (_) => PasswordScreen(
                          api: api,
                          onPasswordChanged: () => onSignOutRequired?.call(),
                        ),
                      ),
                    ),
            ),
            SettingsTile(
              icon: Icons.devices_outlined,
              title: 'Active sessions',
              subtitle: 'Devices currently signed in',
              onTap: api == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SessionsScreen(api: api),
                      ),
                    ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Account',
          footer:
              'Deleting your account removes your messages and cannot be undone.',
          children: [
            // Both still need a backend endpoint and a confirmation flow that
            // cannot be undone by a mis-tap, so they are labelled rather than
            // half-built.
            ComingSoonTile(
              icon: Icons.person_off_outlined,
              title: 'Deactivate account',
              subtitle: 'Hide your profile and stop notifications',
            ),
            const ComingSoonTile(
              icon: Icons.delete_outline_rounded,
              title: 'Delete account',
              subtitle: 'Remove your account and its data',
            ),
          ],
        ),
      ],
    );
  }

  static String _roleLabel(String role) => switch (role) {
    'student' => 'Student',
    'faculty' => 'Faculty',
    'moderator' => 'Moderator',
    _ => role,
  };
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile});

  final UserProfile profile;

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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text(
                initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.fullName.isEmpty ? 'Not set' : profile.fullName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
const SizedBox(height: 2),
                    Builder(
                      builder: (context) {
                        final identifier = profile.identifierLabel;
                        final handle = profile.hasUsername
                            ? '@${profile.username}'
                            : null;
                        final summary = [
                          ?identifier,
                          ?handle,
                        ].join('  ·  ');

                        return Text(
                          summary.isEmpty ? 'No handle set yet' : summary,
                          style: TextStyle(
                            fontSize: 13,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        );
                      },
                    ),
                  ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VerifiedChip extends StatelessWidget {
  const _VerifiedChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_rounded, size: 14, color: Colors.green),
          SizedBox(width: 4),
          Text(
            'Verified',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.green,
            ),
          ),
        ],
      ),
    );
  }
}

class _UnverifiedChip extends StatelessWidget {
  const _UnverifiedChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Verify',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}