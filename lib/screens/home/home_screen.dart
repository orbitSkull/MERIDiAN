import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'ai_history_screen.dart';
import 'ai_screen.dart';
import 'chats_screen.dart';
import 'feed_screen.dart';
import 'settings_screen.dart';

/// Main screen after login/register — 4-tab bottom nav, UI-only.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  late final PageController _pageController = PageController();

  static const _pages = [
    ChatsScreen(),
    FeedScreen(),
    AiScreen(),
    SettingsScreen(),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  void _soon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('UI preview — nothing here yet.')),
    );
  }

  void _openAiHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AiHistoryScreen()),
    );
  }

  List<Widget> _actionsFor(int index) {
    switch (index) {
      case 0: // Chats -> notifications (non-functional)
        return [
          IconButton(
            onPressed: _soon,
            icon: const Icon(Icons.notifications_outlined),
            tooltip: 'Notifications',
          ),
        ];
      case 1: // Feed -> + post (non-functional)
        return [
          IconButton(
            onPressed: _soon,
            icon: const Icon(Icons.add_rounded),
            tooltip: 'New post',
          ),
        ];
      case 2: // AI -> history (opens history page)
        return [
          IconButton(
            onPressed: _openAiHistory,
            icon: const Icon(Icons.history_rounded),
            tooltip: 'AI history',
          ),
        ];
      case 3: // Settings -> dark/light toggle (functional)
        return [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: AppThemeMode.notifier,
            builder: (context, mode, _) {
              final isDark = mode == ThemeMode.dark;
              return IconButton(
                onPressed: AppThemeMode.toggle,
                icon: Icon(
                  isDark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                ),
                tooltip: isDark ? 'Light mode' : 'Dark mode',
              );
            },
          ),
        ];
      default:
        return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        title: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            'MERIDiAN',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              color: scheme.primary,
            ),
          ),
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
        actionsIconTheme: IconThemeData(color: scheme.onSurface),
        actions: _actionsFor(_index),
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (i) => setState(() => _index = i),
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _goTo,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline_rounded),
            selectedIcon: Icon(Icons.play_circle_fill_rounded),
            label: 'Feed',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome_rounded),
            label: 'AI',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
