/// What the device believes about a conversation and the messages in it.
///
/// These are the device's own record. The server is a transport and a recent
/// history window, not the archive — retention deletes from the server after 28
/// days — so anything worth keeping has to live here, and nothing in this file
/// treats the server as the source of truth for a message that has already been
/// received.
library;

/// The five states a message can be in on this device.
///
/// Four of them are what a person recognises (sent, delivered, read). The fifth,
/// [sending], exists only locally: the device has accepted the message but the
/// server has not acknowledged it, and collapsing that into "sent" would show a
/// tick for something nobody can see yet.
///
/// [failed] is also local-only. The message is on the device and on no server,
/// and it is not going to arrive on its own — it needs the user, or a retry.
enum MessageSendState {
  sending,
  sent,
  delivered,
  read,
  failed;

  /// The server reports three booleans, not five names. These three are the
  /// server's vocabulary; [sending] and [failed] never come from it.
  static MessageSendState fromServer({
    required bool sent,
    required bool delivered,
    required bool read,
  }) {
    if (read) return MessageSendState.read;
    if (delivered) return MessageSendState.delivered;
    return MessageSendState.sent;
  }

  bool get isPending => this == MessageSendState.sending || this == MessageSendState.failed;

  /// Whether the user should be offered a retry.
  bool get canRetry => this == MessageSendState.failed;
}

/// One message, as this device holds it.
class ChatMessage {
  const ChatMessage({
    this.id,
    required this.conversationId,
    required this.clientId,
    this.seq,
    required this.body,
    required this.kind,
    required this.senderId,
    required this.createdAt,
    this.expiresAt,
    this.attachmentId,
    this.expired = false,
    this.attachmentExpired = false,
    this.state = MessageSendState.sent,
    this.failureReason,
  });

  /// Server id, or null while the message has not reached the server.
  final int? id;

  final int conversationId;

  /// Stable across retries, generated once on the device.
  ///
  /// This is the whole reason an outbox can retry safely: the server keys
  /// idempotency on it, so a send that actually succeeded but whose response was
  /// lost comes back as the same message rather than as a duplicate.
  final String clientId;

  /// Position within the conversation. Null until the server assigns one.
  final int? seq;

  final String body;
  final String kind;
  final int senderId;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final int? attachmentId;

  /// The server will not serve this body any more. The row stays so the thread
  /// can show a placeholder in the right place instead of a hole.
  final bool expired;

  /// There was an attachment and its bytes are gone. Distinct from
  /// [attachmentId] being null, which means there never was one.
  final bool attachmentExpired;

  final MessageSendState state;

  /// Why a send failed, for the retry affordance. Never shown verbatim as an
  /// error banner — it is a technical string, and a user cannot act on it.
  final String? failureReason;

  bool get isPending => state.isPending;
  bool get canRetry => state.canRetry;

  ChatMessage copyWith({
    int? id,
    int? seq,
    MessageSendState? state,
    String? body,
    bool? expired,
    bool? attachmentExpired,
    String? failureReason,
    bool clearFailure = false,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId,
      clientId: clientId,
      seq: seq ?? this.seq,
      body: body ?? this.body,
      kind: kind,
      senderId: senderId,
      createdAt: createdAt,
      expiresAt: expiresAt,
      attachmentId: attachmentId,
      expired: expired ?? this.expired,
      attachmentExpired: attachmentExpired ?? this.attachmentExpired,
      state: state ?? this.state,
      failureReason: clearFailure ? null : (failureReason ?? this.failureReason),
    );
  }

  /// Build from the server's message object.
  ///
  /// Written to fail loudly on the fields the device cannot do without —
  /// `client_id`, `seq`, `sender_id` — rather than to default them. A missing
  /// conversation_id would otherwise put a message in a conversation that does
  /// not exist, where nothing can ever display it, and the symptom is a chat
  /// that silently does not update.
  ///
  /// The optional ones are the ones the server may legitimately omit or null:
  /// an expired message has no body to send, and `attachment_id` is absent for
  /// a message with nothing attached.
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final delivery = json['delivery'];
    final deliveryMap = delivery is Map<String, dynamic> ? delivery : const <String, dynamic>{};

