import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/user.dart';
import '../../../models/username.dart';
import '../../../services/api_client.dart';
import '../../../services/meridian_api.dart';
import '../../../services/usage_username_availability.dart';
import '../widgets/settings_tile.dart';

/// Username editor.
///
/// Availability lives in lib/services/usage_username_availability.dart so the
/// transport can change without touching this widget, and so a widget test can
/// inject a fake without building a Dio instance.
///
/// Two rules the server also enforces, since they are easy to lose when only
/// the client checks:
///
///   * Every answer takes about the same time whether or not the name is
///     taken. A fast "free" and a slow "taken" is an enumeration oracle: it
///     tells a stranger who is registered.
///   * The endpoint is rate limited harder than login. An unlimited checker is
///     a directory of every student at the college.
///
/// The availability check and the save are separate calls on purpose. Checking
/// proves the name is free at that moment; saving is what claims it, and only
/// the save can fail. Anyone can take the name in between, so a save that
/// reports a conflict has to be recoverable rather than treated as success.
class UsernameScreen extends StatefulWidget {
  const UsernameScreen({
    super.key,
    required this.profile,
    this.availability,
    this.api,
    this.onUsernameChanged,
  });

  final UserProfile profile;
  final UsernameAvailability? availability;
  final MeridianApi? api;

  /// Called with the handle the server settled on after a successful save.
  final ValueChanged<String>? onUsernameChanged;

  @override
  State<UsernameScreen> createState() => _UsernameScreenState();
}

class _UsernameScreenState extends State<UsernameScreen> {
  late final UsernameAvailability _availability =
      widget.availability ?? FakeUsernameAvailability();

  late final TextEditingController _controller;
  Timer? _debounce;

String _current = '';
  UsernameValidation? _validation;
  AvailabilityResult? _result;
  bool _checking = false;
  bool _dirty = false;
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    // The handle the server actually has, not a placeholder. Previously this
    // screen showed "aarav.sharma" to everyone, which made it look saved when
    // the account was carrying something else entirely.
    _current = widget.profile.username;
    _controller = TextEditingController(text: _current);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // Normalising here rather than rejecting uppercase keeps the handle
    // usable: the user types "Aarav", sees "aarav", and does not have to think
    // about the casing rule at all.
    final normalized = value.toLowerCase();

    // Write it back. Without this the field keeps the capitalised text while
    // state holds the lowercased form, so the field and what is validated
    // disagree, and the reply from a check gets discarded by the stale-text
    // guard in _runCheck.
    if (normalized != _controller.text) {
      _controller.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }

    final validation = normalized.isEmpty
        ? null
        : validateUsername(normalized);

    final shouldCheck = validation != null && validation.isValid;

    setState(() {
      _validation = validation;
      _result = null;
      _dirty = normalized != _current;
      _checking = shouldCheck;
    });
    if (!shouldCheck) return;

    // 500ms of quiet before checking. Without it every keystroke becomes a
    // request, which is both slow and the fastest way to get rate limited.
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _runCheck(normalized);
    });
  }

  Future<void> _runCheck(String username) async {
    final result = await _availability.check(username);
    // The user may have typed more while this was in flight; ignore a reply
    // about a value that is no longer on screen.
    if (!mounted || _controller.text != username) return;
    setState(() {
      _result = result;
      _checking = false;
    });
  }

bool get _canSave {
    final validation = _validation;
    if (validation == null || !validation.isValid) return false;
    if (_checking || _saving) return false;
    return _result?.available == true && _dirty;
  }

  Future<void> _save() async {
    final api = widget.api;
    final handle = _controller.text;
    if (api == null) return;

    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      // The server answers with the handle it settled on, not an echo, so what
      // is stored is what the account actually has.
      final saved = await api.saveUsername(handle);
      if (!mounted) return;
      widget.onUsernameChanged?.call(saved);
      Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      if (!mounted) return;
      // The availability check passed a moment ago and this still failed: the
      // name was taken in between, or the weekly change limit bit. Say so and
      // let the person try again rather than closing the screen.
      setState(() {
        _saving = false;
        _saveError = error.message;
        // Force a fresh check so the status line cannot keep claiming the name
        // is available.
        _result = null;
        _dirty = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return SettingsScaffold(
      title: 'Username',
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text(
                    widget.profile.fullName.isEmpty
                        ? '?'
                        : widget.profile.fullName[0].toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '@$_current',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        widget.profile.fullName,
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        SettingsSection(
          title: 'Change your username',
          subtitle: 'Your handle is how others find you on MERIDiAN.',
          footer:
              'Usernames are globally unique and can be changed once every 7 days. '
              'Use 3 to 24 characters: letters, numbers, dots and underscores.',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _controller,
                    onChanged: _onChanged,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(
                        kUsernameMaxLength,
                      ),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Username',
                      prefixText: '@  ',
                      border: const OutlineInputBorder(),
                      suffixIcon: _suffixIcon(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _statusLine(),
                  if (result != null && !result.available &&
                      result.suggestions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final suggestion in result.suggestions)
                          ActionChip(
                            label: Text('@$suggestion'),
                            onPressed: () {
                              _controller.text = suggestion;
                              _onChanged(suggestion);
                            },
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
child: FilledButton(
                onPressed: _canSave ? _save : null,
                child: Text(_saving ? 'Saving...' : 'Save username'),
              ),
            ),
            if (_saveError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  _saveError!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget? _suffixIcon() {
    if (_checking) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final result = _result;
    if (result == null) return null;
    return Icon(
      result.available ? Icons.check_circle_rounded : Icons.error_rounded,
      color: result.available ? Colors.green : Theme.of(context).colorScheme.error,
    );
  }

  Widget _statusLine() {
    final validation = _validation;
    if (validation != null && !validation.isValid) {
      return _message(validation.message!, isError: true);
    }
    if (_checking) {
      return _message('Checking availability...', isError: false);
    }
    final result = _result;
    if (result == null) return const SizedBox.shrink();
    if (result.available) {
      return _message('@${_controller.text} is available.', isError: false);
    }
    return _message(
      '@${_controller.text} is already taken.',
      isError: true,
    );
  }

  Widget _message(String text, {required bool isError}) {
    return Row(
      children: [
        Icon(
          isError ? Icons.error_outline_rounded : Icons.check_circle_outline,
          size: 16,
          color: isError
              ? Theme.of(context).colorScheme.error
              : Colors.green,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: isError
                  ? Theme.of(context).colorScheme.error
                  : Colors.green,
            ),
          ),
        ),
      ],
    );
  }
}

/// Mirrors kUsernameMaxLength from the model. Kept as a local const so this
/// file's imports stay focused on the screen.
const kUsernameMaxLength = 24;