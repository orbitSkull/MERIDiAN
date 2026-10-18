// The constructor takes public named arguments and assigns them to private fields,
// which the initializing-formals lint reads as a mistake.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/chat_models.dart';
import '../../data/chat_store.dart';
import '../../services/api_client.dart';
import '../../services/chat_sync.dart';
import '../../services/meridian_api.dart';
import '../../services/outbox.dart';

/// Drives one conversation: what is on screen, and what happens when the user
/// types.
///
/// Reads from the [ChatStore] and writes to the [Outbox]. It never renders and
/// never touches a widget, which is what makes the behaviour testable without a
/// single `pumpWidget` — the interesting failures in a chat screen are ordering
/// and state transitions, not pixels.
class ConversationController extends ChangeNotifier {
  ConversationController({
    required this.conversationId,
    required MeridianApi api,
    required ChatStore store,
    required Outbox outbox,
    required OutboxSender sender,
    required ChatSync sync,
  }) : _api = api,
       _store = store,
       _outbox = outbox,
       _sender = sender,
       _sync = sync;

  final int conversationId;
  final MeridianApi _api;
  final ChatStore _store;
  final Outbox _outbox;
  final OutboxSender _sender;
  final ChatSync _sync;

  List<ChatMessage> _messages = const [];
  ConversationSummary? _conversation;
  bool _loadingOlder = false;
  bool _loading = true;
  bool _canLoadOlder = false;
  bool _syncing = false;

  /// Set when a send has failed permanently, so the composer can explain itself
  /// rather than the user wondering why nothing happened.
  String? _banner;

  List<ChatMessage> get messages => _messages;
  ConversationSummary? get conversation => _conversation;
  bool get isLoading => _loading;
  bool get isLoadingOlder => _loadingOlder;
  bool get canLoadOlder => _canLoadOlder;
  bool get isSyncing => _syncing;
  String? get banner => _banner;

  bool get hasExpiredMessages => _messages.any((m) => m.expired);
  bool get hasFailedMessages => _messages.any((m) => m.state == MessageSendState.failed);
  int get pendingCount => _messages.where((m) => m.isPending).length;

  Future<void> open() async {
    _loading = true;
    notifyListeners();
    await _reload();
    _loading = false;
    notifyListeners();

    // Best effort: the conversation is already on screen from SQLite, so a
    // failure here is not an error to show, it is just not up to date yet.
    unawaited(refresh());
  }

  Future<void> _reload() async {
    final loaded = await _store.messages(conversationId);
    _messages = loaded;
    _conversation = await _store.conversation(conversationId);
    // A page's worth is the threshold: below it, this is the whole history.
    if (loaded.length < ChatSync.pageSize && _canLoadOlder) {
      final oldest = loaded.isEmpty ? null : loaded.first.seq;
      if (oldest != null) {
        final older = await _store.messages(
          conversationId,
          beforeSeq: oldest,
          limit: 1,
        );
        _canLoadOlder = older.isNotEmpty;
      }
    }
  }

  /// Pull the server's view, and send anything queued.
  Future<void> refresh() async {
    _syncing = true;
    notifyListeners();
    try {
      await _sync.syncConversation(conversationId);
      await _sender.flush();
      await _markRead();
    } finally {
      _syncing = false;
      await _reload();
      notifyListeners();
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
    notifyListeners();
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
      notifyListeners();
    }
  }

  Future<void> _markRead() async {
    final newest = _messages.map((m) => m.seq ?? 0).fold<int>(0, (a, b) => a > b ? a : b);
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
    await _sender.send(conversationId, trimmed);
    await _reload();
    notifyListeners();
    // Fire and forget: the send is recorded, and refresh() will pick up the
    // result when it lands.
    unawaited(refresh());
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
    notifyListeners();
    unawaited(refresh());
  }

  /// Drop a failed message from the device. The user's explicit choice.
  Future<void> discard(ChatMessage message) async {
    await _outbox.abandon(message.clientId);
    await _reload();
    notifyListeners();
  }
}