    return ChatMessage(
      id: json['id'] as int?,
      conversationId: json['conversation_id'] as int,
      clientId: json['client_id'] as String,
      seq: json['seq'] as int?,
      body: (json['body'] as String?) ?? '',
      kind: (json['kind'] as String?) ?? 'text',
      senderId: json['sender_id'] as int,
      createdAt: DateTime.parse(json['created_at'] as String),
      expiresAt: json['expires_at'] == null
          ? null
          : DateTime.parse(json['expires_at'] as String),
      attachmentId: json['attachment_id'] as int?,
      // Absent on older payloads, which is a server that predates the field
      // rather than an unexpired message, and false is the right default.
      expired: (json['expired'] as bool?) ?? false,
      attachmentExpired: (json['attachment_expired'] as bool?) ?? false,
      state: MessageSendState.fromServer(
        sent: deliveryMap['sent'] as bool? ?? true,
        delivered: deliveryMap['delivered'] as bool? ?? false,
        read: deliveryMap['read'] as bool? ?? false,
      ),
    );
  }
}

/// A conversation as the message list shows it.
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.kind,
    this.title,
    this.avatarUrl,
    this.lastSeq = 0,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.preview,
  });

  final int id;

  /// `direct` or `group`. A direct chat's title is the other person's name, so
  /// the server sends the resolved display value rather than the app guessing
  /// whose name to show.
  final String kind;

  final String? title;
  final String? avatarUrl;
  final int lastSeq;
  final DateTime? lastMessageAt;
  final int unreadCount;

  /// Last message body, or a placeholder description of it. Null in a
  /// conversation whose only message has expired, which is a different thing
  /// from an empty conversation.
  final String? preview;

  /// The server sends conversations with slightly different shapes: the direct
  /// endpoint returns the resolved display name, the list endpoint returns a
  /// summary. Both are handled here so a caller does not have to know which it
  /// called.
  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    // The list endpoint may omit `unread_count` for a conversation with no
    // unread messages rather than sending zero; both mean the same thing.
    final unread = json['unread_count'];
    return ConversationSummary(
      id: json['id'] as int,
      kind: (json['kind'] as String?) ?? 'direct',
      title: json['title'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      lastSeq: (json['last_seq'] as int?) ?? 0,
      lastMessageAt: json['last_message_at'] == null
          ? null
          : DateTime.parse(json['last_message_at'] as String),
      unreadCount: unread is int ? unread : 0,
      preview: json['preview'] as String?,
    );
  }
}

/// A message waiting to reach the server.
class OutboxEntry {
  const OutboxEntry({
    required this.clientId,
    required this.conversationId,
    required this.body,
    required this.createdAt,
    required this.attempts,
    required this.nextAttemptAt,
    this.lastError,
  });

  final String clientId;
  final int conversationId;
  final String body;
  final DateTime createdAt;

  /// How many times this has been tried. Drives the backoff.
  final int attempts;

  /// Not before this time. Without it a message retries in a tight loop the
  /// moment the app opens while still offline, which drains the battery and
  /// looks like the app is broken.
  final DateTime nextAttemptAt;

  final String? lastError;

  /// Give up and let the user decide.
  ///
  /// Twenty is about an hour and a half at the current backoff. Long enough
  /// that a phone in a lift comes back on its own, short enough that somebody
  /// who has genuinely lost signal for a day finds out instead of wondering.
  static const int maxAttempts = 20;

  bool get isExhausted => attempts >= maxAttempts;

  /// Exponential, capped.
  ///
  /// Five seconds doubling to five minutes. The first retry is quick because the
  /// most common failure is "the request went out as the tunnel did", and the
  /// cap matters because an uncapped doubling would push the twentieth attempt
  /// out past the point where the user still cares.
  static Duration backoffFor(int attempts) {
    if (attempts <= 0) return Duration.zero;
    final seconds = 5 * (1 << (attempts - 1).clamp(0, 10));
    return Duration(seconds: seconds.clamp(0, 300));
  }
}