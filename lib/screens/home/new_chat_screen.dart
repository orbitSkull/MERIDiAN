import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/chat_models.dart';
import '../../models/settings.dart';
import '../../models/username.dart';
import '../../services/api_client.dart';
import '../../services/chat_environment.dart';
import '../../services/meridian_api.dart';
import '../../services/outbox.dart';
import 'conversation_controller.dart';
import 'conversation_screen.dart';

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
  const NewChatScreen({
    super.key,
    required this.api,
    required this.chat,
    this.myUserId,
    this.myUsername,
  });

  final MeridianApi api;

  /// Owns the store and the client, so opening a conversation is the same
  /// operation here as it is everywhere else.
  ///
  /// A parameter rather than a lookup from the provider: read inside a gesture
  /// handler, a missing provider would not fail until somebody tapped somebody,
  /// which is the worst possible moment to discover it.
  final ChatEnvironment chat;

  /// The signed-in user, so an optimistic bubble lands on the right side.
  final int? myUserId;

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
          _Options(onCreateGroup: _createGroup),
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
    final sender = widget.chat.senderFor(widget.myUserId ?? 0);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _Opening(
          user: user,
          chat: widget.chat,
          sender: sender,
          myUserId: widget.myUserId,
        ),
      ),
    );
  }

  void _createGroup() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NewGroupScreen(
          api: widget.api,
          chat: widget.chat,
          myUserId: widget.myUserId,
          myUsername: widget.myUsername,
        ),
      ),
    );
  }
}

/// Create a group: a name, and at least one other person.
///
/// A group needs a title because a chat list full of unnamed groups is a list
/// nobody can scan, and it needs another person because a group of one is a
/// direct conversation that took a roundabout route to get there.
///
/// People are picked from the same directory search as a one-to-one chat, and
/// a choice is kept even when the search that found it is retyped, so picking
/// three people and then looking for a fourth does not empty the first three.
class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({
    super.key,
    required this.api,
    required this.chat,
    this.myUserId,
    this.myUsername,
  });

  final MeridianApi api;
  final ChatEnvironment chat;
  final int? myUserId;
  final String? myUsername;

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  static const _minQuery = 3;

  /// The ceiling the server enforces, mirrored here so the button explains
  /// itself instead of failing after the fact.
  static const _maxMembers = 50;

  final TextEditingController _title = TextEditingController();
  final TextEditingController _query = TextEditingController();

  Timer? _debounce;
  UserSearch? _result;
  bool _searching = false;
  String? _error;

  /// Chosen people, keyed by user id so picking the same person twice is not
  /// possible and their row keeps its tick when the list re-renders.
  final Map<int, DirectoryUser> _chosen = {};

  bool _creating = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _title.dispose();
    _query.dispose();
    super.dispose();
  }

  String get _typed => _query.text.trim().toLowerCase();

  bool get _canCreate =>
      !_creating &&
      _title.text.trim().isNotEmpty &&
      _chosen.isNotEmpty &&
      _chosen.length <= _maxMembers;

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    final typed = _typed;
    setState(() {
      _error = null;
      if (typed.length < _minQuery) {
        _result = null;
        _searching = false;
        return;
      }
      _searching = true;
    });
    if (typed.length < _minQuery) return;
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(typed));
  }

  Future<void> _search(String query) async {
    try {
      final result = await widget.api.searchUsers(query);
      if (!mounted || _typed != query) return;
      setState(() {
        _result = result;
        _searching = false;
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

  void _toggle(DirectoryUser user) {
    final id = user.id;
    if (id == null) return;
    setState(() {
      if (_chosen.containsKey(id)) {
        _chosen.remove(id);
      } else if (_chosen.length < _maxMembers) {
        _chosen[id] = user;
      }
    });
  }

  Future<void> _create() async {
    if (!_canCreate) return;
    final ids = _chosen.keys.toList();
    setState(() => _creating = true);
    try {
      final conversation = await widget.api.createGroup(
        title: _title.text.trim(),
        memberIds: ids,
      );
      // Written to the store before the conversation is shown, so the chats list
      // has it the moment the user goes back rather than after the next sync.
      await widget.chat.store.upsertConversations([conversation]);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ConversationScreen(
            controller: ConversationController(
              conversationId: conversation.id,
              myUserId: widget.myUserId,
              api: widget.chat.api,
              store: widget.chat.store,
              outbox: widget.chat.outbox,
              sender: widget.chat.senderFor(widget.myUserId ?? 0),
              sync: widget.chat.sync,
              realtime: widget.chat.realtime,
            ),
            myUserId: widget.myUserId,
          ),
        ),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'New Group',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _title,
              onChanged: (_) => setState(() {}),
              textCapitalization: TextCapitalization.sentences,
              maxLength: 80,
              decoration: InputDecoration(
                labelText: 'Group name',
                hintText: 'e.g. Algorithms, Thursday',
                prefixIcon: const Icon(Icons.group_outlined),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _query,
              onChanged: _onQueryChanged,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9._]')),
              ],
              decoration: InputDecoration(
                hintText: 'Add people by username',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
              ),
            ),
          ),
          if (_chosen.isNotEmpty)
            _ChosenStrip(
              chosen: _chosen.values.toList(),
              onRemove: (user) {
                final id = user.id;
                if (id != null) setState(() => _chosen.remove(id));
              },
            ),
          const Divider(height: 16),
          Expanded(child: _results()),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _canCreate ? _create : null,
            child: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : Text(
                    _chosen.isEmpty
                        ? 'Add at least one person'
                        : 'Create group with ${_chosen.length}',
                  ),
          ),
        ),
      ),
    );
  }

  Widget _results() {
    if (_error != null) {
      return _Message(
        icon: Icons.cloud_off_rounded,
        title: 'Could not search',
        detail: _error!,
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
        icon: Icons.group_add_outlined,
        title: 'Name the group, then add people',
        detail: 'Search for a username and tap to add them.',
      );
    }

    final people = result.results
        .where((person) => person.username != widget.myUsername)
        .toList();
    if (people.isEmpty) {
      return _Message(
        icon: Icons.person_off_outlined,
        title: 'Nobody found',
        detail: 'No username contains "$_typed".',
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
        final person = people[index];
        return _PersonTile(
          user: person,
          selected: person.id != null && _chosen.containsKey(person.id),
          onTap: () => _toggle(person),
        );
      },
    );
  }
}

