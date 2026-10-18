import 'package:flutter/material.dart';

import '../../data/chat_models.dart';
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
    if (!_scroll.hasClients) return;
    // Anchored to the bottom so the message just sent is visible.
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

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
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

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    this.showTimestamp = true,
    this.continued = false,
  });

  final ChatMessage message;
  final bool mine;

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
            else
              Text(message.body, style: TextStyle(color: foreground)),
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
  });

  final TextEditingController controller;
  final Future<void> Function() onSend;
  final String hint;

  /// Fires on every keystroke, which is what typing notices need. The controller
  /// throttles before it reaches the network.
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
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