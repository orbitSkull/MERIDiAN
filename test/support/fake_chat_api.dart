import 'package:meridian/data/chat_models.dart';
import 'package:meridian/models/settings.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/meridian_api.dart';

/// A [MeridianApi] for the messaging endpoints, controllable from a test.
///
/// Paginated properly rather than by call count: the fake holds a flat list per
/// conversation and answers a `beforeSeq` cursor the way the server does. An
/// earlier version returned a different hand-loaded page per call, which meant
/// the sync engine's paging logic was never actually exercised — the fake
/// answered in order regardless of what cursor it was asked for, so a test
/// passed while the real client walked the thread backwards from the wrong
/// place.
class FakeChatApi implements MeridianApi {
  /// Everything the server "has", per conversation, in sequence order.
  final Map<int, List<ChatMessage>> server = {};

  List<ConversationSummary> conversationList = const [];

  /// The handler for a send. Set it per test.
  Future<ChatMessage> Function(int conversationId, String clientId, String body)?
  onSend;

  /// Throw from [messages] once this many calls have been made. 0 means never,
  /// so "fail on the second call" is expressible without a sequence of closures.
  int failMessagesAfterCalls = 0;

  /// Sent every time, even after the failure point, to model a flaky link
  /// rather than a switch that stays off.
  ApiException? messagesError;

  int sendCount = 0;
  final List<String> sendClientIds = [];
  final List<int> requestedBeforeSeqs = [];
  int messagesCalls = 0;
  final List<int> requestedConversations = [];

  /// Put messages in a conversation's server-side history.
  void seed(int conversationId, List<ChatMessage> messages) {
    final existing = server.putIfAbsent(conversationId, () => []);
    existing.addAll(messages);
    existing.sort((a, b) => (a.seq ?? 0).compareTo(b.seq ?? 0));
  }

  /// Drop everything the server has for a conversation, as retention does.
  ///
  /// A fresh growable list, not `const []`: a later [seed] after an expiry is
  /// exactly how a test sets up "the newest message arrived after the rest aged
  /// out", and seeding into a const list throws rather than testing anything.
  void expireAll(int conversationId) => server[conversationId] = <ChatMessage>[];

  @override
  Future<ChatPage> messages(
    int conversationId, {
    int? beforeSeq,
    int limit = 50,
  }) async {
    messagesCalls++;
    requestedBeforeSeqs.add(beforeSeq ?? 0);
    requestedConversations.add(conversationId);

    if (messagesCalls > failMessagesAfterCalls && messagesError != null) {
      throw messagesError!;
    }

    final all = server[conversationId] ?? const <ChatMessage>[];
    // The newest page: everything older than the cursor, and if there is no
    // cursor, the newest `limit` of everything.
    final older = all
        .where((m) => beforeSeq == null || (m.seq ?? 0) < beforeSeq)
        .toList();
    final start = older.length > limit ? older.length - limit : 0;
    final page = older.sublist(start);
    final hasMore = older.length > page.length;
    final newest = all.isEmpty
        ? 0
        : all.map((m) => m.seq ?? 0).reduce((a, b) => a > b ? a : b);

    return ChatPage(
      messages: page,
      hasMore: hasMore,
      newestSeq: newest,
    );
  }

  @override
  Future<ChatMessage> sendMessage(
    int conversationId, {
    required String clientId,
    required String body,
    int? attachmentId,
  }) {
    sendCount++;
    sendClientIds.add(clientId);
    final handler = onSend;
    if (handler == null) {
      return Future.value(
        serverMessage(
          id: sendCount,
          seq: sendCount,
          clientId: clientId,
          body: body,
          attachmentId: attachmentId,
        ),
      );
    }
    return handler(conversationId, clientId, body);
  }

  /// Thrown by [openDirect], to model being blocked or refused.
  ApiException? openDirectError;

  /// The user id passed to [openDirect] on the most recent call.
  int? openedDirectFor;

  /// What [searchUsers] returns.
  List<DirectoryUser> searchResults = const [];

  @override
  Future<ConversationSummary> openDirect(int otherUserId) async {
    openedDirectFor = otherUserId;
    final error = openDirectError;
    if (error != null) throw error;
    return ConversationSummary(id: 100 + otherUserId, kind: 'direct');
  }

  @override
  Future<UserSearch> searchUsers(String query) async {
    final needle = query.toLowerCase();
    return UserSearch(
      query: query,
      results: searchResults
          .where((u) => u.username.toLowerCase().contains(needle))
          .toList(),
    );
  }

  @override
  Future<List<ConversationSummary>> conversations() async => conversationList;

  @override
  Future<void> markRead(int conversationId, int upToSeq) async {}

  /// Files the "server" has stored, newest last.
  final List<MediaUpload> uploads = [];

  /// Set to make the next upload fail.
  ApiException? uploadError;

  @override
  Future<MediaUpload> uploadMedia({
    required List<int> bytes,
    required String mime,
    String filename = 'upload',
  }) async {
    final failure = uploadError;
    if (failure != null) throw failure;
    final upload = MediaUpload(
      id: uploads.length + 1,
      kind: 'image',
      mime: mime,
      byteSize: bytes.length,
      expiresAt: DateTime.utc(2026, 3, 8),
    );
    uploads.add(upload);
    return upload;
  }

  // Everything else is not messaging. Left unimplemented so a test that reaches
  // for one fails loudly instead of quietly getting null.

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeChatApi has no ${invocation.memberName}',
  );
}

/// A message as the server would return it.
ChatMessage serverMessage({
  required int id,
  required int seq,
  required String clientId,
  required String body,
  int? attachmentId,
  int conversationId = 1,
  int senderId = 7,
  MessageSendState state = MessageSendState.sent,
  bool expired = false,
  bool attachmentExpired = false,
}) {
  return ChatMessage(
    id: id,
    conversationId: conversationId,
    clientId: clientId,
    seq: seq,
    body: body,
    attachmentId: attachmentId,
    kind: attachmentId == null ? 'text' : 'media',
    senderId: senderId,
    createdAt: DateTime.utc(2026, 3, 1).add(Duration(seconds: seq)),
    expiresAt: DateTime.utc(2026, 3, 29),
    expired: expired,
    attachmentExpired: attachmentExpired,
    state: state,
  );
}