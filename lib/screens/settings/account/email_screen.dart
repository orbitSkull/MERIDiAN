import 'package:flutter/material.dart';

import '../../../models/user.dart';
import '../../../services/api_client.dart';
import '../../../services/meridian_api.dart';
import '../widgets/settings_tile.dart';

/// Change the email address attached to the account.
///
/// The address can be set and replaced. Confirming it cannot: there is no mail
/// service behind the app yet, so this screen says so plainly rather than
/// offering a "Send verification email" button that goes nowhere. A button that
/// always appears to work and never delivers is worse than an honest gap.
class EmailScreen extends StatefulWidget {
  const EmailScreen({super.key, required this.api, required this.profile});

  final MeridianApi api;
  final UserProfile profile;

  @override
  State<EmailScreen> createState() => _EmailScreenState();
}

class _EmailScreenState extends State<EmailScreen> {
  late final TextEditingController _email = TextEditingController(
    text: widget.profile.email ?? '',
  );

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  /// Enough to catch a typo without pretending to be a validator. The server
  /// rejects anything malformed with a message worth showing.
  bool get _looksValid {
    final value = _email.text.trim();
    return value.isEmpty || (value.contains('@') && value.contains('.'));
  }

  bool get _dirty => _email.text.trim() != (widget.profile.email ?? '');

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await widget.api.updateProfile(email: _email.text.trim());
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
    final current = widget.profile.email;
    return SettingsScaffold(
      title: 'Email address',
      children: [
        SettingsSection(
          title: 'Current address',
          children: [
            SettingsTile(
              icon: Icons.mail_outline_rounded,
              title: current ?? 'Not set',
              subtitle: current == null
                  ? 'Add one so you can be reached outside the app.'
                  : widget.profile.emailVerified
                  ? 'Confirmed.'
                  : 'Not confirmed.',
            ),
          ],
        ),
        SettingsSection(
          title: current == null ? 'Add an address' : 'Change address',
          footer:
              'Changing the address clears its confirmed status, because a '
              'new address has not been proven to be yours.',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _email,
                    onChanged: (_) => setState(() {}),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Email address',
                      border: const OutlineInputBorder(),
                      helperText: _looksValid
                          ? 'Leave empty to remove your address.'
                          : 'That does not look like an email address.',
                      helperStyle: TextStyle(
                        color: _looksValid
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton(
                onPressed: _saving || !_dirty || !_looksValid ? null : _save,
                child: Text(_saving ? 'Saving...' : 'Save address'),
              ),
            ),
          ],
        ),
        SettingsSection(
          title: 'Confirmation',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(
                'Confirmation emails are not being sent yet, so an address can '
                'be saved but not verified. Nothing depends on a confirmed '
                'address today: sign-in uses your college and PRN.',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
