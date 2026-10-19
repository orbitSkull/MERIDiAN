// The constructor takes public named arguments and assigns them to private fields,
// which the initializing-formals lint reads as a mistake.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/chat_models.dart';
import '../../data/chat_store.dart';
import '../../data/media_cache.dart';
import '../../services/api_client.dart';
import '../../services/chat_sync.dart';
import '../../services/meridian_api.dart';
import '../../services/outbox.dart';
import '../../services/realtime_client.dart';

/// Drives one conversation: what is on screen, and what happens when the user
/// types.
///
/// Reads from the [ChatStore] and writes to the [Outbox]. It never renders and
/// never touches a widget, which is what makes the behaviour testable without a
/// single `pumpWidget` — the interesting failures in a chat screen are ordering
/// and state transitions, not pixels.
///
/// **It also listens.** Without the socket subscription below, a message arriving
/// while somebody is looking at the conversation would be pushed by the server and
/// dropped by the client, and the whole realtime half of the feature would be a
/// server that talks to nobody.
class ConversationController extends ChangeNotifier {
  ConversationController({
    required this.conversationId,
    this.myUserId,
    required MeridianApi api,
    required ChatStore store,
    required Outbox outbox,
    required OutboxSender sender,
    required ChatSync sync,
    RealtimeClient? realtime,
    RealtimeApi? receipts,
  }) : _api = api,
       _store = store,
       _outbox = outbox,
       _sender = sender,
       _sync = sync,
       _realtime = realtime,
       _receipts = receipts ?? _RestReceipts(api);

  final int conversationId;

  /// Links to this conversation's files, remembered until they lapse.
  ///
  /// Per conversation rather than global, so opening one chat and closing it
  /// drops its links and the memory with them.
  late final MediaCache media = MediaCache(_api);

  /// The API, for the group screen's directory search.
  ///
  /// Exposed narrowly rather than by making the screen own its own client: a
  /// second client would be a second token store and a second idea about who is
  /// signed in.
  MeridianApi get apiForGroups => _api;

  /// The signed-in person, so their own typing notices are ignored rather than
  /// shown back to them as though somebody else were writing.
  final int? myUserId;
  final MeridianApi _api;
  final ChatStore _store;
  final Outbox _outbox;
  final OutboxSender _sender;
  final ChatSync _sync;
  final RealtimeClient? _realtime;
  final RealtimeApi _receipts;

  List<ChatMessage> _messages = const [];
  ConversationSummary? _conversation;
  bool _loadingOlder = false;
  bool _loading = true;
  bool _canLoadOlder = false;
  bool _syncing = false;
  String? _banner;
  bool _otherIsTyping = false;

  bool _disposed = false;

  StreamSubscription<RealtimeEvent>? _events;
  Timer? _typingTimeout;

  List<ChatMessage> get messages => _messages;
  ConversationSummary? get conversation => _conversation;
  bool get isLoading => _loading;
  bool get isLoadingOlder => _loadingOlder;
  bool get canLoadOlder => _canLoadOlder;
  bool get isSyncing => _syncing;
  String? get banner => _banner;

  /// Somebody is typing in this conversation, right now.
  ///
  /// Goes away on its own after a few seconds: the other side may close the app
  /// mid-word, and an indicator that stays lit forever looks broken rather than
  /// stale.
  bool get otherIsTyping => _otherIsTyping;

  bool get hasExpiredMessages => _messages.any((m) => m.expired);
  bool get hasFailedMessages => _messages.any(
    (m) => m.state == MessageSendState.failed,
  );
  int get pendingCount => _messages.where((m) => m.isPending).length;

  Future<void> open() async {
    _listen();
    _loading = true;
    _notify();
    await _reload();
    _loading = false;
    _notify();

    // Best effort: the conversation is already on screen from SQLite, so a
    // failure here is not an error to show, it is just not up to date yet.
    unawaited(refresh());
  }

  void _listen() {
    final realtime = _realtime;
    if (realtime == null || _events != null) return;

    _events = realtime.events.listen((event) {
      // Every handler is fire-and-forget: a socket event must never be able to
      // block the stream, and none of these is worth awaiting inside a listener.
      unawaited(_onRealtime(event));
    });
  }

