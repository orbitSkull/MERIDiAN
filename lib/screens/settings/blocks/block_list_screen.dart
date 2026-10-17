import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/settings_store.dart';
import '../widgets/settings_tile.dart';

/// A blocked account.
///
/// UI-only. Blocked state is a server concern: it must apply on every device,
/// not just this one, or unblocking on your phone would not unblock someone on
/// your laptop.
class BlockedUser {
  const BlockedUser({
    required this.handle,
    required this.displayName,
    required this.blockedAt,
    this.reason,
  });

  final String handle;
  final String displayName;
  final DateTime blockedAt;

  /// Free text the blocker entered, if any.
  final String? reason;
}

final demoBlockedUsers = <BlockedUser>[
  BlockedUser(
    handle: 'spam.bot',
    displayName: 'Unknown',
    blockedAt: DateTime.now().subtract(const Duration(days: 12)),
    reason: 'Spam',
  ),
  BlockedUser(
    handle: 'k.rao',
    displayName: 'Karthik Rao',
    blockedAt: DateTime.now().subtract(const Duration(days: 4)),
  ),
];

class BlockListScreen extends StatefulWidget {
  const BlockListScreen({super.key, this.blocked});

  final List<BlockedUser>? blocked;

  @override
  State<BlockListScreen> createState() => _BlockListScreenState();
}

class _BlockListScreenState extends State<BlockListScreen> {
  late final List<BlockedUser> _blocked = [
    ...(widget.blocked ?? demoBlockedUsers),
  ];

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Block list',
      children: [
        SettingsSection(
          title: 'Blocked (${_blocked.length})',
          subtitle: 'Blocked people cannot message or call you.',
          footer:
              'Blocking is applied on your account, so it takes effect on every '
              'device you are signed in to.',
          children: _blocked.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.block_outlined,
                          size: 40,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Nobody is blocked',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'You can block someone from their profile.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ]
              : [
                  for (final user in _blocked)
                    _BlockedTile(
                      user: user,
                      onUnblock: () => setState(
                        () => _blocked.removeWhere((u) => u.handle == user.handle),
                      ),
                    ),
                ],
        ),
        const SettingsSection(
          title: 'Blocked by others',
          subtitle:
              'People who have blocked you cannot be shown here. You will only '
              'notice when a message fails to send.',
          children: [
            ComingSoonTile(
              icon: Icons.block_outlined,
              title: 'Not available yet',
              subtitle: 'Requires a server endpoint to query',
            ),
          ],
        ),
        const SettingsSection(
          title: 'Preferences',
          children: [
            _BlockPreferences(),
          ],
        ),
      ],
    );
  }
}

class _BlockedTile extends StatelessWidget {
  const _BlockedTile({required this.user, required this.onUnblock});

  final BlockedUser user;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text(
          user.displayName.isEmpty
              ? '?'
              : user.displayName[0].toUpperCase(),
        ),
      ),
      title: Text(user.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        [
          '@${user.handle}',
          if (user.reason != null) user.reason!,
        ].join('  ·  '),
      ),
      trailing: TextButton(
        onPressed: () {
          onUnblock();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Unblocked @${user.handle} (not saved).')),
          );
        },
        child: const Text('Unblock'),
      ),
    );
  }
}

class _BlockPreferences extends StatelessWidget {
  const _BlockPreferences();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();

    return Column(
      children: [
        SettingsSwitchTile(
          icon: Icons.block_outlined,
          title: 'Block unknown callers',
          subtitle: 'Numbers and usernames not in your contacts',
          value: store.blockUnknownCallers,
          onChanged: store.setBlockUnknownCallers,
        ),
        SettingsSwitchTile(
          icon: Icons.visibility_off_outlined,
          title: 'Hide read receipts from blocked',
          subtitle: 'Do not tell them when you read a message',
          value: store.hideReadReceiptsFromBlocked,
          onChanged: store.setHideReadReceiptsFromBlocked,
        ),
      ],
    );
  }
}