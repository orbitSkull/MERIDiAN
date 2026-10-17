import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/settings.dart';
import '../../models/username.dart';
import '../../services/api_client.dart';
import '../../services/meridian_api.dart';

/// New chat: find somebody to message.
///
/// Searches as you type, matching anywhere in a handle. Type "aar" and every
/// handle containing it comes back, closest first.
///
/// This is a directory, which is a deliberate change from what the other
/// username endpoints do -- they answer the same thing whatever you ask, so that
/// none of them can be used to work out who is at the college. A directory is
/// more useful and more expensive, so it is rate limited like the availability
/// checker, needs a session, refuses a query under three characters, and says
/// when a result is only the first page.
///
/// Nobody found here can be messaged yet. There is no conversation, message or
/// delivery behind this, so tapping somebody says so rather than opening an
/// empty screen that looks like a bug.
class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key, required this.api, this.myUsername});

  final MeridianApi api;

  /// The signed-in handle, so the search does not list you as somebody to
  /// message. Null when unknown, which costs one row on the list.
  final String? myUsername;

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  /// Shortest query the server will answer. Matching it here means no request is
  /// made for something that is guaranteed to be refused.
  static const _minQuery = 3;

  final TextEditingController _query = TextEditingController();

  Timer? _debounce;
  UserSearch? _result;
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

  bool get _longEnough => _typed.length >= _minQuery;

  void _onChanged(String _) {
    _debounce?.cancel();
    final typed = _typed;
    final longEnough = typed.length >= _minQuery;

    setState(() {
      _error = null;
      // Too short clears the previous answer rather than leaving stale names
      // under a query that no longer matches them.
      if (!longEnough) {
        _result = null;
        _searching = false;
        _searchedFor = '';
        return;
      }
      _searching = true;
    });
    if (!longEnough) return;

    // A beat of quiet. Without it every keystroke is a request, which is both
    // slow and the fastest way to be rate limited on a directory search.
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(typed));
  }

  Future<void> _search(String query) async {
    try {
      final result = await widget.api.searchUsers(query);
      // The person may have kept typing while this was in flight. A reply about
      // a query that is no longer on screen is not worth showing.
      if (!mounted || _typed != query) return;
      setState(() {
        _result = result;
        _searchedFor = query;
        _searching = false;
        // Cleared here, not only before the request, or the retry button would
        // re-run the search and leave the error on screen.
        _error = null;
      });
    } on ApiException catch (error) {
      if (!mounted || _typed != query) return;
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
                // Handles never contain whitespace or a capital. Refusing them at
                // the keyboard keeps the field honest without the person having
                // to learn the rules.
                FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9._]')),
                LengthLimitingTextInputFormatter(kUsernameMaxLength),
              ],
              decoration: InputDecoration(
                hintText: 'Search people by username',
                helperText: _longEnough
                    ? 'Showing anyone whose handle contains "$_typed".'
                    : 'At least $_minQuery characters.',
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
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _results() {
    if (_error != null) {
      return _Message(
        icon: Icons.cloud_off_rounded,
        title: 'Could not search',
        detail: _error!,
        action: TextButton(
          onPressed: () => _search(_typed),
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
        title: 'Find somebody to message',
        detail: 'Start typing a few letters of their username.',
      );
    }
    if (result.isEmpty) {
      return _Message(
        icon: Icons.person_off_outlined,
        title: 'Nobody found',
        detail: 'No username contains "$_searchedFor".',
      );
    }

    // You are not somebody to message, and listing yourself invites a tap that
    // does nothing useful.
    final people = result.results
        .where((person) => person.username != widget.myUsername)
        .toList();

    if (people.isEmpty) {
      return _Message(
        icon: Icons.person_off_outlined,
        title: 'Nobody found',
        detail: 'That only matched you.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: people.length + (result.truncated ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == people.length) {
          return const _TruncatedNotice();
        }
        return _PersonTile(
          user: people[index],
          onTap: () => _message(people[index]),
        );
      },
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

/// Says the list is a page, not the whole college.
///
/// Without it, twenty results read as "these are the only twenty people".
class _TruncatedNotice extends StatelessWidget {
  const _TruncatedNotice();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: Text(
        'More people match. Type more of the handle to narrow it down.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.user, required this.onTap});

  final DirectoryUser user;
  final VoidCallback onTap;

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
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: scheme.primary.withValues(alpha: 0.14),
          child: Text(
            initials,
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        title: Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        subtitle: Text(
          [
            '@${user.username}',
            user.roleLabel,
            if (user.collegeCode != null) user.collegeCode!,
          ].join('  ·  '),
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, size: 20),
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