  Future<void> _onRealtime(RealtimeEvent event) async {
    if (event is RealtimeMessage) {
      await _onMessage(event.data);
      return;
    }
    if (event is RealtimeReceipt) {
      if (event.conversationId != conversationId) return;
      await _store.applyReceipt(
        conversationId: conversationId,
        userId: event.userId,
        upToSeq: event.upToSeq,
        read: event.read,
      );
      await _reload();
      _notify();
      return;
    }
    if (event is RealtimeTyping) {
      if (event.conversationId != conversationId) return;
      if (myUserId != null && event.userId == myUserId) return;
      _typingTimeout?.cancel();
      if (event.typing) {
        _otherIsTyping = true;
        _typingTimeout = Timer(const Duration(seconds: 6), () {
          _otherIsTyping = false;
          _notify();
        });
        _notify();
      } else if (_otherIsTyping) {
        _otherIsTyping = false;
        _notify();
      }
    }
  }

  /// A message arrived while this conversation was open.
  Future<void> _onMessage(Map<String, dynamic> data) async {
    final message = ChatMessage.fromJson(data);
    if (message.conversationId != conversationId) return;

    await _store.upsertMessages([message]);
    await _reload();
    _notify();

    // Acknowledge receipt. This is the half that makes the double grey tick
    // exist: without it the message is on the phone but the server has no idea,
    // and the sender is told nothing until they happen to open the thread.
    await _acknowledgeDelivery();
  }

  /// Tell the server this device holds everything up to the newest sequence.
  ///
  /// Up to the newest thing in the loaded page, not the whole conversation: this
  /// runs because the conversation is open, and claiming receipt for messages
  /// the user has not looked at is a lie that shows up as double ticks on things
  /// they never scrolled to.
  Future<void> _acknowledgeDelivery() async {
    final newest = _messages
        .map((m) => m.seq ?? 0)
        .fold<int>(0, (a, b) => a > b ? a : b);
    if (newest == 0) return;
    try {
      await _receipts.markDelivered(conversationId, newest);
    } on ApiException {
      // Best effort. The tick will be right after the next sync, and failing to
      // record one is not worth interrupting anything for.
    }
  }

  Future<void> _reload() async {
    final loaded = await _store.messages(conversationId);
    _messages = loaded;
    _conversation ??= await _store.conversation(conversationId);
    // Fetched once, and only when the device has never seen it. Without this a
    // conversation opened straight after it was created -- before any sync has
    // written it to the conversations table -- has no kind, so the bubbles do
    // not know they are in a group and quietly print no sender names.
    _conversation ??= await _describeQuietly();
    // A full page means there may be more on this device; a short one means the
    // device has run out.
    //
    // This has to be derived, not merely updated when it is already true. It
    // previously only ever cleared the flag on a short page, which left it false
    // for a device holding exactly a page's worth of history -- so older messages
    // could never be fetched, by any route.
    _canLoadOlder = loaded.length >= ChatSync.pageSize;
  }

  /// One request for the conversation's own details, swallowing failure.
  ///
  /// Not allowed to throw: this runs on the path that draws the screen, and a
  /// conversation the server will not describe is still a conversation whose
  /// messages are sitting on the device and should be shown.
  Future<ConversationSummary?> _describeQuietly() async {
    try {
      return await _api.conversation(conversationId);
    } on Object {
      // Any failure at all. This sits on the path that draws the screen, and a
      // conversation the server will not describe is still a conversation whose
      // messages are sitting on the device and should be shown.
      //
      // Deliberately not narrowed to ApiException: the only thing this needs to
      // guarantee is that it cannot break the screen, and every extra type that
      // can arrive -- a stubbed client in a test, a platform channel, a
      // malformed response -- is the same failure for this purpose.
      return null;
    }
  }

  /// Pull the server's view, and send anything queued.
  Future<void> refresh() async {
    _syncing = true;
    _notify();
    try {
      await _sync.syncConversation(conversationId);
      await _sender.flush();
      await _markRead();
    } finally {
      _syncing = false;
      await _reload();
      _notify();
    }
  }

