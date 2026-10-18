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
  bool _canLoadOlder = false;

  ConversationController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.addListener(_loadOlderWhenAtTop);
    _controller.open();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.removeListener(_loadOlderWhenAtTop);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {
      _canLoadOlder = _controller.canLoadOlder;
    });
  }

  /// Fetch older history when the user reaches the top of the list.
  ///
  /// Keyed off the scroll position rather than a button, because that is what
  /// everybody's thumbs already expect from a chat.
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
                      itemCount: _controller.messages.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _controller.messages.length) {
                          return _TopOfHistory(
                            loading: _controller.isLoadingOlder,
                            hasMore: _canLoadOlder,
                          );
                        }
                        // reversed: index 0 is the newest, so the message is
                        // found from the end of the list.
                        final message =
                            _controller.messages[
                                _controller.messages.length - 1 - index];
                        return _Bubble(
                          message: message,
                          mine: widget.myUserId == message.senderId,
                        );
                      },
                    ),
            ),
            _Composer(
              controller: _composer,
              onSend: _send,
              hint: _controller.hasExpiredMessages
                  ? 'Older messages have expired'
                  : 'Message',
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
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                pending == 1 ? '1 message was not sent' : '$pending messages were not sent',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () => onRetryAll(),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});

  final ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = mine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final foreground = mine ? scheme.onPrimaryContainer : scheme.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
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
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  _formatTime(message.createdAt),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: foreground.withValues(alpha: 0.6),
                  ),
                ),
                if (mine) ...[
                  const SizedBox(width: 4),
                  _Ticks(message: message, color: foreground),
                ],
              ],
            ),
            if (message.canRetry)
              // Wrap, not Row: the two actions plus the icon and label overflow
              // a 320px bubble in a large text scale, and the overflow stripe
              // would cover the message the user is trying to recover.
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () => _retry(context),
                    icon: Icon(
                      Icons.refresh_rounded,
                      size: 14,
                      color: scheme.error,
                    ),
                    label: Text(
                      'Not sent. Retry',
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _discard(context),
                    child: Text(
                      'Discard',
                      style: TextStyle(color: foreground.withValues(alpha: 0.7)),
                    ),
                  ),
                ],
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.hint,
  });

  final TextEditingController controller;
  final Future<void> Function() onSend;
  final String hint;

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