import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../data/chat_models.dart';
import '../models/settings.dart';
import '../models/user.dart';
import 'api_config.dart';
import 'connectivity_monitor.dart';
import 'meridian_api.dart';
import 'realtime_client.dart';
import 'token_store.dart';

/// Why a refresh attempt ended.
///
/// The distinction between [rejected] and [unreachable] matters: treating a
/// dropped connection as a rejection would permanently destroy a valid
/// session.
enum RefreshOutcome {
  /// New tokens issued.
  success,

  /// The server refused the refresh token. The session is genuinely over.
  rejected,

  /// No refresh token stored, so there is nothing to try.
  noCredentials,

  /// Could not reach the server. Try again later; tokens stay valid.
  unreachable,
}

/// Outcome of a refresh attempt.
class RefreshResult {
  const RefreshResult._(this.outcome, {this.pair});

  final RefreshOutcome outcome;
  final TokenPair? pair;
}

/// Thrown for any API error, carrying a message safe to show the user.
class ApiException implements Exception {
  final String message;
  final int? statusCode;

  const ApiException(this.message, {this.statusCode});

  bool get isUnauthorized => statusCode == 401;

  bool get isRateLimited => statusCode == 429;

  /// True when the request never reached the server, as opposed to being
  /// rejected by it. Callers use this to keep the user signed in offline.
  bool get isOffline =>
      statusCode == null &&
      (message.contains('Cannot reach the server') ||
          message.contains('too long to respond'));

  @override
  String toString() => message;
}