  /// Older messages.
  ///
  /// Reads from the device first and only asks the server for what the device
  /// does not have, in that order, because the device is the archive: scrolling
  /// back through history the user already downloaded must work with no
  /// network at all.
  Future<void> loadOlder() async {
    if (_loadingOlder || _messages.isEmpty) return;
    _loadingOlder = true;
    _notify();
    try {
      final oldestSeq = _messages.first.seq;

      if (oldestSeq != null) {
        final local = await _store.messages(
          conversationId,
          beforeSeq: oldestSeq,
          limit: ChatSync.pageSize,
        );
        if (local.isNotEmpty) {
          _messages = local;
          // A short page means the device has run out. A full one might not, so
          // the server gets asked to fill the gap.
          _canLoadOlder = local.length >= ChatSync.pageSize;
        }
      }

      if (_canLoadOlder && oldestSeq != null) {
        final outcome = await _sync.fetchOlder(
          conversationId,
          beforeSeq: oldestSeq,
        );
        // Whatever the server says wins, including "there is nothing older".
        _canLoadOlder = outcome.hasMore || outcome.stoppedEarly;
      }

      await _reload();
    } finally {
      _loadingOlder = false;
      _notify();
    }
  }

  Future<void> _markRead() async {
    final newest = _messages
        .map((m) => m.seq ?? 0)
        .fold<int>(0, (a, b) => a > b ? a : b);
    if (newest == 0) return;
    try {
      await _api.markRead(conversationId, newest);
    } on ApiException {
      // Read receipts are best effort. Failing to record one costs a stale tick
      // for the other person, which is not worth interrupting the user over.
    }
  }

  /// Send a message. Returns immediately; the bubble is already on screen.
  Future<void> send(String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    _banner = null;
    reportTyping(false);
    await _sender.send(conversationId, trimmed);
    await _reload();
    _notify();
    // Fire and forget: the send is recorded, and refresh() will pick up the
    // result when it lands.
    unawaited(refresh());
  }

  /// Tell the server this person is typing, or has stopped.
  void reportTyping(bool typing) {
    _realtime?.sendTyping(conversationId, typing: typing);
  }

  // ------------------------------------------------------------------
  // media

  /// Send a photograph, with an optional caption.
  ///
  /// Two requests: upload the bytes, then send the message naming the file. Not
  /// three -- there is no separate attach step, because the server binds them in
  /// one transaction and a client that does it in three has a window where the
  /// message exists and the picture does not.
  ///
  /// Deliberately not queued in the outbox. A queued send is a row of text and a
  /// client_id; this needs the bytes, and the picker has long since released the
  /// file handle by the time a phone that has been offline for an hour comes
  /// back. Pretending to queue it would mean copying every photograph onto the
  /// device's disk to retry later, so a media send needs a connection and says
  /// so plainly rather than pretending otherwise.
  ///
  /// Returns null on success, or a sentence fit to show the user.
  Future<String?> sendWithMedia({
    required List<int> bytes,
    required String mime,
    String filename = 'photo.jpg',
    String caption = '',
  }) async {
    try {
      final upload = await _api.uploadMedia(
        bytes: bytes,
        mime: mime,
        filename: filename,
      );
      // Straight through the API rather than the outbox, for the reason above.
      final message = await _api.sendMessage(
        conversationId,
        clientId: _newClientId(),
        body: caption.trim(),
        attachmentId: upload.id,
      );
      await _store.upsertMessages([message]);
      await _reload();
      _notify();
      unawaited(refresh());
      return null;
    } on ApiException catch (error) {
      if (error.statusCode == 413) {
        return 'That file is too large to send.';
      }
      if (error.statusCode == 415) {
        return 'That kind of file cannot be sent in a chat.';
      }
      if (error.statusCode == 410) {
        return 'That photo has expired.';
      }
      return error.message;
    }
  }

  /// A fresh idempotency key, from the same generator the outbox uses.
  static String _newClientId() => newClientId(Random());

  // ------------------------------------------------------------------
  // groups

