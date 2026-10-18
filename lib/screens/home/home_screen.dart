import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_service.dart';
import '../../services/chat_environment.dart';
import '../../services/usage_username_availability.dart';
import '../../theme/app_theme.dart';
import 'ai_history_screen.dart';
import 'ai_screen.dart';
import 'chats_screen.dart';
import 'feed_screen.dart';
import 'settings_screen.dart';

/// Main screen after login/register — 4-tab bottom nav, UI-only.
///
/// No profile parameter. The settings tab reads the signed-in user from
/// [AuthService] itself, which is what stopped the login screen's
/// `HomeScreen(auth: ...)` from rendering a signed-out account screen.
class HomeScreen extends StatefulWidget {
  final AuthService auth;

  const HomeScreen({super.key, required this.auth});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  late final PageController _pageController = PageController();

  late final List<Widget> _pages = [
    ChatsScreen(
      api: widget.auth.api,
      chat: context.watch<ChatEnvironmentHolder>().environment,
      myUserId: widget.auth.user?.id,
      myUsername: widget.auth.user?.username,
    ),
    const FeedScreen(),
    const AiScreen(),
    SettingsScreen(
      auth: widget.auth,
      // The real checker, built from the client AuthService already owns. The
      // screen falls back to the local fake only when this is null, which is
      // what a widget test without an AuthService gets.
      usernameAvailability: ApiUsernameAvailability(widget.auth.api),
    ),
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
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AiHistoryScreen()));
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
              // The brightness the user is actually looking at, not the
              // stored mode. Under ThemeMode.system those differ, and using the
              // mode instead made the first tap appear to do nothing.
              final isDark = Theme.of(context).brightness == Brightness.dark;
              return IconButton(
                onPressed: () => AppThemeMode.toggle(currentlyDark: isDark),
                icon: Icon(
                  isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                ),
                tooltip: isDark
                    ? 'Switch to light mode'
                    : 'Switch to dark mode',
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
      body: Column(
        children: [
          // Offline banner: shown when the app is running on cached data
          // because the server was unreachable at launch.
          if (widget.auth.isOffline) const _OfflineBanner(),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _index = i),
              children: _pages,
            ),
          ),
        ],
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

/// Shown when the server was unreachable at launch.
///
/// The session is still valid; this only explains why fresh data may be
/// missing, and reassures the user they have not been signed out.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFEF3C7),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 18,
            color: Color(0xFF92400E),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Offline. Showing your cached data.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF92400E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
