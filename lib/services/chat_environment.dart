import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/chat_store.dart';
import '../data/sqlite_chat_store.dart';
import 'api_client.dart';
import 'chat_sync.dart';
import 'meridian_api.dart';
import 'realtime_client.dart';
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
    required RealtimeCredentials credentials,
    required this.store,
    required this.outbox,
  }) : _api = api,
       realtime = RealtimeClient(api: credentials),
       sync = ChatSync(api: api, store: store);

  /// Production: one SQLite file serving both roles, and the real client.
  factory ChatEnvironment.production({required ApiClient api}) {
    final store = SqliteChatStore();
    return ChatEnvironment._(
      api: api,
      credentials: api,
      store: store,
      outbox: store,
    );
  }

  /// For tests, where the store and outbox are an in-memory double.
  ///
  /// [credentials] defaults to a stub with no token, so a test environment starts
  /// no socket at all rather than trying to reach a server that is not there.
  /// Tests that care about the socket pass their own.
  @visibleForTesting
  factory ChatEnvironment.forTesting({
    required MeridianApi api,
    required ChatStore store,
    required Outbox outbox,
    RealtimeCredentials? credentials,
  }) => ChatEnvironment._(
    api: api,
    credentials: credentials ?? const _NoCredentials(),
    store: store,
    outbox: outbox,
  );

  final MeridianApi _api;
  final ChatStore store;
  final Outbox outbox;
  final ChatSync sync;

  /// The live socket. Owned here rather than by a screen, so it survives
  /// navigating between conversations and so sign-out has one place to close it.
  final RealtimeClient realtime;

  /// The client the chat screens talk to.
  ///
  /// Exposed because opening a conversation is not a store operation and not a
  /// sync operation -- it is the one thing a chat screen does that has to reach
  /// the API directly, and the environment is what owns the client.
  MeridianApi get api => _api;

  /// Open the local store and start listening for live events.
  ///
  /// Both, together, because a socket writing into a store that is not open yet
  /// is a race nobody would notice until a message went missing.
  Future<void> open() async {
    print('[ChatEnvironment] open() called');
    await store.open();
    print('[ChatEnvironment] store opened, starting realtime');
    realtime.start();
    print('[ChatEnvironment] realtime.start() called');
  }

  /// Hold the socket while the app is in the background.
  ///
  /// Deliberately does *not* close the local store. Opening SQLite is cheap and
  /// the file is already on disk, whereas a socket that reconnects on every
  /// resume is what actually costs: each one is a WebSocket handshake, a token
  /// refresh check and a burst of catch-up, and a phone that goes in and out of
  /// a pocket does that dozens of times an hour for a socket nobody is reading.
  ///
  /// The store stays open throughout so that anything already on screen renders
  /// the same way it did a moment ago.
  Future<void> pause() => realtime.stop();

  /// Come back.
  ///
  /// Reconnects and then syncs, in that order. Reconnecting alone would leave
  /// the conversation list showing whatever was there when the phone went to
  /// sleep; the socket only delivers what happens *after* it is open, so
  /// anything sent while the app was away needs catching up explicitly.
  Future<void> resume() async {
    if (!store.isOpen) await store.open();
    realtime.start();
    await sync.syncAll();
  }

  /// Stop listening. Separate from [clear], which erases.
  ///
  /// They are called together on sign-out and nowhere else, but they are
  /// different operations: closing a socket is about this device's behaviour,
  /// wiping is about the next person's privacy.
  Future<void> disposeRealtime() async {
    await realtime.stop();
  }

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

/// Nobody is signed in, so there is nothing to connect with.
class _NoCredentials implements RealtimeCredentials {
  const _NoCredentials();

  @override
  Future<String?> accessTokenForSocket() async => null;

  @override
  Future<bool> tryRefresh() async => false;
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

  /// The production environment, over the real API client.
  ///
  /// Takes [ApiClient] rather than [MeridianApi] because the socket needs a
  /// token, and only the concrete client knows how to get and refresh one.
  static ChatEnvironment _defaultBuild(MeridianApi api) {
    if (api is! ApiClient) {
      // A test passing something narrower should use `build`, and saying so
      // beats a cast that throws three frames later during a socket connect.
      throw ArgumentError(
        'The default chat environment needs an ApiClient, because the live '
        'socket needs a token. Pass build: to supply a test environment.',
      );
    }
    return ChatEnvironment.production(api: api);
  }

  final ChatEnvironment Function(MeridianApi api) _build;

  ChatEnvironment _environment;

  ChatEnvironment get environment => _environment;

  /// Called when the session ends, with the client the next session will use.
  Future<void> handleSignOut(MeridianApi nextApi) async {
    // Close the socket *before* the wipe, not after: the event stream feeds the
    // store, so a live socket during the wipe would write somebody's messages
    // into a database being emptied underneath it.
    await _environment.disposeRealtime();
    await _environment.clear();
    _environment = _build(nextApi);
    notifyListeners();
  }
}