import 'dart:math';

import 'package:flutter/material.dart';

import '../widgets/settings_tile.dart';

/// Link this phone to a browser or desktop, in the style of WhatsApp Web.
///
/// Parked deliberately. Pairing needs a long-lived token the backend issues,
/// and that endpoint does not exist, so this screen explains the shape instead
/// of pretending to work.
class WebConnectScreen extends StatelessWidget {
  const WebConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Web connect',
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Icon(
                  Icons.laptop_chromebook_outlined,
                  size: 44,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  'Not available yet',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Linking a browser or desktop to this account is planned but '
                  'not built. When it works you will scan a code here and your '
                  'chats will follow you to the computer.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        SettingsSection(
          title: 'Planned options',
          subtitle: 'Shown so the wording can be agreed on.',
          children: [
            SettingsTile(
              icon: Icons.qr_code_2_rounded,
              title: 'Link a device',
              subtitle: 'Scan a code from the browser',
              onTap: () => _soon(context),
            ),
            SettingsTile(
              icon: Icons.devices_outlined,
              title: 'Linked devices',
              subtitle: 'See and disconnect computers',
              onTap: () => _soon(context),
            ),
            SettingsTile(
              icon: Icons.notifications_none_rounded,
              title: 'Message notifications',
              subtitle: 'Whether the computer shows previews',
              onTap: () => _soon(context),
            ),
          ],
        ),
      ],
    );
  }

  static void _soon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Web connect is not built yet.')),
    );
  }
}

/// Placeholder pairing code generator.
///
/// Not used by the current screen. It exists so the pairing UI can be
/// prototyped before the backend issues real codes, and is deterministic for a
/// given session so a re-render does not shuffle the digits.
class MockPairingCode {
  MockPairingCode._();

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// 8 groups of 4, which is the shape WhatsApp uses. Skips I, O, 0 and 1 so
  /// the code is unambiguous when read aloud or retyped.
  static String generate({int? seed}) {
    final random = seed == null ? Random() : Random(seed);
    final groups = List.generate(
      8,
      (_) => List.generate(4, (_) => _alphabet[random.nextInt(_alphabet.length)]).join(),
    );
    return groups.join('-');
  }
}