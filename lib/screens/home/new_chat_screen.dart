import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/settings.dart';
import '../../models/username.dart';
import '../../services/api_client.dart';
import '../../services/meridian_api.dart';

/// New chat: find somebody by handle.
///
/// Exact handle, because that is the only thing the API answers. There is no
/// prefix search and no people directory, deliberately: the username endpoints
/// are built so they cannot be used to enumerate everyone at the college, and a
/// searchable directory would undo that.
///
/// The person found cannot be messaged yet. There is no conversation, no
/// message and no delivery behind this, so the button says so rather than
/// opening an empty screen that looks like a bug.
class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key, required this.api});

  final MeridianApi api;

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final TextEditingController _query = TextEditingController();

  Timer? _debounce;
  UserLookup? _result;
  bool _searching = false;
  String? _error;
  String _searchedFor = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// What the field currently holds, normalised the way the server normalises.
  String get _typed => _query.text.trim().toLowerCase();

  void _onChanged(String _) {
    _debounce?.cancel();
    final typed = _typed;
    final valid = validateUsername(typed).isValid;

    setState(() {
      _error = null;
      // Anything invalid clears the previous answer rather than leaving a stale
      // person's name under a handle that no longer matches it.
      if (!valid) {
        _result = null;
        _searching = false;
        _searchedFor = '';
        return;
      }
      _searching = true;
    });
    if (!valid) return;

    // Half a second of quiet. Without it every keystroke is a request, which is
    // the fastest way to get this endpoint's rate limit.
    _debounce = Timer(const Duration(milliseconds: 500), () => _lookup(typed));
  }

  Future<void> _lookup(String handle) async {
    try {
      final result = await widget.api.lookupUser(handle);
      // The person may have kept typing while this was in flight. A reply about
      // a handle that is no longer on screen is not worth showing.
      if (!mounted || _typed != handle) return;
      setState(() {
        _result = result;
        _searchedFor = handle;
        _searching = false;
        // Cleared here, not only before the request. Without it the retry button
        // re-ran the lookup and left the error on screen, so it looked like
        // nothing happened.
        _error = null;
      });
    } on ApiException catch (error) {
      if (!mounted || _typed != handle) return;
      setState(() {
        _searching = false;
        _error = error.message;
        _result = null;
      });
    }
  }

  void _clear() {
    _debounce?.cancel();
    _query.clear();
    setState(() {
      _result = null;
      _searching = false;
      _error = null;
      _searchedFor = '';
    });
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _query,
              onChanged: _onChanged,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.search,
              inputFormatters: [
                // Handles never contain whitespace or a capital. Refusing them
                // at the keyboard keeps the field honest without the person
                // having to learn the rules.
                FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9._]')),
                LengthLimitingTextInputFormatter(kUsernameMaxLength),
              ],
              decoration: InputDecoration(
                hintText: 'Search by exact username',
                helperText: 'Their full handle, for example aarav.sharma',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        onPressed: _clear,
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
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
          const _Options(),
          const Divider(height: 24),
          Expanded(child: _results(scheme)),
        ],
      ),
    );
  }

  Widget _results(ColorScheme scheme) {
    if (_error != null) {
      return _Message(
        icon: Icons.cloud_off_rounded,
        title: 'Could not search',
        detail: _error!,
        action: TextButton(
          onPressed: () => _lookup(_typed),
          child: const Text('Try again'),
        ),
      );
    }
    if (_searching) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }

    final result = _result;
    if (result == null) {
      return const _Message(
        icon: Icons.search_rounded,
        title: 'Find somebody by their handle',
        detail: 'Type their whole username. Handles are unique across the app.',
      );
    }

    final user = result.user;
    if (!result.found || user == null) {
      return _Message(
        icon: Icons.person_off_outlined,
        title: 'No account found',
        // Deliberately does not claim the handle is unclaimed. The endpoint
        // answers a miss the same way whatever the reason, and this screen must
        // not read as a way to test who is registered.
        detail: 'Nothing matches @$_searchedFor right now.',
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        _PersonTile(user: user),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => _message(user),
          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
          label: const Text('Message'),
        ),
      ],
    );
  }

  void _message(DirectoryUser user) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Chatting with @${user.username} is not built yet. There is no '
          'message backend behind this yet.',
        ),
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.user});

  final DirectoryUser user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = user.fullName;
    final initials = name.trim().isEmpty
        ? '?'
        : name
              .split(RegExp(r'\s+'))
              .where((part) => part.isNotEmpty)
              .take(2)
              .map((part) => part[0].toUpperCase())
              .join();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: scheme.primary.withValues(alpha: 0.14),
              child: Text(
                initials,
                style: TextStyle(
                  color: scheme.primary,
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
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      '@${user.username}',
                      user.roleLabel,
                      if (user.collegeCode != null) user.collegeCode!,
                    ].join('  ·  '),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

/// Group and QR, neither of which has a backend yet.
class _Options extends StatelessWidget {
  const _Options();

  void _soon(BuildContext context, String what) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$what is not built yet.')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primary.withValues(alpha: 0.12),
              child: Icon(Icons.group_add_outlined, color: scheme.primary),
            ),
            title: const Text(
              'Create New Group',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('Group with friends or class'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _soon(context, 'Groups'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primary.withValues(alpha: 0.12),
              child: Icon(Icons.qr_code_scanner_rounded, color: scheme.primary),
            ),
            title: const Text(
              'Scan QR',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('Add a friend via QR code'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _soon(context, 'QR codes'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ],
      ),
    );
  }
}
