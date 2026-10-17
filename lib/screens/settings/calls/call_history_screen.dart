import 'package:flutter/material.dart';

import '../../../models/call_log.dart';
import '../widgets/settings_tile.dart';

/// Call history hub and log in one screen.
///
/// Filters are a segmented control rather than a separate screen because they
/// are cheap and switching them should not cost a navigation.
class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key, this.entries});

  /// Seed data so the layout can be reviewed. Replaced by the server list
  /// when the call endpoints exist.
  final List<CallLogEntry>? entries;

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  CallFilter _filter = CallFilter.all;

  List<CallLogEntry> get _all => widget.entries ?? demoCallLog;

  List<CallLogEntry> get _visible =>
      _all.where(_filter.matches).toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final entries = _visible;

    return SettingsScaffold(
      title: 'Calls',
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SegmentedButton<CallFilter>(
            segments: const [
              ButtonSegment(value: CallFilter.all, label: Text('All')),
              ButtonSegment(value: CallFilter.missed, label: Text('Missed')),
              ButtonSegment(value: CallFilter.incoming, label: Text('In')),
              ButtonSegment(value: CallFilter.outgoing, label: Text('Out')),
            ],
            selected: {_filter},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                setState(() => _filter = selection.first),
          ),
        ),
        SettingsSection(
          title: 'History',
          children: entries.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.call_outlined,
                          size: 40,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'No calls yet',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Calls you make and receive will appear here.',
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
              : [for (final entry in entries) _CallTile(entry: entry)],
        ),
        SettingsSection(
          title: 'Settings',
          children: [
            SettingsTile(
              icon: Icons.notifications_active_outlined,
              title: 'Call alerts',
              subtitle: 'Ringtone and vibration',
              onTap: () => _soon(context, 'Call alerts'),
            ),
            SettingsTile(
              icon: Icons.delete_sweep_outlined,
              title: 'Clear call history',
              subtitle: 'Removes every entry on this device',
              destructive: true,
              onTap: () => _confirmClear(context),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear call history?'),
        content: const Text('This removes every call entry on this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Not wired up yet.')),
    );
  }

  static void _soon(BuildContext context, String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what is not built yet.')),
    );
  }
}

class _CallTile extends StatelessWidget {
  const _CallTile({required this.entry});

  final CallLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, iconColor) = switch (entry) {
      CallLogEntry(missed: true) => (Icons.call_made_rounded, scheme.error),
      CallLogEntry(direction: CallDirection.incoming) => (
        Icons.call_received_rounded,
        Colors.green,
      ),
      _ => (Icons.call_made_rounded, scheme.onSurfaceVariant),
    };

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: iconColor.withValues(alpha: 0.12),
        child: Icon(icon, color: iconColor, size: 20),
      ),
      title: Text(
        entry.peerName,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: entry.missed ? scheme.error : null,
        ),
      ),
      subtitle: Text('${entry.whenLabel}  ·  ${entry.kind.label}'),
      trailing: Text(
        entry.durationLabel ?? '',
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSurfaceVariant,
        ),
      ),
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Call actions for ${entry.peerName} are not built.')),
      ),
    );
  }
}