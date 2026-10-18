import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/chat_models.dart';
import '../../services/api_client.dart';
import '../../services/chat_environment.dart';
import '../../services/meridian_api.dart';
import 'conversation_controller.dart';
import 'conversation_screen.dart';
import 'new_chat_screen.dart';
import 'widgets/empty_state.dart';

/// The list of conversations.
///
/// Reads from the device's store and never from the network directly, for the
/// same reason the conversation screen does: the app has to be usable with no
/// signal, and the only way to guarantee that is for the UI to have one source
/// and for it to be the local one.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({
    super.key,
    required this.api,
    required this.chat,
    this.myUserId,
    this.myUsername,
  });

  final MeridianApi api;

  /// Owns the store, the outbox and the sync engine. One object rather than four
  /// parameters, and one place to clear on sign-out.
  final ChatEnvironment chat;
  final int? myUserId;
  final String? myUsername;

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  List<ConversationSummary> _conversations = const [];
  String _query = '';
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_refresh());
  }

  Future<void> _load() async {
    final loaded = await widget.chat.store.conversations();
    if (!mounted) return;
    setState(() => _conversations = loaded);
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _syncing = true);
    try {
      await widget.chat.sync.syncAll();
      // Sending whatever is queued is what makes a message that was typed while
      // offline eventually leave, without the user having to remember it.
      await widget.chat.senderFor(widget.myUserId ?? 0).flush();
      await _load();
    } on ApiException {
      // Offline at the list level is normal and invisible: whatever the device
      // already has is what is shown.
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  List<ConversationSummary> get _visible {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _conversations;
    return _conversations
        .where(
          (c) =>
              (c.title ?? '').toLowerCase().contains(query) ||
              (c.preview ?? '').toLowerCase().contains(query),
        )
        .toList();
  }

  Future<void> _open(ConversationSummary conversation) async {
    final controller = ConversationController(
      conversationId: conversation.id,
      myUserId: widget.myUserId,
      api: widget.chat.api,
      store: widget.chat.store,
      outbox: widget.chat.outbox,
      sender: widget.chat.senderFor(widget.myUserId ?? 0),
      sync: widget.chat.sync,
      realtime: widget.chat.realtime,
    );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          controller: controller,
          myUserId: widget.myUserId,
        ),
      ),
    );
    // Ticks and the preview will have moved.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _visible;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Search messages or names…',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
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
          if (_syncing) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: visible.isEmpty
                ? EmptyState(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: _query.isEmpty ? 'No chats yet.' : 'No matches.',
                    subtitle: _query.isEmpty
                        ? 'Your conversations with friends and faculty will '
                              'show up here.'
                        : 'Nothing matches “$_query”.',
                    actionLabel: _query.isEmpty ? 'Start a chat' : 'Clear search',
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final conversation = visible[index];
                        return _ConversationTile(
                          conversation: conversation,
                          onTap: () => _open(conversation),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NewChatScreen(
              api: widget.api,
              chat: widget.chat,
              myUserId: widget.myUserId,
              myUsername: widget.myUsername,
            ),
          ),
        ),
        tooltip: 'New chat',
        child: const Icon(Icons.add_rounded, size: 28),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.onTap});

  final ConversationSummary conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = conversation.unreadCount;
    final title = conversation.title ?? 'Conversation';
    final when = conversation.lastMessageAt;

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: CircleAvatar(
        radius: 23,
        backgroundColor: scheme.primaryContainer,
        child: Text(
          title.isEmpty ? '?' : title[0].toUpperCase(),
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          // Without a time on the row, telling two conversations apart means
          // opening both. Relative for today and yesterday, a date beyond that.
          if (when != null) ...[
            const SizedBox(width: 8),
            Text(
              _rowTime(when),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: unread > 0 ? scheme.primary : scheme.outline,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        // Null preview means the conversation's only message has expired, which
        // is not the same as a conversation with nothing in it.
        conversation.preview ?? 'No messages yet',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: conversation.preview == null ? scheme.outline : null,
          fontStyle: conversation.preview == null ? FontStyle.italic : null,
        ),
      ),
      trailing: unread > 0
          ? Badge(label: Text('$unread'), backgroundColor: scheme.primary)
          : null,
    );
  }

  /// `14:32` today, `Yesterday`, `12 Mar` beyond.
  static String _rowTime(DateTime when) {
    final local = when.toLocal();
    final now = DateTime.now();
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(local.year, local.month, local.day)).inDays;
    if (days == 0) {
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }
    if (days == 1) return 'Yesterday';
    const months = [
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
    return '${local.day} ${months[local.month - 1]}';
  }
}