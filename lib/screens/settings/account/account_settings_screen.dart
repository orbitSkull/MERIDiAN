import 'package:flutter/material.dart';

import '../../../models/user.dart';
import '../widgets/settings_tile.dart';
import 'username_screen.dart';

/// Account settings.
///
/// The only sub-screen with real behaviour so far is the username editor.
/// The rest are laid out with the rows they will contain so the information
/// architecture can be reviewed before the forms are built.
class AccountSettingsScreen extends StatelessWidget {
  const AccountSettingsScreen({
    super.key,
    required this.profile,
    this.usernameAvailability,
  });

  final UserProfile profile;
  final UsernameAvailability? usernameAvailability;

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
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
              subtitle: 'Photo, display name, bio',
              onTap: () => _preview(context, 'Profile'),
            ),
            SettingsTile(
              icon: Icons.alternate_email_rounded,
              title: 'Username',
              subtitle: profile.hasUsername
                  ? '@${profile.username}'
                  : 'Not set yet',
              onTap: () => _push(
                context,
                UsernameScreen(
                  profile: profile,
                  availability: usernameAvailability,
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
              title: 'Academic ID',
              value: profile.identifierLabel ?? 'Not set',
              trailing: profile.identifierLabel == null
                  ? const Icon(Icons.chevron_right_rounded, size: 20)
                  : const _VerifiedChip(),
              onTap: () => _preview(context, 'Academic ID'),
            ),
            SettingsTile(
              icon: Icons.account_balance_outlined,
              title: 'College',
              value: profile.collegeCode ?? 'Not set',
              onTap: () => _preview(context, 'College'),
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
              subtitle: profile.email == null ? 'Add one to secure your account' : null,
              trailing: profile.email == null
                  ? const Icon(Icons.chevron_right_rounded, size: 20)
                  : const _UnverifiedChip(),
              onTap: () => _preview(context, 'Email'),
            ),
          ],
        ),
        SettingsSection(
          title: 'Security',
          children: [
            SettingsTile(
              icon: Icons.lock_outline_rounded,
              title: 'Change password',
              onTap: () => _preview(context, 'Change password'),
            ),
            SettingsTile(
              icon: Icons.devices_outlined,
              title: 'Active sessions',
              subtitle: 'Devices currently signed in',
              onTap: () => _preview(context, 'Active sessions'),
            ),
          ],
        ),
        SettingsSection(
          title: 'Account',
          footer:
              'Deleting your account removes your messages and cannot be undone.',
          children: [
            SettingsTile(
              icon: Icons.person_off_outlined,
              title: 'Deactivate account',
              subtitle: 'Hide your profile and stop notifications',
              onTap: () => _preview(context, 'Deactivate'),
            ),
            SettingsTile(
              icon: Icons.delete_outline_rounded,
              title: 'Delete account',
              destructive: true,
              onTap: () => _preview(context, 'Delete'),
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

  static void _preview(BuildContext context, String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what is not built yet.')),
    );
  }
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