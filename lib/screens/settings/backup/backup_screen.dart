import 'package:flutter/material.dart';

import '../widgets/settings_tile.dart';

/// Export, import and backup.
///
/// Every action here is a stub. This screen exists so the options and their
/// wording can be agreed before any file format or storage location is
/// chosen, since both are expensive to change once users have backups.
class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Export / Import',
      children: [
        SettingsSection(
          title: 'Export',
          children: [
            SettingsTile(
              icon: Icons.ios_share_rounded,
              title: 'Export chats',
              subtitle: 'JSON, HTML, PDF or plain text',
              onTap: () => _push(context, const ExportScreen()),
            ),
          ],
        ),
        SettingsSection(
          title: 'Import',
          footer:
              'Importing merges into your existing history. It never deletes '
              'anything you already have.',
          children: [
            SettingsTile(
              icon: Icons.file_download_outlined,
              title: 'Import chats',
              subtitle: 'From a file you choose',
              onTap: () => _push(context, const ImportScreen()),
            ),
          ],
        ),
        SettingsSection(
          title: 'Automatic backup',
          footer:
              'Backups are encrypted with a passphrase you choose. It cannot '
              'be recovered, so keep it somewhere safe.',
          children: [
            const SettingsSwitchTile(
              icon: Icons.cloud_upload_outlined,
              title: 'Back up automatically',
              subtitle: 'Not available yet',
              value: false,
              enabled: false,
              onChanged: null,
            ),
            SettingsTile(
              icon: Icons.schedule_rounded,
              title: 'Backup schedule',
              value: 'Weekly',
              onTap: () => _soon(context),
            ),
            SettingsTile(
              icon: Icons.history_rounded,
              title: 'Last backup',
              value: 'Never',
              onTap: () => _soon(context),
            ),
          ],
        ),
        SettingsSection(
          title: 'Storage',
          children: [
            SettingsTile(
              icon: Icons.pie_chart_outline_rounded,
              title: 'Backup size',
              value: '0 MB',
              onTap: () => _soon(context),
            ),
          ],
        ),
      ],
    );
  }

  static void _soon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Not built yet.')),
    );
  }
}

enum ExportFormat {
  json('JSON', 'Everything, machine readable. Best for re-importing.'),
  html('HTML', 'Readable in a browser, with formatting.'),
  pdf('PDF', 'Fixed layout, best for printing or sharing.'),
  text('Plain text', 'Simplest, no formatting.');

  const ExportFormat(this.label, this.description);

  final String label;
  final String description;
}

enum ExportScope {
  all('All chats'),
  selected('Selected chats'),
  dateRange('A date range');

  const ExportScope(this.label);

  final String label;
}

class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  ExportFormat _format = ExportFormat.json;
  ExportScope _scope = ExportScope.all;
  bool _includeMedia = true;

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Export chats',
      children: [
        SettingsSection(
          title: 'What to export',
          children: [
            SettingsControlTile(
              icon: Icons.forum_outlined,
              title: 'Scope',
              child: Wrap(
                spacing: 8,
                children: [
                  for (final scope in ExportScope.values)
                    ChoiceChip(
                      label: Text(scope.label),
                      selected: _scope == scope,
                      onSelected: (_) => setState(() => _scope = scope),
                    ),
                ],
              ),
            ),
          ],
        ),
        // ChoiceChip rather than RadioListTile: the groupValue/onChanged pair
        // on RadioListTile is deprecated after 3.32, and a radio inside a card
        // already styled by SettingsSection reads as heavier than needed for
        // a four-way pick.
        SettingsSection(
          title: 'Format',
          subtitle: _format.description,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final format in ExportFormat.values)
                    ChoiceChip(
                      label: Text(format.label),
                      selected: _format == format,
                      onSelected: (_) => setState(() => _format = format),
                    ),
                ],
              ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Options',
          children: [
            SettingsSwitchTile(
              icon: Icons.perm_media_outlined,
              title: 'Include photos and files',
              subtitle: 'Makes the export much larger',
              value: _includeMedia,
              onChanged: (value) => setState(() => _includeMedia = value),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: FilledButton.icon(
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Export is not built yet.')),
            ),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Start export'),
          ),
        ),
      ],
    );
  }
}

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _merge = true;

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Import chats',
      children: [
        SettingsSection(
          title: 'Source',
          children: [
            SettingsTile(
              icon: Icons.folder_open_rounded,
              title: 'Choose a file',
              subtitle: 'A .json export from MERIDiAN',
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('File picking is not built yet.')),
              ),
            ),
          ],
        ),
        SettingsSection(
          title: 'How to handle existing chats',
          children: [
            SettingsSwitchTile(
              icon: Icons.merge_rounded,
              title: 'Merge with existing history',
              subtitle: _merge
                  ? 'Duplicate messages are skipped'
                  : 'Existing chats are kept, imports are appended',
              value: _merge,
              onChanged: (value) => setState(() => _merge = value),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: FilledButton.icon(
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Import is not built yet.')),
            ),
            icon: const Icon(Icons.file_upload_rounded),
            label: const Text('Start import'),
          ),
        ),
      ],
    );
  }
}