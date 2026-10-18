import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/chat_models.dart';
import '../../data/media_cache.dart';
import '../../models/settings.dart';
import '../../services/api_client.dart';
import '../../services/meridian_api.dart';
import 'conversation_controller.dart';

/// One conversation.
///
/// Reads exclusively from the device's store. Nothing in this file talks to the
/// network, so the screen renders identically online and offline — which is the
/// point of the slice, and the reason there is no spinner over the message list.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.controller,
    this.myUserId,
  });

  final ConversationController controller;

  /// The signed-in user, so the widget knows which side of the screen a message
  /// goes on. Not read from the session here so a screenshot or a widget test
  /// does not need a signed-in user to exist.
  final int? myUserId;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Lazily created so a preview that never taps the button never touches the
  /// platform channel.
  ImagePicker? _picker;
  bool _sendingPhoto = false;

  ConversationController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // A ScrollController listener, not another one on the conversation
    // controller. Listeners on the controller fire when the *data* changes --
    // open, refresh, send -- and never while the user scrolls, so paging back
    // was unreachable no matter how far up they dragged.
    _scroll.addListener(_loadOlderWhenAtTop);
    _controller.open();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _scroll.removeListener(_loadOlderWhenAtTop);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// Fetch older history when the user reaches the top of the list.
  ///
  /// Keyed off the scroll position rather than a button, because that is what
  /// everybody's thumbs already expect from a chat. The list is reversed, so
  /// offset zero is the *oldest* end.
  void _loadOlderWhenAtTop() {
    if (!_scroll.hasClients || _scroll.offset > 80) return;
    if (!_controller.canLoadOlder || _controller.isLoadingOlder) return;
    _controller.loadOlder();
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    _composer.clear();
    await _controller.send(text);
    // Anchored to the bottom so the message just sent is visible.
    await _scrollToNewest();
  }

  /// The longest edge a sent photograph is allowed to have.
  ///
  /// A chat photo is not a photograph. Anything much larger than this is pixels
  /// nobody will see on the phone they are looking at, sent over a connection
  /// that has to carry it before the server will accept it.
  static const _maxEdge = 1920.0;

  /// Pick a photograph and send it, with whatever is in the composer as a
  /// caption.
  ///
  /// The picker is asked to shrink and re-encode natively rather than reading a
  /// 12 MB original into Dart and compressing it there: a phone photo is
  /// routinely over the server's ceiling, and a shrink that happens after the
  /// bytes are in memory has already cost what it was meant to save.
  Future<void> _attachPhoto() async {
    if (_sendingPhoto) return;
    final picker = _picker ??= ImagePicker();

    final XFile? picked;
    try {
      picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: _maxEdge,
        maxHeight: _maxEdge,
        imageQuality: 82,
      );
    } on Exception catch (error) {
      if (!mounted) return;
      // A denied permission arrives as a platform exception. It says so
      // plainly, because the fix is in system settings and the person has to go
      // and do it themselves.
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open photos. $error')));
      return;
    }
    // Null is a cancelled picker, which is not a failure and gets no message.
    if (picked == null || !mounted) return;

    final caption = _composer.text.trim();
    setState(() => _sendingPhoto = true);
    final failure = await _controller.sendWithMedia(
      bytes: await picked.readAsBytes(),
      mime: picked.mimeType ?? 'image/jpeg',
      caption: caption,
    );
    if (!mounted) return;
    setState(() => _sendingPhoto = false);

    if (failure != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failure)));
      // The caption stays where it was when the send failed. A photograph that
      // did not go should not also cost the person what they typed.
      return;
    }
    _composer.clear();
    _controller.reportTyping(false);
    await _scrollToNewest();
  }

  Future<void> _scrollToNewest() async {
    if (!_scroll.hasClients) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (_scroll.hasClients) {
      await _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = _controller.conversation?.title ?? 'Chat';

    final isGroup = _controller.conversation?.isGroup ?? false;

    return Scaffold(
      appBar: AppBar(
        // Tappable for a group, because a group's header is the only place the
        // roster and the owner's controls live. A direct conversation has
        // neither, so it stays inert rather than opening an empty screen.
        title: isGroup
            ? InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => GroupInfoScreen(
                      controller: _controller,
                      api: _controller.apiForGroups,
                      myUserId: widget.myUserId,
                    ),
                  ),
                ),
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 4),
                    Icon(Icons.info_outline_rounded,
                        size: 18, color: scheme.onSurfaceVariant),
                  ],
                ),
              )
            : Text(title),
        actions: [
          if (_controller.isSyncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_controller.hasFailedMessages)
              _FailureBanner(
                pending: _controller.pendingCount,
                onRetryAll: () async {
                  for (final message in _controller.messages
                      .where((m) => m.canRetry)
                      .toList()) {
                    await _controller.retry(message);
                  }
                },
              ),
            Expanded(
              child: _controller.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _controller.messages.isEmpty
                  ? const _EmptyConversation()
                  : ListView.builder(
                      controller: _scroll,
                      // Anchored at the bottom: a chat opens on the newest
                      // message, not on the first one ever sent.
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      // Two slots per message: the bubble, and the date
                      // separator that sits *below* it. Counted rather than
                      // spliced because the list is reversed, so index 0 is the
                      // newest message and the count has to run backwards.
                      itemCount: _controller.messages.length * 2 + 1,
                      itemBuilder: (context, index) {
                        final messages = _controller.messages;

                        // One extra slot past the oldest message, for the end of
                        // the conversation.
                        if (index >= messages.length * 2) {
                          return _TopOfHistory(
                            loading: _controller.isLoadingOlder,
                            hasMore: _controller.canLoadOlder,
                          );
                        }

                        final pair = index ~/ 2;

                        if (index.isOdd) {
                          // A separator belongs below the oldest message of its
                          // day, which makes it read top-down as a heading for
                          // everything older below it.
                          final message =
                              messages[messages.length - 1 - pair];
                          final next = pair + 1 < messages.length
                              ? messages[messages.length - 2 - pair]
                              : null;
                          if (next == null ||
                              !_sameDay(message.createdAt, next.createdAt)) {
                            return _DayDivider(day: message.createdAt);
                          }
                          return const SizedBox.shrink();
                        }

                        final position = messages.length - 1 - pair;
                        return _Bubble(
                          message: messages[position],
                          mine: widget.myUserId == messages[position].senderId,
                          media: _controller.media,
                          // Only the last message of a run carries a time and a
                          // tail. A timestamp on every bubble turns a
                          // conversation into a column of clocks.
                          showTimestamp: _isRunEnd(messages, position),
                          continued: position > 0 &&
                              _sameRun(messages[position - 1], messages[position]),
                        );
                      },
                    ),
            ),
            // Above the composer, not at the top of the list. Somewhere typing is
            // reported is about the conversation still being live, and the
            // bottom of the screen is where a person is looking while they wait.
            _TypingIndicator(visible: _controller.otherIsTyping),
            _Composer(
              controller: _composer,
              onSend: _send,
              onChanged: (text) => _controller.reportTyping(text.trim().isNotEmpty),
              onAttach: _attachPhoto,
              sending: _sendingPhoto,
              hint: 'Message',
            ),
          ],
        ),
      ),
      backgroundColor: scheme.surface,
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'No messages yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Messages are stored on your device, so this conversation '
              'stays readable without a connection.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// The strip above the oldest message.
