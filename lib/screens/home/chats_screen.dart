import 'package:flutter/material.dart';

import '../../services/meridian_api.dart';
import 'new_chat_screen.dart';
import 'widgets/empty_state.dart';

class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key, required this.api, this.myUsername});

  /// Passed to the new-chat screen, which needs it to search for people.
  final MeridianApi api;

  /// The signed-in handle, so search does not list you as somebody to message.
  final String? myUsername;

  void _openNewChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NewChatScreen(api: api, myUsername: myUsername),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // Search field below title bar (WhatsApp-style).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search messages or names…',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
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
          const Expanded(
            child: EmptyState(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'No chats yet.',
              subtitle:
                  'Your conversations with friends and faculty will show up here.',
              actionLabel: 'Start a chat',
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openNewChat(context),
        tooltip: 'New chat',
        child: const Icon(Icons.add_rounded, size: 28),
      ),
    );
  }
}
