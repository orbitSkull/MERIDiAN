import 'package:flutter/material.dart';

import '../auth/login_screen.dart';

/// Settings tab — static options list, UI-only.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _soon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('UI preview — nothing here yet.')),
    );
  }

  void _logout(BuildContext context) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        Icons.person_outline_rounded,
        'Account settings',
        'Profile, PRN, college ID',
      ),
      (
        Icons.tune_rounded,
        'App Settings',
        'Theme, notifications, language',
      ),
      (
        Icons.call_outlined,
        'Calls History',
        'Voice and video call log',
      ),
      (
        Icons.import_export_rounded,
        'Export / Import chats',
        'Backup and restore conversations',
      ),
      (
        Icons.block_outlined,
        'Block list',
        'Manage blocked users',
      ),
      (
        Icons.laptop_chromebook_outlined,
        'WebConnect',
        'Link app to computer for web access',
      ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        for (final item in items)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(item.$1),
              title: Text(item.$2,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(item.$3),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _soon(context),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.logout_rounded, color: Colors.red),
            title: const Text('Log out',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: Colors.red)),
            onTap: () => _logout(context),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }
}
