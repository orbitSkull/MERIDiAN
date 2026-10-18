import 'package:meridian/data/chat_models.dart';
import 'package:meridian/data/chat_store.dart';

/// In-memory [ChatStore] and [Outbox], so the sync engine and the flush loop can
/// be tested without a native plugin.
///
/// Deliberately mirrors the real store's behaviour where it is load bearing, so
/// a test that passes here means something on a device:
///
/// * Upsert replaces on `clientId`, so an optimistic row is superseded by the
///   server's answer rather than sitting beside it.
/// * Local rows and server ids are separate, so a message without a server id
///   never collides with one that has one.
/// * Nothing a sync brings in removes a row.
class InMemoryChatStore implements ChatStore, Outbox {
  InMemoryChatStore({List<ChatMessage>? messages, List<ConversationSummary>? conversations})
    : _messages = [...?messages],
      _conversations = [...?conversations];

  final List<ChatMessage> _messages;
  final List<ConversationSummary> _conversations;
  final Map<String, OutboxEntry> _outbox = {};

  /// Local row ids, exactly as SQLite would assign them.
  int _nextRowId = 1;
  final Map<String, int> _rowIdByClientId = {};

  bool isOpen = false;
  int clearCount = 0;

  @override
  Future<void> open() async => isOpen = true;

  @override
  Future<List<ConversationSummary>> conversations() async {
    final sorted = [..._conversations]
      ..sort((a, b) {
        final at = a.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final byDate = bt.compareTo(at);
        return byDate != 0 ? byDate : b.id.compareTo(a.id);
      });
    return sorted;
  }

  @override
  Future<ConversationSummary?> conversation(int id) async {
    for (final conversation in _conversations) {
      if (conversation.id == id) return conversation;
    }
    return null;
  }

  @override
  Future<List<ChatMessage>> messages(
    int conversationId, {
    int limit = 50,
    int? beforeSeq,
  }) async {
    final inConversation = _messages.where((m) => m.conversationId == conversationId);
    final filtered = inConversation.where((m) {
      if (beforeSeq == null) return true;
      final seq = m.seq;
      // Mirrors `(seq IS NULL OR seq < ?)`: unsent messages are always newest.
      return seq == null || seq < beforeSeq;
    }).toList()
      ..sort((a, b) {
        final aseq = a.seq;
        final bseq = b.seq;
        if (aseq == null && bseq != null) return -1;
        if (aseq != null && bseq == null) return 1;
        if (aseq != null && bseq != null && aseq != bseq) return bseq.compareTo(aseq);
        final byDate = b.createdAt.compareTo(a.createdAt);
        if (byDate != 0) return byDate;
        return (_rowIdByClientId[b.clientId] ?? 0).compareTo(_rowIdByClientId[a.clientId] ?? 0);
      });
    return filtered.reversed.take(limit).toList();
  }

  @override
  Future<ChatMessage?> messageByClientId(String clientId) async {
    for (final message in _messages) {
      if (message.clientId == clientId) return message;
    }
    return null;
  }

  @override
  Future<void> upsertMessages(List<ChatMessage> incoming) async {
    for (final message in incoming) {
      final index = _messages.indexWhere((m) => m.clientId == message.clientId);
      if (index >= 0) {
        // Keep the row id, the way REPLACE-with-a-fresh-rowid would not.
        _messages[index] = message;
      } else {
        _rowIdByClientId[message.clientId] = _nextRowId++;
        _messages.add(message);
      }
    }
  }

  @override
  Future<void> upsertConversations(List<ConversationSummary> incoming) async {
    for (final conversation in incoming) {
      final index = _conversations.indexWhere((c) => c.id == conversation.id);
      if (index >= 0) {
        _conversations[index] = conversation;
      } else {
        _conversations.add(conversation);
      }
    }
  }

  @override
  Future<void> markSent({
    required String clientId,
    required int id,
    required int seq,
    required MessageSendState state,
  }) async {
    final index = _messages.indexWhere((m) => m.clientId == clientId);
    if (index < 0) return;
    _messages[index] = _messages[index].copyWith(id: id, seq: seq, state: state, clearFailure: true);
  }

  @override
  Future<void> markFailed({required String clientId, required String reason}) async {
    final index = _messages.indexWhere((m) => m.clientId == clientId);
    if (index < 0) return;
    _messages[index] = _messages[index].copyWith(
      state: MessageSendState.failed,
      failureReason: reason,
    );
  }

  @override
  Future<void> clear() async {
    clearCount++;
    _messages.clear();
    _conversations.clear();
    _outbox.clear();
  }

  // ------------------------------------------------------------------
  // outbox

  @override
  Future<void> add(OutboxEntry entry) async => _outbox[entry.clientId] = entry;

  @override
  Future<List<OutboxEntry>> due(DateTime now, {int limit = 20}) async {
    final entries = _outbox.values.where((e) => !e.nextAttemptAt.isAfter(now)).toList()
      ..sort((a, b) {
        final byNext = a.nextAttemptAt.compareTo(b.nextAttemptAt);
        return byNext != 0 ? byNext : a.createdAt.compareTo(b.createdAt);
      });
    return entries.take(limit).toList();
  }

  @override
  Future<OutboxEntry?> byClientId(String clientId) async => _outbox[clientId];

  @override
  Future<void> resolve(String clientId) async => _outbox.remove(clientId);

  @override
  Future<void> defer(
    String clientId, {
    required String error,
    required DateTime nextAttemptAt,
  }) async {
    final entry = _outbox[clientId];
    if (entry == null) return;
    _outbox[clientId] = OutboxEntry(
      clientId: entry.clientId,
      conversationId: entry.conversationId,
      body: entry.body,
      createdAt: entry.createdAt,
      attempts: entry.attempts + 1,
      nextAttemptAt: nextAttemptAt,
      lastError: error,
    );
  }

  @override
  Future<void> abandon(String clientId) async => _outbox.remove(clientId);

  @override
  Future<int> count() async => _outbox.length;

  // ------------------------------------------------------------------
  // test helpers

  /// Everything currently held, unsorted. For assertions about what survived.
  List<ChatMessage> get allMessages => [..._messages];
}