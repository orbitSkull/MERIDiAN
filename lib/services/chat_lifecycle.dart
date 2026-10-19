import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_environment.dart';
import '../services/push_registration.dart';

/// Stops the live socket while the app is in the background.
///
/// A chat app that holds its WebSocket open while it is in a drawer is holding
/// a radio open for nothing: the operating system will keep the connection up
/// for minutes, burning battery, and the messages that arrive are ones nobody is
/// looking at -- and the phone that sends them sees an open socket, so it does
/// not send a notification either. The conversation only looks alive when it
/// cannot wake anybody.
///
/// Only [AppLifecycleState.paused] stops the socket, and that is the whole
/// subtlety here. [AppLifecycleState.inactive] fires for the notification
/// shade, a phone call, the app switcher, a permission dialog and the screen
/// locking -- several times an hour on an ordinary phone. Pausing on those would
/// mean a reconnect storm during exactly the moments somebody is checking
/// whether a message arrived.
///
/// Pausing also keeps the local store open. Opening SQLite is cheap and the file
/// is already there; the socket is what costs.
class ChatLifecycleObserver extends StatefulWidget {
  const ChatLifecycleObserver({super.key, required this.child});

  final Widget child;

  @override
  State<ChatLifecycleObserver> createState() => _ChatLifecycleObserverState();
}

class _ChatLifecycleObserverState extends State<ChatLifecycleObserver>
    with WidgetsBindingObserver {
  bool _backgrounded = false;
  bool _resuming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(_pause());
      case AppLifecycleState.resumed:
        unawaited(_resume());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _pause() async {
    if (_backgrounded) return;
    _backgrounded = true;
    await _withChat((chat) => chat.pause());
  }

  Future<void> _resume() async {
    if (!_backgrounded || _resuming) return;
    _resuming = true;
    _backgrounded = false;
    try {
      // Reconnect and catch up, then nudge anything listening so an open
      // conversation reflects what arrived while the phone was asleep.
      await _withChat((chat) => chat.resume());
      if (mounted) {
        context.read<PushRegistration>().markSeen();
      }
    } finally {
      _resuming = false;
    }
  }

  /// Runs [action] against the chat environment, if there is one.
  ///
  /// Swallows everything: this is driven by the OS, not by a person, so there
  /// is nobody to show an error to and a throw here would be an unhandled
  /// exception in a callback the framework does not check.
  Future<void> _withChat(Future<void> Function(ChatEnvironment) action) async {
    try {
      // Awaited, not fired and forgotten: without the await the try below only
      // covers the call itself, so every failure inside the action escapes as
      // an unhandled error in a callback the framework never checks.
      await action(context.read<ChatEnvironmentHolder>().environment);
    } on Object catch (error, stack) {
      debugPrint('Chat lifecycle: $error\n$stack');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}