  /// Who is in this conversation.
  ///
  /// Returns null when the caller is no longer a member, which happens for a
  /// real reason: somebody removed them, or they were the one who left and is
  /// still looking at the screen they left from. Both are handled by leaving the
  /// conversation rather than by showing an empty member list.
  Future<List<ConversationMember>?> loadMembers() async {
    try {
      final conversation = await _api.conversation(conversationId);
      _conversation = conversation;
      _notify();
      return conversation.members;
    } on ApiException catch (error) {
      // 404 and 403 both mean the same thing here: you are not in this room any
      // more. Anything else is worth leaving the roster alone for, rather than
      // replacing a good list with an error.
      if (error.statusCode == 404 || error.statusCode == 403) return null;
      rethrow;
    }
  }

  /// Put people into a group. Owner only.
  Future<void> addMembers(List<int> userIds) async {
    final conversation = await _api.addMembers(conversationId, userIds);
    _conversation = conversation;
    _notify();
  }

  /// Rename a group. Owner only.
  Future<void> rename(String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final conversation = await _api.renameGroup(conversationId, trimmed);
    _conversation = conversation;
    _notify();
  }

  /// Walk out of a conversation.
  ///
  /// The conversation is dropped from the store first and the server told
  /// afterwards. A leave that failed halfway should leave the chat gone from
  /// this device rather than leaving a conversation the person cannot send to
  /// and cannot tell apart from a broken one.
  Future<void> leave() async {
    await _store.removeConversation(conversationId);
    await _api.leaveConversation(conversationId);
  }

  /// Try a message that failed.
  Future<void> retry(ChatMessage message) async {
    if (!message.canRetry) return;

    // Re-queue the same client_id rather than generating a new one. The server
    // may well have accepted it already -- a lost response looks exactly like a
    // failure -- so reusing the id turns a possible duplicate into a no-op.
    await _outbox.add(
      OutboxEntry(
        clientId: message.clientId,
        conversationId: conversationId,
        body: message.body,
        createdAt: message.createdAt,
        attempts: 0,
        nextAttemptAt: DateTime.now(),
      ),
    );
    await _store.markSent(
      clientId: message.clientId,
      id: message.id ?? 0,
      seq: message.seq ?? 0,
      state: MessageSendState.sending,
    );
    await _reload();
    _notify();
    unawaited(refresh());
  }

  /// Drop a failed message from the device. The user's explicit choice.
  Future<void> discard(ChatMessage message) async {
    await _outbox.abandon(message.clientId);
    await _reload();
    _notify();
  }

  /// Feed one socket event straight in.
  ///
  /// For tests and previews, which have a [FakeRealtime] rather than a socket.
  /// Public so the preview harness can put the screen into a state nobody can
  /// reach without a second person -- somebody else typing -- and so it can be
  /// looked at.
  @visibleForTesting
  Future<void> debugReceive(RealtimeEvent event) => _onRealtime(event);

  /// Safe to call after [dispose].
  ///
  /// Not belt and braces. [open] ends with an unawaited refresh, and a user who
  /// taps back before that finishes disposes this controller while the refresh is
  /// still running -- which then calls notifyListeners on a dead notifier, and
  /// Flutter throws for exactly that. On a device that is "type a message, tap
  /// back quickly, crash", which is the most ordinary sequence in a chat app.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _typingTimeout?.cancel();
    unawaited(_events?.cancel());
    _events = null;
    super.dispose();
  }
}

/// Just the two calls the controller needs to acknowledge receipts.
///
/// Narrow on purpose: the controller's job here is deciding *what* to acknowledge
/// and *when*, and it should not need a whole API client to do it. It also keeps
/// the controller testable without a token store and a Dio instance.
abstract class RealtimeApi {
  Future<void> markDelivered(int conversationId, int upToSeq);
}

/// The real thing.
class _RestReceipts implements RealtimeApi {
  _RestReceipts(this._api);

  final MeridianApi _api;

  @override
  Future<void> markDelivered(int conversationId, int upToSeq) =>
      _api.markDelivered(conversationId, upToSeq);
}