import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/user.dart';
import '../../../models/username.dart';
import '../widgets/settings_tile.dart';

/// Stand-in for the server-side availability check.
///
/// The real implementation calls `GET /api/v1/users/username/check`, which the
/// backend answers from a Bloom filter backed by a unique index. Until that
/// endpoint exists this decides locally from [taken], so the screen can be
/// built and exercised end to end.
///
/// Two rules the real service must also enforce, because they are easy to lose
/// when only the client checks:
///
///   * Every answer must take about the same time whether or not the name is
///     taken. A fast "no" and a slow "yes" is an enumeration oracle: it tells a
///     stranger who is registered on the platform.
///   * The endpoint is rate limited harder than login. The backend already has
///     an account and an IP limiter; this needs its own bucket, since an
///     unlimited checker is a directory of every student at the college.
abstract class UsernameAvailability {
  Future<AvailabilityResult> check(String username);
}

class AvailabilityResult {
  const AvailabilityResult.available()
    : available = true,
      suggestions = const [];

  const AvailabilityResult.taken(this.suggestions) : available = false;

  final bool available;

  /// Alternatives to offer, already ordered. Empty when there is nothing
  /// useful to suggest.
  final List<String> suggestions;
}

/// Deterministic local fake, so the screen behaves consistently in tests and
/// demos instead of flipping at random.
class FakeUsernameAvailability implements UsernameAvailability {
  FakeUsernameAvailability({Set<String>? taken})
    : _taken = taken ?? const {'aarav.sharma', 'meera.iyer', 'admin'};

  final Set<String> _taken;

  @override
  Future<AvailabilityResult> check(String username) async {
    // A short delay so the screen's pending state is visible, which is what a
    // real network round trip looks like.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (_taken.contains(username)) {
      return AvailabilityResult.taken(
        _alternatives(username),
      );
    }
    return const AvailabilityResult.available();
  }

  List<String> _alternatives(String username) {
    final base = username.contains('.')
        ? username.substring(0, username.lastIndexOf('.'))
        : username;
    return [
      for (var n = 2; n <= 4; n++)
        if (!_taken.contains('$base.$n')) '$base.$n',
    ];
  }
}

/// Username editor.
///
/// Shows the current handle, validates as the user types, and checks
/// availability after a pause in typing. Nothing is saved server side yet.
class UsernameScreen extends StatefulWidget {
  const UsernameScreen({
    super.key,
    required this.profile,
    this.availability,
  });

  final UserProfile profile;
  final UsernameAvailability? availability;

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

  @override
  void initState() {
    super.initState();
    // Placeholder until the profile carries a username. The real value comes
    // from the server on first load.
    _current = 'aarav.sharma';
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
    if (_checking) return false;
    return _result?.available == true && _dirty;
  }

  void _save() {
    final handle = _controller.text;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Username set to @$handle (not saved yet).')),
    );
    Navigator.of(context).pop();
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
                child: const Text('Save username'),
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