/// The people already picked, so a long group does not have to be scrolled back
/// through to remember who is in it.
class _ChosenStrip extends StatelessWidget {
  const _ChosenStrip({required this.chosen, required this.onRemove});

  final List<DirectoryUser> chosen;
  final void Function(DirectoryUser) onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: chosen.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final person = chosen[index];
          return InputChip(
            label: Text('@${person.username}'),
            onDeleted: () => onRemove(person),
            deleteIconColor: scheme.onSurfaceVariant,
            visualDensity: VisualDensity.compact,
          );
        },
      ),
    );
  }
}

/// Opens or reopens the direct conversation, then shows it.
///
/// The opening call is asynchronous and can fail -- offline, or the person has
/// blocked you -- so it happens on a screen of its own. Pushing the
/// conversation first and opening behind it would show a conversation that
/// cannot be sent to and cannot be told apart from an empty one.
///
/// The conversation is written to the store here even when the server has no
/// messages in it, so the chats list shows it immediately and the next sync
/// fills it in.
class _Opening extends StatefulWidget {
  const _Opening({
    required this.user,
    required this.chat,
    required this.sender,
    required this.myUserId,
  });

  final DirectoryUser user;
  final ChatEnvironment chat;
  final OutboxSender sender;
  final int? myUserId;

  @override
  State<_Opening> createState() => _OpeningState();
}

class _OpeningState extends State<_Opening> {
  late final Future<ConversationSummary?> _opening = _open();

  Future<ConversationSummary?> _open() async {
    final userId = widget.user.id;
    if (userId == null) {
      // The id is what opening a conversation needs, and a result without one
      // cannot be opened. Handled rather than passed as null and turned into a
      // confusing server error.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That person cannot be messaged from here.'),
          ),
        );
      }
      return null;
    }
    try {
      final conversation = await widget.chat.api.openDirect(userId);
      await widget.chat.store.upsertConversations([conversation]);
      return conversation;
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.statusCode == 403
                  ? 'You cannot start a chat with @${widget.user.username}.'
                  : 'Could not open that chat. ${error.message}',
            ),
          ),
        );
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ConversationSummary?>(
      future: _opening,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final conversation = snapshot.data;
        if (conversation == null) {
          // Nothing to show. Popping rather than leaving a blank screen is what
          // the user tapped back expecting.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return const Scaffold(body: SizedBox.shrink());
        }

        return ConversationScreen(
          controller: ConversationController(
            conversationId: conversation.id,
            myUserId: widget.myUserId,
            api: widget.chat.api,
            store: widget.chat.store,
            outbox: widget.chat.outbox,
            sender: widget.sender,
            sync: widget.chat.sync,
            realtime: widget.chat.realtime,
          ),
          myUserId: widget.myUserId,
        );
      },
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
  const _PersonTile({
    required this.user,
    required this.onTap,
    this.selected = false,
  });

  final DirectoryUser user;
  final VoidCallback onTap;

  /// Whether this person is already in the group being built.
  final bool selected;

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
        // A tick rather than a chevron, because in this screen a tap adds
        // rather than opens, and a chevron would promise the wrong thing.
        trailing: selected
            ? Icon(Icons.check_circle_rounded, color: scheme.primary)
            : const Icon(Icons.add_circle_outline_rounded, size: 20),
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

/// Group and QR.
class _Options extends StatelessWidget {
  const _Options({required this.onCreateGroup});

  final VoidCallback onCreateGroup;

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
            onTap: onCreateGroup,
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
