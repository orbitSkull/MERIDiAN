import '../data/chat_models.dart';
import '../models/settings.dart';
import '../models/user.dart';

/// Everything the settings screens need from the API.
///
/// An interface rather than a direct dependency on [ApiClient] so the widgets
/// can be tested without a Dio instance, a token store and a live server. The
/// alternative is passing a real client into every widget test and stubbing HTTP
/// underneath it, which tests the transport instead of the screen.
///
/// The production implementation is `ApiClient`, which `implements` this.
///
/// Nothing here throws [ApiClient]-specific types: errors arrive as
/// `ApiException`, because a screen has to render "you are offline" and "that
/// username is taken" differently and neither is a transport concern.
abstract class MeridianApi {
  /// The signed-in person's profile, including display name, bio and avatar.
  Future<UserProfile> me();

  /// Partial profile update. Null fields are left alone; an empty string clears.
  Future<UserProfile> updateProfile({
    String? displayName,
    String? bio,
    String? avatarUrl,
    String? email,
  });

  /// Change the password. Every session is revoked server side, including this
  /// one, so the caller must sign in again afterwards.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  });

  /// Devices signed in to this account.
  Future<List<DeviceSession>> sessions();

  /// Sign out one device.
  Future<void> revokeSession(int sessionId);

  /// Sign out every device except the one making the request.
  Future<void> revokeOtherSessions();

  /// People this account has blocked.
  Future<List<BlockedUser>> blockedUsers();

  /// Block someone by handle. Returns the resulting list.
  ///
  /// Always succeeds as far as the caller can tell: an unknown handle, yourself
  /// and an already-blocked person all give the same answer, so this cannot be
  /// used to find out who is registered.
  Future<List<BlockedUser>> block(String username, {String? reason});

  /// Unblock by handle. Unblocking someone who was not blocked also succeeds.
  Future<void> unblock(String username);

  /// The account's notification and privacy preferences.
  Future<UserPreferences> preferences();

  /// Partial preference update; only the keys present are written.
  Future<UserPreferences> updatePreferences(Map<String, bool> changes);

  /// Change the handle. Returns the handle the server settled on.
  Future<String> saveUsername(String username);

  /// Resolve an exact handle to the person behind it.
  ///
  /// Exact, not a prefix search. The lookup endpoint answers "no match" the same
  /// way for every miss on purpose, so this cannot be used to discover who is
  /// registered on the college.
  Future<UserLookup> lookupUser(String username);

  /// Find people whose handle matches [query] anywhere in it.
  ///
  /// Unlike [lookupUser] this *is* a directory: it needs a session, it is rate
  /// limited like the availability checker, the server refuses a query shorter
  /// than three characters, and the result carries a truncated flag because the
  /// server caps how many rows one search returns.
  Future<UserSearch> searchUsers(String query);

  // ------------------------------------------------------------------
  // messaging

  /// The signed-in person's conversations, newest activity first.
  Future<List<ConversationSummary>> conversations();

  /// One page of a conversation's messages, oldest first within the page.
  ///
  /// [beforeSeq] walks backwards. Null asks for the newest page, which is what
  /// a conversation opens on.
  Future<ChatPage> messages(int conversationId, {int? beforeSeq, int limit});

  /// Send, or return the message this [clientId] already made.
  ///
  /// [clientId] is generated once on the device and reused for every retry.
  /// That is what makes a retry safe: a send that succeeded but whose reply was
  /// lost comes back as the same message rather than as a duplicate.
  Future<ChatMessage> sendMessage(
    int conversationId, {
    required String clientId,
    required String body,
    int? attachmentId,
  });

  /// Open, or reopen, the direct conversation with somebody.
  Future<ConversationSummary> openDirect(int otherUserId);

  /// Tell the server how far this device has read. Cheap and idempotent.
  Future<void> markRead(int conversationId, int upToSeq);

  /// Tell the server this device holds these messages, without marking them
  /// read.
  ///
  /// Separate from [markRead] because they are different claims, and because
  /// this one is what makes the double grey tick mean anything: it is sent when
  /// a message arrives on a socket, and the sender is told immediately.
  Future<void> markDelivered(int conversationId, int upToSeq);

  /// One conversation in full, including the member roster.
  ///
  /// Separate from [conversations] because the roster is only worth fetching
  /// for the conversation actually on screen, and the list is the screen that
  /// must not wait on it.
  Future<ConversationSummary> conversation(int conversationId);

  // ------------------------------------------------------------------
  // groups

  /// Create a group with at least one other person.
  ///
  /// The owner is whoever creates it; ownership cannot be transferred or sold,
  /// so a group cannot end up with an owner nobody can replace.
  Future<ConversationSummary> createGroup({
    required String title,
    required List<int> memberIds,
  });

  /// Put people into a group. Owner only.
  ///
  /// Already-a-member ids are ignored rather than refused, so a retried add and
  /// a person who is already in both settle instead of raising an error dialog
  /// about something that is not wrong.
  Future<ConversationSummary> addMembers(
    int conversationId,
    List<int> userIds,
  );

  /// Leave a conversation.
  ///
  /// Permitted for the last person out of a direct conversation, which has no
  /// owner to hand it to: refusing would trap anybody who ever opened one.
  Future<void> leaveConversation(int conversationId);

  /// Rename a group. Owner only.
  Future<ConversationSummary> renameGroup(
    int conversationId,
    String title,
  );

  // ------------------------------------------------------------------
  // media

  /// Store a file and get back an id, without attaching it to anything yet.
  ///
  /// Uploaded first and attached later, so that picking four photographs and
  /// sending one does not leave three rows behind forever.
  Future<MediaUpload> uploadMedia({
    required List<int> bytes,
    required String mime,
    String filename,
  });

  /// Bind a stored file to a message that already exists.
  Future<void> attachMedia({
    required int mediaId,
    required int messageId,
    required int conversationId,
  });

  /// A short-lived link to a file, after checking the viewer is in the
  /// conversation the file belongs to.
  Future<MediaLink> mediaLink(int mediaId);
}

/// One page from [MeridianApi.messages].
class ChatPage {
  const ChatPage({
    required this.messages,
    required this.hasMore,
    required this.newestSeq,
  });

  final List<ChatMessage> messages;
  final bool hasMore;

  /// The highest sequence number in this page, or zero when it is empty.
  ///
  /// This is the catch-up cursor rather than the last id: ids are assigned by
  /// the database and sequence numbers by the conversation, so a device can ask
  /// "what is newer than this position" and be answered without scanning.
  final int newestSeq;
}