/// HTTP client for the MERIDiAN API.
///
/// Attaches the access token to every request and, on a 401, refreshes once
/// and replays the original request. That is what lets the app start straight
/// into the home screen on later launches instead of showing the login page.
class ApiClient implements MeridianApi, RealtimeCredentials {
  ApiClient({required this.tokens, Dio? dio, String? baseUrl})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: '${baseUrl ?? ApiConfig.baseUrl}${ApiConfig.prefix}',
              // Generous, because the API is on a free tier that sleeps after
              // about fifteen minutes idle and then needs up to a minute to wake.
              // A 10 second connect timeout gave up while the instance was still
              // booting, so a cold start reported as "taking too long to
              // respond" rather than as a slow success.
              //
              // The cost of these numbers is a spinner that lingers instead of a
              // fast failure. That is the right trade for an endpoint that is
              // genuinely coming back, and the offline banner still appears when
              // the device genuinely has no route to the server.
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 30),
              headers: {'Accept': 'application/json'},
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: _onRequest,
        onError: _onError,
        // The only trustworthy signal that a network is available is a request
        // that came back. Announced on both paths so "offline" clears the moment
        // one request succeeds, rather than needing a separate probe that would
        // cost a round trip of its own.
        onResponse: (_, _) => _connectivity?.report(succeeded: true),
      ),
    );
  }

  /// Told about the outcome of every request. Null until something sets it.
  ConnectivityMonitor? _connectivity;

  void useConnectivityMonitor(ConnectivityMonitor monitor) =>
      _connectivity = monitor;

  final Dio _dio;

  /// Unauthenticated client, for fetching the bytes behind a signed URL.
  ///
  /// Separate from [_dio] so an account's access token can never be sent to
  /// whatever host serves the file.
  late final Dio _bare = Dio();
  final TokenStore tokens;

  /// Called when the session can no longer be recovered.
  void Function()? onSessionExpired;

  String? _accessToken;

  /// Guards against a burst of parallel 401s each firing their own refresh.
  Future<RefreshResult>? _inFlightRefresh;

  /// Marks a request as already having been retried after a refresh.
  static const String _retryFlag = 'meridian_auth_retry';

  Future<void> loadAccessToken() async {
    _accessToken = await tokens.readAccessToken();
  }

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = _accessToken ?? await tokens.readAccessToken();
    _accessToken = token;
    // Never attach credentials to the refresh call itself.
    if (token != null && !options.path.contains('/auth/refresh')) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  /// Handles a 401 by refreshing once and replaying the original request.
  ///
  /// Dio's error chain carries [DioException], so the original error is always
  /// forwarded; translation into [ApiException] happens in [_guard].
  Future<void> _onError(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final response = error.response;
    final request = error.requestOptions;

    // A 4xx means the network worked and the server said no. Reporting that as
    // "offline" would grey out the send button because somebody mistyped their
    // password once.
    if (error.type != DioExceptionType.connectionError &&
        error.type != DioExceptionType.connectionTimeout &&
        error.type != DioExceptionType.receiveTimeout &&
        error.type != DioExceptionType.sendTimeout &&
        error.type != DioExceptionType.unknown) {
      _connectivity?.report(succeeded: true);
    } else {
      _connectivity?.report(succeeded: false);
    }

    // A request may be retried at most once. Without this guard, a server that
    // keeps answering 401 even with a freshly issued token (a suspended
    // account, say) makes refresh -> replay -> 401 -> refresh spin forever.
    final alreadyRetried = request.extra[_retryFlag] == true;

    final shouldRetry =
        response?.statusCode == 401 &&
        _accessToken != null &&
        !alreadyRetried &&
        !request.path.contains('/auth/refresh') &&
        !request.path.contains('/auth/login');

    if (!shouldRetry) {
      handler.next(error);
      return;
    }

    final result = await _refreshOnce();
    switch (result.outcome) {
      case RefreshOutcome.success:
        break;

      case RefreshOutcome.rejected:
        // The server refused the refresh token. The session is genuinely dead.
        await _endSession();
        handler.next(error);
        return;

      case RefreshOutcome.noCredentials:
        await _endSession();
        handler.next(error);
        return;

      case RefreshOutcome.unreachable:
        // Never destroy a valid session because the network dropped. Tokens
        // stay so the next launch can recover once connectivity returns.
        handler.next(error);
        return;
    }

    try {
      final pair = result.pair!;
      _accessToken = pair.accessToken;
      request.extra[_retryFlag] = true;
      request.headers['Authorization'] = 'Bearer ${pair.accessToken}';
      handler.resolve(await _dio.fetch<dynamic>(request));
    } on DioException catch (e) {
      // A retry that fails to reach the server is likewise not proof that the
      // session is invalid.
      if (e.response?.statusCode == 401) await _endSession();
      handler.next(e);
    }
  }

  /// Single-flight refresh: concurrent callers share one in-flight request.
  Future<RefreshResult> _refreshOnce() {
    return _inFlightRefresh ??= _performRefresh().whenComplete(() {
      _inFlightRefresh = null;
    });
  }

  /// Attempt a silent refresh with the stored refresh token.
  ///
  /// Returns false when the refresh token is missing or the server rejected
  /// it. Does *not* clear tokens; callers decide that.
  /// The access token for a WebSocket handshake.
  ///
  /// Separate from [loadAccessToken] because a socket cannot go through the
  /// request interceptor that transparently refreshes an expired token -- the
  /// handshake is not a request. So the socket asks here, and on rejection comes
  /// back through [tryRefresh] rather than refreshing on a timer it does not
  /// need.
  ///
  /// Null when nobody is signed in, which the socket treats as "there is
  /// nothing to connect to" rather than as an error to retry.
  @override
  Future<String?> accessTokenForSocket() async {
    await loadAccessToken();
    return _accessToken;
  }
  @override
  Future<bool> tryRefresh() async {
    final result = await _refreshOnce();
    if (result.outcome != RefreshOutcome.success) return false;
    _accessToken = result.pair?.accessToken;
    return true;
  }

  Future<RefreshResult> _performRefresh() async {
    final refreshToken = await tokens.readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      return const RefreshResult._(RefreshOutcome.noCredentials);
    }

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      final body = response.data;
      if (body == null) {
        return const RefreshResult._(RefreshOutcome.rejected);
      }
      final pair = TokenPair.fromJson(body);
      await tokens.save(
        accessToken: pair.accessToken,
        refreshToken: pair.refreshToken,
      );
      return RefreshResult._(RefreshOutcome.success, pair: pair);
    } on DioException catch (e) {
      // Distinguish "the server said no" from "we could not reach the server".
      // Collapsing these two would delete a valid session on a dropped packet.
      final status = e.response?.statusCode;
      if (status == null) {
        return const RefreshResult._(RefreshOutcome.unreachable);
      }
      if (status == 401 || status == 403) {
        return const RefreshResult._(RefreshOutcome.rejected);
      }
      return const RefreshResult._(RefreshOutcome.unreachable);
    }
  }

  Future<void> _endSession() async {
    _accessToken = null;
    await tokens.clear();
    onSessionExpired?.call();
  }

  ApiException _toApiException(DioException error) {
    final statusCode = error.response?.statusCode;
    final data = error.response?.data;

    if (data is Map && data['detail'] != null) {
      return ApiException(data['detail'].toString(), statusCode: statusCode);
    }

    return ApiException(switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        'The server took too long to respond. Check your connection.',
      DioExceptionType.connectionError =>
        'Cannot reach the server. Check your connection.',
      _ => 'Something went wrong. Please try again.',
    }, statusCode: statusCode);
  }

  // ---------------------------------------------------------------------
  // Auth endpoints
  // ---------------------------------------------------------------------

  Future<TokenPair> login({
    required String collegeCode,
    String? identifier,
    String? password,
    String? moderatorKey,
  }) async {
    final response = await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: {
          'college_code': collegeCode,
          'identifier': ?identifier,
          'password': ?password,
          'moderator_key': ?moderatorKey,
        },
      ),
    );
    final body = response.data!;
    final pair = TokenPair.fromJson(body);
    await tokens.save(
      accessToken: pair.accessToken,
      refreshToken: pair.refreshToken,
    );
    _accessToken = pair.accessToken;
    return pair;
  }

  Future<UserProfile> register({
    required String collegeCode,
    required String role,
    required String firstName,
    required String surname,
    String? prn,
    String? empId,
    required String password,
  }) async {
    final response = await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/auth/register',
        data: {
          'college_code': collegeCode,
          'role': role,
          'first_name': firstName,
          'surname': surname,
          'prn': ?prn,
          'emp_id': ?empId,
          'password': password,
        },
      ),
    );
    return UserProfile.fromJson(response.data!);
  }

  @override
  Future<UserProfile> me() async {
    await loadAccessToken();
    // `/me`, not `/auth/me`. Both need a session, but only this one carries the
    // handle, display name, bio, avatar and verification flag, so reading the
    // richer endpoint saves a second request from every settings screen.
    final response = await _guard(() => _dio.get<Map<String, dynamic>>('/me'));
    return UserProfile.fromJson(response.data!);
  }

  @override
  Future<UserProfile> updateProfile({
    String? displayName,
    String? bio,
    String? avatarUrl,
    String? email,
  }) async {
    await loadAccessToken();
    // Only the keys the caller actually named. The endpoint is partial, and
    // sending the rest would blank anything the server has that this screen does
    // not know about.
    final data = <String, dynamic>{
      'display_name': ?displayName,
      'bio': ?bio,
      'avatar_url': ?avatarUrl,
      'email': ?email,
    };
    final response = await _guard(
      () => _dio.patch<Map<String, dynamic>>('/me', data: data),
    );
    return UserProfile.fromJson(response.data!);
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await loadAccessToken();
    await _guard(
      () => _dio.post<void>(
        '/me/password',
        data: {
          'current_password': currentPassword,
          'new_password': newPassword,
        },
      ),
    );
  }

  @override
  Future<List<DeviceSession>> sessions() async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.get<List<dynamic>>('/me/sessions'),
    );
    return (response.data ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(DeviceSession.fromJson)
        .toList();
  }

  @override
  Future<void> revokeSession(int sessionId) async {
    await loadAccessToken();
    await _guard(() => _dio.delete<void>('/me/sessions/$sessionId'));
  }

  @override
  Future<void> revokeOtherSessions() async {
    await loadAccessToken();
    await _guard(() => _dio.post<void>('/me/sessions/revoke-others'));
  }

  @override
  Future<List<BlockedUser>> blockedUsers() async {
    await loadAccessToken();
    final response = await _guard(() => _dio.get<List<dynamic>>('/me/blocks'));
    return (response.data ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(BlockedUser.fromJson)
        .toList();
  }

  @override
  Future<List<BlockedUser>> block(String username, {String? reason}) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.post<List<dynamic>>(
        '/me/blocks',
        data: {
          'username': username,
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        },
      ),
    );
    return (response.data ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(BlockedUser.fromJson)
        .toList();
  }

  @override
  Future<void> unblock(String username) async {
    await loadAccessToken();
    await _guard(() => _dio.delete<void>('/me/blocks/$username'));
  }

  @override
  Future<UserPreferences> preferences() async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.get<Map<String, dynamic>>('/me/settings'),
    );
    return UserPreferences.fromJson(response.data!);
  }

  @override
  Future<UserPreferences> updatePreferences(Map<String, bool> changes) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.patch<Map<String, dynamic>>('/me/settings', data: changes),
    );
    return UserPreferences.fromJson(response.data!);
  }

  @override
  Future<String> saveUsername(String username) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.patch<Map<String, dynamic>>(
        '/users/username',
        data: {'username': username},
      ),
    );
    // The endpoint answers with the handle it settled on rather than an
    // echo, so the caller stores what the server has rather than what it asked
    // for.
    return response.data?['username'] as String? ?? username;
  }

  @override
  Future<UserLookup> lookupUser(String username) async {
    await loadAccessToken();
    // Path-encoded: handles may contain dots and underscores, and a raw one
    // would be fine, but a stray slash from a pasted value would change the
    // path rather than being looked up.
    final response = await _guard(
      () => _dio.get<Map<String, dynamic>>(
        '/users/by-username/${Uri.encodeComponent(username.trim().toLowerCase())}',
      ),
    );
    final data = response.data;
    if (data == null) return UserLookup.notFound;
    return UserLookup.fromJson(data);
  }

  @override
  Future<UserSearch> searchUsers(String query) async {
    await loadAccessToken();
    final trimmed = query.trim().toLowerCase();
    final response = await _guard(
      () => _dio.get<Map<String, dynamic>>(
        '/users/search',
        queryParameters: {'q': trimmed},
      ),
    );
    final data = response.data;
    if (data == null) return UserSearch.empty;
    return UserSearch.fromJson(data);
  }

  // ------------------------------------------------------------------
  // messaging

  @override
  Future<List<ConversationSummary>> conversations() async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.get<List<dynamic>>('/conversations'),
    );
    final data = response.data;
    if (data == null) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(ConversationSummary.fromJson)
        .toList();
  }

  @override
  Future<ChatPage> messages(
    int conversationId, {
    int? beforeSeq,
    int limit = 50,
  }) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.get<Map<String, dynamic>>(
        '/conversations/$conversationId/messages',
        queryParameters: {
          'before_id': ?beforeSeq,
          'limit': limit,
        },
      ),
    );
    final data = response.data;
    if (data == null) return const ChatPage(messages: [], hasMore: false, newestSeq: 0);
    final rows = (data['messages'] as List<dynamic>? ?? const []);
    return ChatPage(
      messages: rows
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList(),
      hasMore: (data['has_more'] as bool?) ?? false,
      newestSeq: (data['newest_seq'] as int?) ?? 0,
    );
  }

  @override
  Future<ChatMessage> sendMessage(
    int conversationId, {
    required String clientId,
    required String body,
    int? attachmentId,
  }) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/conversations/$conversationId/messages',
        data: {
          'client_id': clientId,
          'body': body,
          // Null is omitted rather than sent as null, because the field is
          // extra="forbid" on the server and an explicit null is not the same as
          // leaving it out.
          'attachment_id': ?attachmentId,
        },
      ),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException('Empty response sending a message');
    }
    return ChatMessage.fromJson(data);
  }

  @override
  Future<ConversationSummary> openDirect(int otherUserId) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/conversations/direct',
        queryParameters: {'other_id': otherUserId},
      ),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException('Empty response opening a conversation');
    }
    return ConversationSummary.fromJson(data);
  }

  @override
  Future<void> markDelivered(int conversationId, int upToSeq) async {
    await loadAccessToken();
    await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/conversations/$conversationId/delivered',
        data: {'up_to_seq': upToSeq},
      ),
    );
  }

  @override
  Future<void> markRead(int conversationId, int upToSeq) async {
    await loadAccessToken();
    await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/conversations/$conversationId/read',
        data: {'up_to_seq': upToSeq},
      ),
    );
  }

  @override
  Future<ConversationSummary> conversation(int conversationId) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.get<Map<String, dynamic>>('/conversations/$conversationId'),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException('Empty response loading a conversation');
    }
    return ConversationSummary.fromJson(data);
  }

  // ------------------------------------------------------------------
  // groups

  @override
  Future<ConversationSummary> createGroup({
    required String title,
    required List<int> memberIds,
  }) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/conversations/group',
        // Repeated query parameters rather than a JSON body, because the
        // endpoint was specified that way. The helper sends a list as one
        // `member_ids` per value, which is what FastAPI binds to list[int].
        queryParameters: {'title': title, 'member_ids': memberIds},
      ),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException('Empty response creating a group');
    }
    return ConversationSummary.fromJson(data);
  }

  @override
  Future<ConversationSummary> addMembers(
    int conversationId,
    List<int> userIds,
  ) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/conversations/$conversationId/members',
        data: {'user_ids': userIds},
      ),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException('Empty response adding people to a group');
    }
    return ConversationSummary.fromJson(data);
  }

  @override
  Future<void> leaveConversation(int conversationId) async {
    await loadAccessToken();
    await _guard(
      () => _dio.delete<void>('/conversations/$conversationId/members/me'),
    );
  }

  @override
  Future<ConversationSummary> renameGroup(
    int conversationId,
    String title,
  ) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.patch<Map<String, dynamic>>(
        '/conversations/$conversationId',
        data: {'title': title},
      ),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException('Empty response renaming a group');
    }
    return ConversationSummary.fromJson(data);
  }

  // ------------------------------------------------------------------
  // media

  @override
  Future<MediaUpload> uploadMedia({
    required List<int> bytes,
    required String mime,
    String filename = 'upload',
  }) async {
    await loadAccessToken();
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    final response = await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/media',
        data: form,
        options: Options(contentType: 'multipart/form-data'),
      ),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException('Empty response uploading a file');
    }
    return MediaUpload.fromJson(data);
  }

  @override
  Future<void> attachMedia({
    required int mediaId,
    required int messageId,
    required int conversationId,
  }) async {
    await loadAccessToken();
    await _guard(
      () => _dio.post<void>(
        '/media/$mediaId/attach',
        data: {'message_id': messageId, 'conversation_id': conversationId},
      ),
    );
  }

  @override
  Future<DeviceRegistration> registerDevice({
    required String pushToken,
    required String platform,
  }) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.post<Map<String, dynamic>>(
        '/devices',
        data: {'push_token': pushToken, 'platform': platform},
      ),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException('Empty response registering this device');
    }
    return DeviceRegistration.fromJson(data);
  }

  @override
  Future<Uint8List?> fetchBytes(String url) async {
    // A bare Dio rather than the authenticated one on purpose: the signed URL is
    // its own authorisation, and attaching the account's access token to a URL
    // that another service issued would leak that token to whoever serves the
    // file.
    final response = await _bare.get<List<int>>(url);
    final data = response.data;
    if (data == null || data.isEmpty) return null;
    return Uint8List.fromList(data);
  }

  @override
  Future<void> markDeviceSeen(int deviceId) async {
    await loadAccessToken();
    await _guard(() => _dio.post<void>('/devices/$deviceId/seen'));
  }

  @override
  Future<void> deleteDevice(int deviceId) async {
    await loadAccessToken();
    await _guard(() => _dio.delete<void>('/devices/$deviceId'));
  }

  @override
  Future<MediaLink> mediaLink(int mediaId) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.get<Map<String, dynamic>>('/media/$mediaId'),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException('Empty response asking for a file');
    }
    return MediaLink.fromJson(data);
  }

  /// GET a JSON object from the API.
  ///
  /// Exposed for endpoints that are not tied to a model, such as username
  /// availability, where the response is read field by field.
  ///
  /// Deliberately returns 200-aware data rather than throwing on 404: the
  /// username checker answers 200 for both outcomes, because a status code that
  /// differs between "free" and "taken" would leak what the body is trying to
  /// hide.
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    await loadAccessToken();
    final response = await _guard(
      () => _dio.get<Map<String, dynamic>>(path, queryParameters: query),
    );
    final data = response.data;
    if (data == null) {
      throw ApiException(
        'Empty response from $path',
        statusCode: response.statusCode,
      );
    }
    return data;
  }

  /// Best-effort server-side revocation. Never blocks the local logout.
  Future<void> logout() async {
    final refreshToken = await tokens.readRefreshToken();
    if (refreshToken != null) {
      try {
        await _dio.post<Map<String, dynamic>>(
          '/auth/logout',
          data: {'refresh_token': refreshToken},
        );
      } on DioException {
        // Offline logout still succeeds locally.
      }
    }
    await _endSession();
  }

  Future<Response<T>> _guard<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }
}
