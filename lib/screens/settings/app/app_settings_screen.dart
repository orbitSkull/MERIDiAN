import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/settings_store.dart';
import '../../../theme/app_theme.dart';
import '../widgets/settings_tile.dart';

/// App settings hub.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();

    return SettingsScaffold(
      title: 'App settings',
      children: [
        SettingsSection(
          title: 'Preferences',
          children: [
            SettingsTile(
              icon: Icons.palette_outlined,
              title: 'Appearance',
              subtitle: 'Theme, text size',
              onTap: () => _push(context, const AppearanceScreen()),
            ),
            SettingsTile(
              icon: Icons.notifications_outlined,
              title: 'Notifications',
              subtitle: store.allNotificationsOff
                  ? 'All notifications are off'
                  : 'Push, email, in-app',
              onTap: () => _push(context, const NotificationsScreen()),
            ),
            SettingsTile(
              icon: Icons.visibility_outlined,
              title: 'Privacy',
              subtitle: 'Read receipts, typing, last seen',
              onTap: () => _push(context, const PrivacyScreen()),
            ),
          ],
        ),
        SettingsSection(
          title: 'Data',
          children: [
            SettingsTile(
              icon: Icons.sd_storage_outlined,
              title: 'Storage',
              subtitle: 'Cache, downloads',
              onTap: () => _push(context, const StorageScreen()),
            ),
            SettingsTile(
              icon: Icons.translate_rounded,
              title: 'Language',
              subtitle: 'English (India)',
              onTap: () => _push(context, const LanguageScreen()),
            ),
          ],
        ),
        SettingsSection(
          title: 'Advanced',
          footer: 'Diagnostics for developers. Nothing here changes your data.',
          children: [
            SettingsTile(
              icon: Icons.dns_outlined,
              title: 'Connection',
              subtitle: 'Which server this build talks to',
              onTap: () => _push(context, const AdvancedScreen()),
            ),
          ],
        ),
      ],
    );
  }
}

