import 'package:flutter/material.dart';

/// New chat screen — UI-only.
/// Search by username + two options: Create New Group, Scan QR.
class NewChatScreen extends StatelessWidget {
  const NewChatScreen({super.key});

  void _soon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('UI preview — nothing here yet.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'New Chat',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Column(
        children: [
          // Search field at top.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search by username…',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 13),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(99),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(99),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(99),
                  borderSide: BorderSide(color: scheme.primary, width: 1.5),
                ),
              ),
            ),
          ),
          // Two options below.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        scheme.primary.withValues(alpha: 0.12),
                    child: Icon(Icons.group_add_outlined,
                        color: scheme.primary),
                  ),
                  title: const Text('Create New Group',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Group with friends or class'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _soon(context),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        scheme.primary.withValues(alpha: 0.12),
                    child: Icon(Icons.qr_code_scanner_rounded,
                        color: scheme.primary),
                  ),
                  title: const Text('Scan QR',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Add a friend via QR code'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _soon(context),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ],
            ),
          ),
          const Divider(height: 24),
          // Empty search-results placeholder (UI-only).
          Expanded(
            child: Center(
              child: Text(
                'Search results will appear here.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Theme.of(context).hintColor),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
