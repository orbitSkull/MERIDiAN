import 'dart:async';

import 'package:dio/dio.dart';

import '../models/settings.dart';
import '../models/user.dart';
import 'api_config.dart';
import 'meridian_api.dart';
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
class ApiClient implements MeridianApi {
  ApiClient({required this.tokens, Dio? dio, String? baseUrl})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: '${baseUrl ?? ApiConfig.baseUrl}${ApiConfig.prefix}',
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'Accept': 'application/json'},
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: _onRequest, onError: _onError),
    );
  }

  final Dio _dio;
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

    return ApiException(
      switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          'The server took too long to respond. Check your connection.',
        DioExceptionType.connectionError =>
          'Cannot reach the server. Check your connection.',
        _ => 'Something went wrong. Please try again.',
      },
      statusCode: statusCode,
    );
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
    final response = await _guard(() => _dio.post<Map<String, dynamic>>(
      '/auth/login',
      data: {
        'college_code': collegeCode,
        'identifier': ?identifier,
        'password': ?password,
        'moderator_key': ?moderatorKey,
      },
    ));
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
    final response = await _guard(() => _dio.post<Map<String, dynamic>>(
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
    ));
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
    final response = await _guard(
      () => _dio.get<List<dynamic>>('/me/blocks'),
    );
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
      throw ApiException('Empty response from $path', statusCode: response.statusCode);
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
