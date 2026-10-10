import 'package:flutter/material.dart';

import 'widgets/empty_state.dart';

class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.play_circle_outline_rounded,
      title: 'No posts yet.',
      subtitle:
          'Student posts, reels and campus feed will appear here.',
      actionLabel: 'Explore feed',
    );
  }
}