class _TopOfHistory extends StatelessWidget {
  const _TopOfHistory({required this.loading, required this.hasMore});

  final bool loading;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          'Beginning of the conversation',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.outline),
        ),
      ),
    );
  }
}

class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.pending, required this.onRetryAll});

  final int pending;
  final Future<void> Function() onRetryAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: scheme.onErrorContainer,
    );

    return Material(
      color: scheme.errorContainer,
      child: Padding(
        // Slim. A full-height bar for one unsent message shouts louder than the
        // message it is about, and the failed bubble already carries its own
        // Retry. This line exists for "retry all of them", so it stays quiet.
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                pending == 1
                    ? '1 message was not sent'
                    : '$pending messages were not sent',
                style: style,
              ),
            ),
            // A text action rather than a TextButton: a filled button here drew
            // more attention than the conversation itself.
            InkWell(
              onTap: () => onRetryAll(),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  'Retry all',
                  style: style?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Consecutive messages from one person within [runWindow] read as a run.
bool _sameRun(ChatMessage older, ChatMessage newer) =>
    older.senderId == newer.senderId &&
    newer.createdAt.difference(older.createdAt).abs() < const Duration(minutes: 20);

/// True when nothing older continues the same run, so this is where the time
/// and the tail belong.
bool _isRunEnd(List<ChatMessage> display, int position) {
  if (position == display.length - 1) return true;
  return !_sameRun(display[position], display[position + 1]);
}

bool _sameDay(DateTime a, DateTime b) {
  final localA = a.toLocal();
  final localB = b.toLocal();
  return localA.year == localB.year &&
      localA.month == localB.month &&
      localA.day == localB.day;
}

/// "Today" / "Yesterday" / a date.
///
/// Reading a timestamp is work; a person looking for "what did we say on
/// Tuesday" should not have to do it. Relatives only where they are genuinely
/// clearer -- "14:30" last week is worse than "3 Mar".
String _dayLabel(DateTime when) {
  final local = when.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(local.year, local.month, local.day);
  final days = today.difference(that).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) {
    const names = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[local.weekday - 1];
  }
  return '${local.day} ${_months[local.month - 1]}';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            _dayLabel(day),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// One photograph in a bubble.
///
/// Renders nothing but a framed space until the link comes back, because a
/// bubble that grows from a line to a photograph as the image arrives makes the
/// whole conversation jump under the reader's thumb. The space is reserved at
/// the shape a chat photo is drawn, so the layout settles once and stays put.
/// Opens one photograph full screen.
///
/// A plain function rather than a method: it needs nothing from the screen that
/// called it, and a bubble that had to reach back up into the screen's state to
/// show a picture is a bubble that cannot be built in a preview.
void _openViewer(BuildContext context, ChatMessage message, String url) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => _PhotoViewer(url: url, message: message)),
  );
}