class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();

    return SettingsScaffold(
      title: 'Appearance',
      children: [
        SettingsSection(
          title: 'Theme',
          subtitle: 'System follows your phone setting.',
          children: [
            SettingsControlTile(
              icon: Icons.brightness_6_outlined,
              title: 'Colour scheme',
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'light', label: Text('Light')),
                  ButtonSegment(value: 'dark', label: Text('Dark')),
                  ButtonSegment(value: 'system', label: Text('System')),
                ],
                selected: {store.themeModeName},
                onSelectionChanged: (selection) async {
                  final mode = selection.first;
                  await store.setThemeModeName(mode);
                  await AppThemeMode.set(_decode(mode));
                },
              ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Text size',
          subtitle: 'Applies to the app interface, not to other people\'s messages.',
          footer:
              'Your own message text stays at a fixed size so it looks the same '
              'to everyone else.',
          children: [
            SettingsControlTile(
              icon: Icons.format_size_rounded,
              title: 'Interface scale',
              subtitle: '${(store.fontScale * 100).round()}%',
              child: Slider(
                value: store.fontScale,
                min: 0.85,
                max: 1.3,
                divisions: 9,
                label: '${(store.fontScale * 100).round()}%',
                onChanged: store.setFontScale,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static ThemeMode _decode(String name) => switch (name) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final channelsOn =
        store.pushEnabled || store.emailEnabled || store.inAppEnabled;

    return SettingsScaffold(
      title: 'Notifications',
      children: [
        if (!channelsOn)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _Warning(
              'Every channel is off. You will not be told about messages.',
            ),
          ),
        SettingsSection(
          title: 'Channels',
          footer: 'Turning off a channel here also stops that alert on your phone.',
          children: [
            SettingsSwitchTile(
              icon: Icons.notifications_active_outlined,
              title: 'Push notifications',
              subtitle: 'Delivered by your phone',
              value: store.pushEnabled,
              onChanged: store.setPushEnabled,
            ),
            SettingsSwitchTile(
              icon: Icons.mail_outline_rounded,
              title: 'Email',
              subtitle: 'Only for account and security messages',
              value: store.emailEnabled,
              onChanged: store.setEmailEnabled,
            ),
            SettingsSwitchTile(
              icon: Icons.inbox_outlined,
              title: 'In-app',
              subtitle: 'Badge counters while the app is open',
              value: store.inAppEnabled,
              onChanged: store.setInAppEnabled,
            ),
          ],
        ),
        SettingsSection(
          title: 'What you get told about',
          // Disabled rather than hidden when no channel is on, so the shape of
          // the screen does not change as you toggle.
          children: [
            SettingsSwitchTile(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'New messages',
              value: store.notifyMessages,
              enabled: channelsOn,
              onChanged: store.setNotifyMessages,
            ),
            SettingsSwitchTile(
              icon: Icons.alternate_email_rounded,
              title: 'Mentions',
              subtitle: 'When someone uses @yourname',
              value: store.notifyMentions,
              enabled: channelsOn,
              onChanged: store.setNotifyMentions,
            ),
            SettingsSwitchTile(
              icon: Icons.call_outlined,
              title: 'Calls',
              subtitle: 'Incoming voice and video',
              value: store.notifyCalls,
              enabled: channelsOn,
              onChanged: store.setNotifyCalls,
            ),
          ],
        ),
      ],
    );
  }
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();

    return SettingsScaffold(
      title: 'Privacy',
      children: [
        SettingsSection(
          title: 'What others can see',
          footer:
              'Turning these off hides the information from people you chat '
              'with. Blocked users never receive it regardless.',
          children: [
            SettingsSwitchTile(
              icon: Icons.done_all_rounded,
              title: 'Read receipts',
              subtitle: 'Show others when you have read a message',
              value: store.readReceipts,
              onChanged: store.setReadReceipts,
            ),
            SettingsSwitchTile(
              icon: Icons.more_horiz_rounded,
              title: 'Typing indicator',
              subtitle: 'Show "typing..." while you compose',
              value: store.typingIndicator,
              onChanged: store.setTypingIndicator,
            ),
            SettingsSwitchTile(
              icon: Icons.schedule_rounded,
              title: 'Last seen',
              subtitle: 'Show when you were last online',
              value: store.lastSeen,
              onChanged: store.setLastSeen,
            ),
          ],
        ),
      ],
    );
  }
}

class StorageScreen extends StatelessWidget {
  const StorageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();

    return SettingsScaffold(
      title: 'Storage',
      children: [
        SettingsSection(
          title: 'Downloads',
          children: [
            SettingsSwitchTile(
              icon: Icons.download_for_offline_outlined,
              title: 'Auto-download media',
              subtitle: 'Photos and files over Wi-Fi only',
              value: store.autoDownloadMedia,
              onChanged: store.setAutoDownloadMedia,
            ),
          ],
        ),
        SettingsSection(
          title: 'Space',
          children: [
            SettingsTile(
              icon: Icons.cleaning_services_outlined,
              title: 'Clear cache',
              subtitle: 'Photos and files only. Messages are not affected.',
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Nothing to clear yet.')),
              ),
            ),
            SettingsTile(
              icon: Icons.pie_chart_outline_rounded,
              title: 'Manage storage',
              subtitle: 'See what is using space',
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Not built yet.')),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Language',
      children: [
        SettingsSection(
          title: 'App language',
          subtitle: 'The language of menus and labels, not of messages.',
          children: [
            SettingsTile(
              icon: Icons.translate_rounded,
              title: 'English (India)',
              trailing: Icon(
                Icons.check_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              onTap: () {},
            ),
            const ComingSoonTile(
              icon: Icons.translate_rounded,
              title: 'Hindi, Malayalam, Tamil',
              subtitle: 'More languages are on the way',
            ),
          ],
        ),
        SettingsSection(
          title: 'Region',
          children: [
            SettingsTile(
              icon: Icons.public_rounded,
              title: 'Time zone',
              value: 'Asia/Kolkata',
              onTap: () {},
            ),
          ],
        ),
      ],
    );
  }
}

class AdvancedScreen extends StatelessWidget {
  const AdvancedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Advanced',
      children: [
        SettingsSection(
          title: 'Connection',
          subtitle: 'Which backend this build talks to.',
          footer:
              'Set at build time with --dart-define=API_BASE_URL=... A wrong '
              'value here is the most common reason the app cannot sign in.',
          children: [
            SettingsTile(
              icon: Icons.dns_outlined,
              title: 'API server',
              value: ApiConfigSummary.value,
              onTap: () {},
            ),
          ],
        ),
        SettingsSection(
          title: 'Reset',
          children: [
            SettingsTile(
              icon: Icons.settings_backup_restore_rounded,
              title: 'Reset app settings',
              subtitle: 'Puts every switch on this page back to its default',
              onTap: () async {
                await context.read<SettingsStore>().reset();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Settings reset.')),
                  );
                }
              },
            ),
            SettingsTile(
              icon: Icons.logout_rounded,
              title: 'Clear local data',
              subtitle: 'Signs you out and deletes cached messages',
              destructive: true,
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Not built yet.')),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Reads the configured server without importing the service layer into a
/// settings screen. Kept separate so the value has one definition.
class ApiConfigSummary {
  const ApiConfigSummary._();

  static String get value {
    const override = String.fromEnvironment('API_BASE_URL');
    return override.isNotEmpty ? override : 'Default for this platform';
  }
}

class _Warning extends StatelessWidget {
  const _Warning(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}