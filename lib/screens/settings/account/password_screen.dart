import 'package:flutter/material.dart';

import '../../../services/api_client.dart';
import '../../../services/meridian_api.dart';
import '../widgets/settings_tile.dart';

/// Change the password.
///
/// Requires the current one even though the caller is already authenticated. A
/// stolen access token would otherwise be enough to set a new password and keep
/// the account for good, which is the whole reason this screen asks.
///
/// The server revokes every session on success, including this one, so the
/// button here says so up front and the screen hands back "you are signed out"
/// rather than pretending nothing happened. Anything else would leave the person
/// tapping Save and then quietly failing every later request.
class PasswordScreen extends StatefulWidget {
  const PasswordScreen({super.key, required this.api, this.onPasswordChanged});

  final MeridianApi api;

  /// Called after a successful change, so the app can send the person to the
  /// login screen. Left to the caller because only they know how.
  final VoidCallback? onPasswordChanged;

  @override
  State<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends State<PasswordScreen> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  bool _saving = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// Local rules, so the obvious mistakes are caught without a round trip.
  ///
  /// The server enforces the same thing and is the authority; this only saves a
  /// request that was always going to be refused.
  String? get _localError {
    if (_next.text.length < 8) {
      return 'Use at least 8 characters.';
    }
    if (_next.text != _confirm.text) {
      return 'The two new passwords do not match.';
    }
    if (_next.text == _current.text && _current.text.isNotEmpty) {
      return 'That is your current password.';
    }
    return null;
  }

  bool get _canSubmit =>
      !_saving &&
      _current.text.isNotEmpty &&
      _next.text.isNotEmpty &&
      _localError == null;

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.changePassword(
        currentPassword: _current.text,
        newPassword: _next.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      widget.onPasswordChanged?.call();
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
    final localError = _localError;
    return SettingsScaffold(
      title: 'Change password',
      children: [
        SettingsSection(
          title: 'New password',
          footer:
              'Changing your password signs out every device, this one '
              'included. You will sign in again afterwards.',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Field(
                    controller: _current,
                    label: 'Current password',
                    obscure: _obscure,
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  _Field(
                    controller: _next,
                    label: 'New password',
                    obscure: _obscure,
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  _Field(
                    controller: _confirm,
                    label: 'Confirm new password',
                    obscure: _obscure,
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Checkbox(
                        value: !_obscure,
                        onChanged: (value) =>
                            setState(() => _obscure = !(value ?? false)),
                      ),
                      const Text('Show passwords'),
                    ],
                  ),
                  if (localError != null)
                    Text(
                      localError,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
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
                onPressed: _canSubmit ? _submit : null,
                child: Text(_saving ? 'Changing...' : 'Change password'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      onChanged: (_) => onChanged(),
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
