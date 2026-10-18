import 'chat_models.dart';

/// The device's own record of conversations and messages.
///
/// An interface rather than a direct dependency on sqflite for the same reason
/// `MeridianApi` is one: the sync engine and the outbox are where the behaviour
/// worth testing lives, and neither should need a native plugin to be exercised.
/// `SqliteChatStore` is the production implementation; `InMemoryChatStore` in
/// test/support is the other.
///
/// The rule this interface exists to enforce is that it has no delete that
/// follows from a server response. Nothing the server sends removes a local row.
/// Retention is why: the server drops messages after 28 days and is expected to,
/// and a device that deleted its copy whenever the server stopped listing it
/// would be empty a month later.
abstract class ChatStore {
  Future<void> open();

  Future<List<ConversationSummary>> conversations();

  Future<ConversationSummary?> conversation(int id);

  Future<List<ChatMessage>> messages(
    int conversationId, {
    int limit = 50,
    int? beforeSeq,
  });

  Future<ChatMessage?> messageByClientId(String clientId);

  /// Insert or update by server id. A row whose body the server can no longer
  /// serve is written with [ChatMessage.expired] set and an empty body, so the
  /// thread keeps its shape.
  Future<void> upsertMessages(List<ChatMessage> messages);

  Future<void> upsertConversations(List<ConversationSummary> conversations);

  /// Move a local message to its acknowledged state once the server has it.
  Future<void> markSent({
    required String clientId,
    required int id,
    required int seq,
    required MessageSendState state,
  });

  /// Record a send that failed, so the bubble can offer a retry.
  Future<void> markFailed({
    required String clientId,
    required String reason,
  });

  /// Wipe everything. Used on sign-out: another person's messages must not be
  /// readable by whoever signs in next on the same device.
  Future<void> clear();
}

/// The queue of messages that have not reached the server yet.
///
/// Separate from [ChatStore] because it has a different lifecycle: it is written
/// to on every send, read on every flush, and its rows carry retry state. Faking
/// it independently keeps the flush tests from needing message storage at all.
abstract class Outbox {
  Future<void> add(OutboxEntry entry);

  /// Entries whose backoff has elapsed, oldest first.
  Future<List<OutboxEntry>> due(DateTime now, {int limit = 20});

  Future<OutboxEntry?> byClientId(String clientId);

  /// The server took it. The row goes and the message is now a normal one.
  Future<void> resolve(String clientId);

  /// The server refused it or it could not be sent. Records the attempt count
  /// and when to try again.
  Future<void> defer(String clientId, {required String error, required DateTime nextAttemptAt});

  /// Drop the entry but keep the message, marked failed. Only for something
  /// permanent, like being blocked, where retrying forever is pointless.
  Future<void> abandon(String clientId);

  Future<int> count();

  Future<void> clear();
}