class _AttachmentImage extends StatefulWidget {
  const _AttachmentImage({
    required this.mediaId,
    required this.cache,
    required this.onOpen,
  });

  final int mediaId;
  final MediaCache? cache;
  final void Function(String url) onOpen;

  @override
  State<_AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<_AttachmentImage> {
  String? _url;

  /// Set when the server declined, as distinct from "not yet": without the
  /// distinction a refusal would be indistinguishable from slow, and the
  /// placeholder would spin forever on a file that is gone.
  bool _refused = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_AttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaId != widget.mediaId) {
      _url = null;
      _refused = false;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final cache = widget.cache;
    if (cache == null) {
      // A preview with no server. Not a failure, just nothing to show.
      if (mounted) setState(() => _refused = true);
      return;
    }
    final url = await cache.urlFor(widget.mediaId);
    if (!mounted) return;
    setState(() {
      _url = url;
      _refused = url == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_refused) {
      // Said plainly rather than as a broken-image glyph, because the honest
      // answer is that it has expired and a person can act on that.
      return Container(
        width: 190,
        height: 120,
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_not_supported_outlined,
                color: scheme.onSurfaceVariant,
                size: 22,
              ),
              const SizedBox(height: 6),
              Text(
                'Photo unavailable',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            // Sized before the bytes exist so the bubble does not resize under
            // the reader when they do.
            Container(width: 190, height: 140, color: scheme.surfaceContainerHighest),
            if (_url != null)
              GestureDetector(
                onTap: () => widget.onOpen(_url!),
                child: Image.network(
                  _url!,
                  width: 190,
                  height: 140,
                  // Cover, so a very tall photograph is cropped rather than
                  // shrunk to a thumbnail the size of a stamp.
                  fit: BoxFit.cover,
                  // The cache already remembers the link; this stops a rebuild
                  // from re-decoding the same bitmap for a different URL.
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (context, error, stack) => const SizedBox(
                    width: 190,
                    height: 140,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen view of one photograph.
class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.url, required this.message});

  final String url;
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(
          _formatTime(message.createdAt),
          style: const TextStyle(color: Colors.white),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Center(
        // InteractiveViewer rather than a fixed fit, because the one thing
        // somebody opens a photograph to do is look closely at part of it.
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => const Center(
              child: Text(
                'This photo is no longer available.',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who is in this group, and what the owner may do about it.
///
/// Opened from a group's header. Direct conversations have no roster worth
/// showing and no owner, so they do not get this screen at all rather than
/// getting one with everything on it disabled.
class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({
    super.key,
    required this.controller,
    required this.api,
    required this.myUserId,
  });

  final ConversationController controller;
  final MeridianApi api;
  final int? myUserId;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  List<ConversationMember>? _members;
  bool _loading = true;
  bool _busy = false;

  /// Set when the person is no longer in the conversation.
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final members = await widget.controller.loadMembers();
      if (!mounted) return;
      setState(() {
        _members = members;
        _loading = false;
        // Null means the server says you are not a member. Removed, or you
        // left and something went wrong coming back -- either way this screen
        // has nothing true to show, so it closes rather than pretending.
        _gone = members == null;
      });
      if (_gone) Navigator.of(context).maybePop();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  bool get _isOwner =>
      widget.myUserId != null &&
      (_members?.any((m) => m.userId == widget.myUserId && m.isOwner) ??
          false);

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename() async {
    final current = widget.controller.conversation?.title ?? '';
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: current),
    );
    if (text == null || text.trim().isEmpty) return;
    await _run(() => widget.controller.rename(text));
    await _load();
  }

  Future<void> _addMembers() async {
    final picked = await Navigator.of(context).push<List<DirectoryUser>>(
      MaterialPageRoute(
        builder: (_) => _AddPeopleScreen(
          api: widget.api,
          exclude: (_members ?? const <ConversationMember>[])
              .map((m) => m.userId)
              .toSet(),
          me: widget.myUserId,
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final ids = picked.map((u) => u.id).whereType<int>().toList();
    if (ids.isEmpty) return;
    await _run(() => widget.controller.addMembers(ids));
    await _load();
  }

  Future<void> _leave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave this group?'),
        content: const Text(
          'You will stop receiving its messages. Whoever added you can add you '
          'back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _run(() async {
      await widget.controller.leave();
      if (mounted) {
        // Two pops: this screen, then the conversation that is no longer there.
        Navigator.of(context).pop();
        Navigator.of(context).maybePop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = widget.controller.conversation?.title ?? 'Group';

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Group info',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      if (_isOwner)
                        IconButton(
                          tooltip: 'Rename',
                          onPressed: _busy ? null : _rename,
                          icon: const Icon(Icons.edit_outlined),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    '${_members?.length ?? 0} members',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_isOwner)
                  ListTile(
                    leading: Icon(Icons.person_add_alt_1_outlined,
                        color: scheme.primary),
                    title: const Text('Add people'),
                    onTap: _busy ? null : _addMembers,
                  ),
                const Divider(),
                for (final member in _members ?? const <ConversationMember>[])
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primary.withValues(alpha: 0.14),
                      child: Text(
                        _initials(member.label),
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    title: Text(member.label),
                    subtitle: Text('@${member.username}'),
                    // The owner is labelled rather than given a control that
                    // removes them: there is no way to hand a group on, so
                    // showing a button that could not do anything would be a lie.
                    trailing: member.isOwner
                        ? const Chip(label: Text('Owner'))
                        : null,
                  ),
                const Divider(),
                ListTile(
                  leading: Icon(Icons.logout_rounded, color: scheme.error),
                  title: Text(
                    'Leave group',
                    style: TextStyle(color: scheme.error),
                  ),
                  onTap: _busy ? null : _leave,
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  static String _initials(String label) {
    final parts = label
        .replaceAll('@', '')
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2);
    if (parts.isEmpty) return '?';
    return parts.map((p) => p[0].toUpperCase()).join();
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename group'),
      content: TextField(
        controller: _text,
        autofocus: true,
        maxLength: 80,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Group name'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Pick people to add, minus those already in.
///
/// Shares the directory search with the new-chat screens rather than inventing
/// its own: two search implementations in one app is how they drift apart and
/// one of them ends up rating a query differently.
class _AddPeopleScreen extends StatefulWidget {
  const _AddPeopleScreen({
    required this.api,
    required this.exclude,
    required this.me,
  });

  final MeridianApi api;

  /// User ids already in the group, which cannot be added again.
  final Set<int> exclude;

  final int? me;

  @override
  State<_AddPeopleScreen> createState() => _AddPeopleScreenState();
}

class _AddPeopleScreenState extends State<_AddPeopleScreen> {
  static const _minQuery = 3;

  final TextEditingController _query = TextEditingController();
  final Map<int, DirectoryUser> _picked = {};

  Timer? _debounce;
  UserSearch? _result;
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    final typed = _query.text.trim().toLowerCase();
    setState(() {
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
      if (!mounted || _query.text.trim().toLowerCase() != query) return;
      setState(() {
        _result = result;
        _searching = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _result = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add people'),
        actions: [
          if (_picked.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.of(context).pop(_picked.values.toList()),
              child: Text('Add ${_picked.length}'),
            ),
        ],
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
              decoration: const InputDecoration(
                hintText: 'Search by username',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _results() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    final result = _result;
    if (result == null) {
      return const Center(child: Text('Search for somebody to add.'));
    }
    final people = result.results
        .where(
          (p) =>
              p.id != null &&
              p.id != widget.me &&
              !widget.exclude.contains(p.id) &&
              !_picked.containsKey(p.id),
        )
        .toList();
    if (people.isEmpty) {
      return const Center(child: Text('Nobody here to add.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: people.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final person = people[index];
        return Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            title: Text(person.fullName),
            subtitle: Text('@${person.username}'),
            trailing: const Icon(Icons.add_circle_outline_rounded),
            onTap: () => setState(() => _picked[person.id!] = person),
          ),
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    this.showTimestamp = true,
    this.continued = false,
    this.media,
  });

  final ChatMessage message;
  final bool mine;

  /// Where short-lived links come from. Null in a preview that has no API to
  /// ask, in which case the image area simply shows its placeholder.
  final MediaCache? media;

  /// Whether this message closes a run, and so is the one that carries a time
  /// and the pointed corner.
  final bool showTimestamp;

  /// Whether the message above is from the same person in the same run, so this
  /// one sits tight under it instead of floating.
  final bool continued;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = mine
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = mine ? scheme.onPrimaryContainer : scheme.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        // Tight under the previous message of the same run, loose under a
        // change of speaker or of day. That single number is most of what makes
        // a conversation read as a conversation.
        margin: EdgeInsets.only(
          top: continued ? 2 : 8,
          bottom: 2,
          left: 4,
          right: 4,
        ),
        padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            // Only the message that closes a run gets the pointed corner, so a
            // stack of three looks like one utterance rather than three.
            bottomLeft: Radius.circular(!mine && showTimestamp ? 4 : 16),
            bottomRight: Radius.circular(mine && showTimestamp ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.expired)
              _Notice(
                icon: Icons.history_toggle_off_rounded,
                text: 'This message has expired',
                color: foreground,
              )
            else ...[
              if (message.attachmentId != null && !message.attachmentExpired)
                _AttachmentImage(
                  mediaId: message.attachmentId!,
                  cache: media,
                  onOpen: (url) => _openViewer(context, message, url),
                ),
              if (message.body.isNotEmpty)
                Text(message.body, style: TextStyle(color: foreground)),
            ],
            if (message.attachmentExpired)
              _Notice(
                icon: Icons.image_not_supported_outlined,
                text: 'Attachment expired',
                color: foreground,
              ),
            if (showTimestamp || mine || message.canRetry)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (showTimestamp)
                      Text(
                        _formatTime(message.createdAt),
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(
                              color: foreground.withValues(alpha: 0.6),
                            ),
                      ),
                    if (mine) ...[
                      const SizedBox(width: 4),
                      _Ticks(message: message, color: foreground),
                    ],
                  ],
                ),
              ),
            // A failed send. One compact line, not two buttons inside the
            // bubble: the banner above already says the message was not sent and
            // offers a Retry for all of them, so repeating it here at button
            // scale doubled the shouting and stretched the bubble to twice the
            // height of the message it was about.
            if (message.canRetry) _FailedFooter(
              message: message,
              foreground: foreground,
              onRetry: () => _retry(context),
              onDiscard: () => _discard(context),
            ),
          ],
        ),
      ),
    );
  }

  void _retry(BuildContext context) {
    final controller = context
        .findAncestorStateOfType<_ConversationScreenState>()
        ?._controller;
    controller?.retry(message);
  }

  void _discard(BuildContext context) {
    final controller = context
        .findAncestorStateOfType<_ConversationScreenState>()
        ?._controller;
    controller?.discard(message);
  }
}

/// The affordance on a message that never arrived.
class _FailedFooter extends StatelessWidget {
  const _FailedFooter({
    required this.message,
    required this.foreground,
    required this.onRetry,
    required this.onDiscard,
  });

  final ChatMessage message;
  final Color foreground;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.error,
      fontWeight: FontWeight.w600,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        children: [
          InkWell(
            onTap: onRetry,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text('Not sent · Retry', style: style),
            ),
          ),
          InkWell(
            onTap: onDiscard,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                'Discard',
                style: style?.copyWith(color: foreground.withValues(alpha: 0.7)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color.withValues(alpha: 0.7)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: color.withValues(alpha: 0.8),
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }
}

/// The four ticks.
///
/// One icon rather than four. WhatsApp draws a single tick and changes its
/// colour, and four separate glyphs means four translations and four things to
/// get subtly wrong.
class _Ticks extends StatelessWidget {
  const _Ticks({required this.message, required this.color});

  final ChatMessage message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, tint) = switch (message.state) {
      MessageSendState.sending => (Icons.schedule_rounded, color.withValues(alpha: 0.6)),
      MessageSendState.sent => (Icons.check_rounded, color.withValues(alpha: 0.6)),
      MessageSendState.delivered => (Icons.done_all_rounded, color.withValues(alpha: 0.75)),
      MessageSendState.read => (Icons.done_all_rounded, scheme.primary),
      MessageSendState.failed => (Icons.error_outline_rounded, scheme.error),
    };

    return Semantics(
      // container: true, because without it this label merges into the bubble's
      // own semantics node and a screen reader is given "hello 10:42 Sent" as
      // one string rather than a tick it can announce on its own.
      container: true,
      label: switch (message.state) {
        MessageSendState.sending => 'Sending',
        MessageSendState.sent => 'Sent',
        MessageSendState.delivered => 'Delivered',
        MessageSendState.read => 'Read',
        MessageSendState.failed => 'Not sent',
      },
      child: Icon(icon, size: 15, color: tint),
    );
  }
}

/// Somebody is typing.
///
/// A row of three dots that pulses, because the alternative -- a message that has
/// not arrived yet -- looks identical to being ignored. Sized so it appears and
/// disappears without the composer jumping: it occupies no height when hidden,
/// and the composer does not move when it appears.
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator({required this.visible});

  final bool visible;

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  /// Built in [initState], not as a `late final` field initialiser.
  ///
  /// The widget returns early when nobody is typing, so build never touches the
  /// controller -- and a lazy initialiser first runs in `dispose`, which creates
  /// a ticker while the element is being deactivated. Flutter throws for exactly
  /// that, so opening a conversation where nobody is typing would crash.
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.visible) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_TypingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    // Only animate while there is something to say. A ticker running for an
    // invisible indicator is a wakeup a phone pays for on every conversation.
    if (widget.visible) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(left: 20, bottom: 4),
      // Left, not centred. A Column aligns a minimum-width child to the middle
      // by default, which floats the indicator in the middle of the screen
      // instead of lining it up with the messages it is describing.
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.more_horiz_rounded,
                size: 16,
                color: scheme.primary.withValues(alpha: 0.4 + 0.4 * _pulse.value),
              ),
              const SizedBox(width: 6),
              Text(
                'typing…',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.primary.withValues(alpha: 0.7),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.hint,
    this.onChanged,
    this.onAttach,
    this.sending = false,
  });

  final TextEditingController controller;
  final Future<void> Function() onSend;
  final String hint;

  /// Fires on every keystroke, which is what typing notices need. The controller
  /// throttles before it reaches the network.
  final ValueChanged<String>? onChanged;

  /// Open the photo picker. Null disables the button, which is how a preview
  /// without a picker is drawn rather than crashing on tap.
  final Future<void> Function()? onAttach;

  /// True while a photograph is being uploaded, so the button cannot be pressed
  /// twice and send two copies.
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              onPressed: onAttach == null || sending ? null : onAttach,
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : const Icon(Icons.add_photo_alternate_outlined),
              tooltip: 'Send a photo',
              color: scheme.onSurfaceVariant,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: hint,
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: onSend,
              icon: const Icon(Icons.send_rounded),
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }
}

String _formatTime(DateTime time) {
  final local = time.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}