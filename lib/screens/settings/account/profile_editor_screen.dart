import 'package:flutter/material.dart';

import '../../../models/user.dart';
import '../../../services/api_client.dart';
import '../../../services/meridian_api.dart';
import '../widgets/settings_tile.dart';

/// Edit the parts of a profile a person owns.
///
/// Display name, bio and avatar URL are writable; the legal name, PRN, college
/// and role are not, and they are not on this form. An editable-looking field
/// that silently rejects on save is worse than an absent one.
///
/// The avatar is a URL rather than an image picker on purpose: there is no
/// upload endpoint, and pretending otherwise would mean storing a local path in
/// a field the server hands to other devices, where the path means nothing.
class ProfileEditorScreen extends StatefulWidget {
  const ProfileEditorScreen({
    super.key,
    required this.api,
    required this.profile,
  });

  final MeridianApi api;
  final UserProfile profile;

  @override
  State<ProfileEditorScreen> createState() => _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends State<ProfileEditorScreen> {
  late final TextEditingController _displayName;
  late final TextEditingController _bio;
  late final TextEditingController _avatarUrl;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _displayName = TextEditingController(
      text: widget.profile.displayName ?? '',
    );
    _bio = TextEditingController(text: widget.profile.bio ?? '');
    _avatarUrl = TextEditingController(text: widget.profile.avatarUrl ?? '');
  }

  @override
  void dispose() {
    _displayName.dispose();
    _bio.dispose();
    _avatarUrl.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _displayName.text != (widget.profile.displayName ?? '') ||
      _bio.text != (widget.profile.bio ?? '') ||
      _avatarUrl.text != (widget.profile.avatarUrl ?? '');

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Sent as the raw text, including an emptied field. The API treats an empty
      // string as "clear this", which is what a person deleting their bio means.
      final updated = await widget.api.updateProfile(
        displayName: _displayName.text,
        bio: _bio.text,
        avatarUrl: _avatarUrl.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(updated);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Profile',
      children: [
        SettingsSection(
          title: 'How others see you',
          subtitle: 'Your name and identifier are verified at registration.',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ReadOnlyRow(
                    label: 'Legal name',
                    value: widget.profile.fullName,
                  ),
                  _ReadOnlyRow(
                    label: 'Handle',
                    value: widget.profile.hasUsername
                        ? '@${widget.profile.username}'
                        : 'Not set',
                  ),
                  _ReadOnlyRow(
                    label: widget.profile.isFaculty ? 'Employee ID' : 'PRN',
                    value: widget.profile.identifierLabel ?? 'Not set',
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Edit',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _displayName,
                    onChanged: (_) => setState(() {}),
                    textCapitalization: TextCapitalization.words,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                      helperText: 'Optional. Falls back to your legal name.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _bio,
                    onChanged: (_) => setState(() {}),
                    maxLines: 4,
                    maxLength: 280,
                    decoration: const InputDecoration(
                      labelText: 'Bio',
                      helperText: 'A line about you, up to 280 characters.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _avatarUrl,
                    onChanged: (_) => setState(() {}),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Avatar URL',
                      helperText:
                          'Link to an image. There is no upload yet, so this '
                          'has to be a URL that works on any device.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton(
                // Disabled until something actually changed, so an accidental
                // tap cannot rewrite the profile with what is already there.
                onPressed: _saving || !_dirty ? null : _save,
                child: Text(_saving ? 'Saving...' : 'Save changes'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
