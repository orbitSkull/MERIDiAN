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
}
