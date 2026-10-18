import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/chat_store.dart';
import '../data/sqlite_chat_store.dart';
import 'chat_sync.dart';
import 'meridian_api.dart';
import 'outbox.dart';

/// Everything the chat screens need, built once.
///
/// One object rather than four parameters threaded through every screen,
/// because the screens should not care that the store is SQLite or that the
/// outbox and the store happen to be the same object. It also gives sign-out one
/// place to call, which matters: [clear] is the only thing standing between one
/// person's messages and whoever signs in next on the same device.
class ChatEnvironment {
  /// [store] and [outbox] are passed separately because Dart has no type that
  /// is both, and because tests inject an in-memory one that implements both.
  /// In production they are the same object: [SqliteChatStore] implements
  /// [ChatStore] and [Outbox] over one file, with the outbox in its own table.
  ChatEnvironment._({
    required MeridianApi api,
    required this.store,
    required this.outbox,
  }) : _api = api,
       sync = ChatSync(api: api, store: store);

  /// Production: one SQLite file serving both roles.
  factory ChatEnvironment.production({required MeridianApi api}) {
    final store = SqliteChatStore();
    return ChatEnvironment._(api: api, store: store, outbox: store);
  }

  /// For tests, where the store and outbox are an in-memory double.
  @visibleForTesting
  factory ChatEnvironment.forTesting({
    required MeridianApi api,
    required ChatStore store,
    required Outbox outbox,
  }) => ChatEnvironment._(api: api, store: store, outbox: outbox);

  final MeridianApi _api;
  final ChatStore store;
  final Outbox outbox;
  final ChatSync sync;

  Future<void> open() => store.open();

  /// An [OutboxSender] for whoever is signed in on this device.
  ///
  /// A factory rather than a single instance because the sender needs the user's
  /// id to label optimistic bubbles, and that changes with the session.
  OutboxSender senderFor(int userId, {Random? random, DateTime Function()? clock}) {
    return OutboxSender(
      api: _api,
      store: store,
      outbox: outbox,
      senderId: userId,
      random: random,
      clock: clock,
    );
  }

  /// Wipe everything. Called on sign-out.
  ///
  /// Not optional and not lazy: the alternative is the next person to sign in on
  /// this phone reading somebody else's conversations, which is the sort of bug
  /// that is found by the person it happens to.
  Future<void> clear() => store.clear();
}

/// Owns the app's [ChatEnvironment] and empties it when the session ends.
///
/// A holder rather than the environment itself so sign-out can rebuild it:
/// anything that captured the old store or sender would otherwise keep a handle
/// on a database full of the previous user's messages.
class ChatEnvironmentHolder extends ChangeNotifier {
  /// [build] is how the environment is made, both now and for the next session.
  ///
  /// One factory rather than one for the initial environment and a separate
  /// override for the replacement. Two code paths here means a test can end up
  /// exercising an initial environment it never seeded -- wiping a real database
  /// instead of its own double, and passing without proving anything.
  ChatEnvironmentHolder({
    required MeridianApi api,
    ChatEnvironment Function(MeridianApi api)? build,
  }) : _build = build ?? _defaultBuild,
       _environment = (build ?? _defaultBuild)(api);

  static ChatEnvironment _defaultBuild(MeridianApi api) =>
      ChatEnvironment.production(api: api);

  final ChatEnvironment Function(MeridianApi api) _build;

  ChatEnvironment _environment;

  ChatEnvironment get environment => _environment;

  /// Called when the session ends, with the client the next session will use.
  Future<void> handleSignOut(MeridianApi nextApi) async {
    await _environment.clear();
    _environment = _build(nextApi);
    notifyListeners();
  }
}