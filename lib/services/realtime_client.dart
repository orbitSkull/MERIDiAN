// The constructor takes public named arguments and assigns them to private
// fields, which the initializing-formals lint reads as a mistake. Collapsing them
// would make the arguments private and force every caller to pass positionally.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_config.dart';

/// Something the server said.
@immutable
sealed class RealtimeEvent {
  const RealtimeEvent();
}

/// The socket is authenticated and open.
class RealtimeReady extends RealtimeEvent {
  const RealtimeReady(this.userId);
  final int userId;
}

/// Somebody sent a message in a conversation this person is in.
class RealtimeMessage extends RealtimeEvent {
  const RealtimeMessage(this.data);

  /// The server's MessageOut, still raw. Decoding is the store's business.
  final Map<String, dynamic> data;
}

/// Somebody's ticks moved.
class RealtimeReceipt extends RealtimeEvent {
  const RealtimeReceipt({
    required this.conversationId,
    required this.userId,
    required this.upToSeq,
    required this.read,
  });

  final int conversationId;
  final int userId;
  final int upToSeq;
  final bool read;
}

/// Somebody started or stopped typing.
class RealtimeTyping extends RealtimeEvent {
  const RealtimeTyping({
    required this.conversationId,
    required this.userId,
    required this.typing,
  });

  final int conversationId;
  final int userId;
  final bool typing;
}

/// The socket opened or closed. Not an error -- the app is offline all the time.
class RealtimeStatus extends RealtimeEvent {
  const RealtimeStatus({required this.connected, this.detail});

  final bool connected;

  /// Why it closed, when it is worth saying. Never shown raw to a user.
  final String? detail;
}

/// The socket could not be used and reconnecting alone will not help.
///
/// The one case that matters is a session the server will not accept, which is
/// not a transport problem at all.
class RealtimeFailure extends RealtimeEvent {
  const RealtimeFailure(this.detail);
  final String detail;
}

/// The two things a live connection does.
///
/// Narrower than [WebSocketChannel] on purpose. Depending on the package's
/// interface would mean every test had to implement its whole surface -- protocol
/// negotiation, header access, pipe, changeSink -- to exercise reconnect
/// behaviour, and most of that has nothing to do with reconnect behaviour. A
/// seam this size states exactly what the client actually uses.
abstract class RealtimeSocket {
  /// Frames from the server. Closes when the connection ends, for any reason.
  Stream<dynamic> get stream;

  void send(String text);

  Future<void> close();
}

/// The production seam, over `web_socket_channel`.
class _ChannelSocket implements RealtimeSocket {
  _ChannelSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close() => _channel.sink.close();
}

/// The two things the socket needs from whoever owns the session.
///
/// Narrower than [ApiClient] on purpose. The socket needs a token and the
/// ability to refresh one; it does not need the messaging endpoints, and typing it
/// as `ApiClient` would mean every caller had to supply a fully built HTTP
/// client -- or cast one, which throws at runtime the first time a test passes
/// something simpler.
abstract class RealtimeCredentials {
  /// A usable access token, or null when nobody is signed in.
  Future<String?> accessTokenForSocket();

  /// Get a new access token. False when the session itself has gone.
  Future<bool> tryRefresh();
}

/// Builds the socket for an endpoint.
typedef RealtimeSocketFactory = RealtimeSocket Function(Uri uri);

/// Opens, authenticates and keeps one socket alive.
///
/// **Reconnect is the normal case, not the exceptional one.** A phone locks, a
/// tunnel closes, and the hosted server sleeps after fifteen idle minutes and can
/// take a minute to wake. So the loop reconnects on its own with the same
/// exponential backoff and jitter the outbox uses, for the same reason: a hundred
/// devices that all lost signal in the same lift would otherwise all wake and
/// reconnect at the same instant.
///
/// **The token is refreshed only when the server says so.** An access token
/// lives fifteen minutes, so refreshing on a timer would be almost all waste.
/// A rejected handshake triggers one refresh and one immediate retry; only a
/// second rejection is treated as worth surfacing.
///
/// Not wired to app lifecycle here. A backgrounded app keeps its socket until the
/// OS takes it away, which wastes a little battery and is otherwise harmless.
/// Listening for `paused` is a refinement rather than a correctness problem.
class RealtimeClient {
  RealtimeClient({
    required RealtimeCredentials api,
    Random? random,
    Uri? endpoint,
    RealtimeSocketFactory? connect,
    Duration? handshakeTimeout,
  }) : _api = api,
       _random = random ?? Random(),
       _endpoint =
           endpoint ?? Uri.parse('${ApiConfig.wsBaseUrl}${ApiConfig.prefix}/ws'),
       _connect = connect ?? _openWebSocket,
       _handshakeTimeout = handshakeTimeout ?? const Duration(seconds: 10);

  static RealtimeSocket _openWebSocket(Uri uri) =>
      _ChannelSocket(WebSocketChannel.connect(uri));

  final RealtimeCredentials _api;
  final Random _random;
  final Uri _endpoint;
  final RealtimeSocketFactory _connect;
  final Duration _handshakeTimeout;

  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast();

  RealtimeSocket? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _typingTimer;
  Timer? _backoffTimer;
  Completer<void>? _pumpDone;

  bool _running = false;
  bool _connected = false;
  int _attempt = 0;
  int? _typingIn;

  Stream<RealtimeEvent> get events => _events.stream;
  bool get isConnected => _connected;

  /// Consecutive failed attempts. Exposed because "reconnecting, attempt 7" is
  /// the difference between a phone on a train and something actually broken.
  int get reconnectAttempts => _attempt;

  /// Open the socket and keep it open until [stop].
  void start() {
    if (_running) return;
    _running = true;
    print('[RealtimeClient] start() called');
    unawaited(_connectLoop());
  }

  Future<void> stop() async {
    _running = false;
    _typingTimer?.cancel();
    _typingTimer = null;
    // Wake the loop out of its backoff immediately rather than letting it sit
    // out the full delay with the socket it was about to open.
    _backoffTimer?.cancel();
    _backoffTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    // Cancelling a subscription does not fire onDone, so without this the pump
    // waits on a completer nothing will ever complete and the loop stays
    // suspended for the life of the process.
    final pump = _pumpDone;
    _pumpDone = null;
    if (pump != null && !pump.isCompleted) pump.complete();
    await _closeChannel();
    _connected = false;
  }

  /// Tell the server this person is typing, or has stopped.
  ///
  /// Throttled, because a client that reports on every keystroke reports dozens
  /// of times a second. The server throttles as well; this keeps the traffic
  /// from ever getting there.
  void sendTyping(int conversationId, {required bool typing}) {
    if (!_connected) return;

    if (!typing) {
      _typingTimer?.cancel();
      _typingTimer = null;
      _typingIn = null;
      _send({
        'type': 'typing',
        'conversation_id': conversationId,
        'typing': false,
      });
      return;
    }

    if (_typingIn == conversationId && _typingTimer?.isActive == true) return;
    _typingTimer?.cancel();
    _typingIn = conversationId;
    _send({
      'type': 'typing',
      'conversation_id': conversationId,
      'typing': true,
    });

    // A "stopped typing" after a pause, so the other person's indicator clears
    // even when nothing else is said.
    _typingTimer = Timer(const Duration(seconds: 6), () {
      _typingTimer = null;
      _typingIn = null;
      _send({
        'type': 'typing',
        'conversation_id': conversationId,
        'typing': false,
      });
    });
  }

  void _send(Map<String, dynamic> event) {
    try {
      _channel?.send(jsonEncode(event));
    } catch (_) {
      // The socket died between the check and the send. The close handler
      // reconnects; there is nothing useful to do about it here.
    }
  }

  Future<void> _connectLoop() async {
    while (_running) {
      print('[RealtimeClient] _connectLoop: attempting connection (attempt $_attempt)');
      final ok = await _attemptConnection();
      if (!_running) return;

      if (ok) {
        // Reset only after a connection that actually worked. Resetting on every
        // try would make a permanently broken socket reconnect instantly,
        // forever.
        _attempt = 0;
        await _pump();
        if (!_running) return;
      }

      // Cancellable, rather than Future.delayed.
      //
      // A plain delay cannot be interrupted, so stop() would return while the
      // loop was still asleep in it -- and then carry on and open another
      // socket after a signed-out person had said to stop. Worse, the wait runs
      // out its full thirty seconds regardless, which in a test means every
      // teardown pays the longest backoff.
      await _wait(_backoff(_attempt));
      if (!_running) return;
      _attempt++;
    }
  }

  /// Sleeps, but wakes immediately when [stop] is called.
  Future<void> _wait(Duration duration) {
    final wake = Completer<void>();
    _backoffTimer?.cancel();
    _backoffTimer = Timer(duration, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future;
  }

  /// Open and authenticate. True when the socket is ready to carry events.
  ///
  /// [mayRefresh] is what stops this recursing forever. A rejected handshake
  /// triggers one refresh and one retry; if that retry is rejected too, the
  /// cause is not a stale token, so it fails instead of refreshing again. A
  /// mutable flag cannot express that -- it is cleared before the retry, so the
  /// retry is treated as a first attempt and refreshes again, for as long as the
  /// server keeps saying no. Against a real server that is an unbounded refresh
  /// loop, and against a stub that always succeeds it never terminates at all.
  Future<bool> _attemptConnection({bool mayRefresh = true}) async {
    print('[RealtimeClient] _attemptConnection: getting token...');
    final token = await _api.accessTokenForSocket();
    print('[RealtimeClient] _attemptConnection: token=${token != null ? 'present' : 'null'}');
    if (token == null || token.isEmpty) {
      _events.add(
        const RealtimeFailure('Not signed in, so there is nothing to connect to.'),
      );
      return false;
    }

    try {
      print('[RealtimeClient] _attemptConnection: connecting to $_endpoint');
      final channel = _connect(_endpoint);
      _channel = channel;
      print('[RealtimeClient] _attemptConnection: sending auth');
      channel.send(jsonEncode({'type': 'auth', 'token': token}));

      final ready = await channel.stream
          .map(_decode)
          .where((event) => event != null)
          .cast<Map<String, dynamic>>()
          .first
          .timeout(_handshakeTimeout);

      if (ready['type'] != 'ready') {
        // Rejected. One refresh and one more try, because the usual cause is an
        // access token that aged out rather than a broken socket.
        if (mayRefresh) {
          final refreshed = await _api.tryRefresh();
          if (refreshed) {
            await _closeChannel();
            return _attemptConnection(mayRefresh: false);
          }
        }
        _events.add(
          const RealtimeFailure('The server would not accept this session.'),
        );
        await _closeChannel();
        return false;
      }

      _connected = true;
      print('[RealtimeClient] _attemptConnection: authenticated as user_id=${ready['user_id']}');
      _events.add(RealtimeReady((ready['user_id'] as num?)?.toInt() ?? 0));
      _events.add(const RealtimeStatus(connected: true));
      return true;
    } on TimeoutException {
      print('[RealtimeClient] _attemptConnection: timeout');
      await _closeChannel();
      return false;
    } catch (e) {
      print('[RealtimeClient] _attemptConnection: error=$e');
      await _closeChannel();
      return false;
    }
  }

/// Forward server events until the socket ends.
  Future<void> _pump() async {
    final channel = _channel;
    if (channel == null) return;

    final completer = Completer<void>();
    print('[RealtimeClient] _pump: starting to listen for events');
    _subscription = channel.stream.listen(
      (raw) {
        print('[RealtimeClient] _pump: raw event received: $raw');
        final event = _decode(raw);
        if (event == null) return;
        final translated = _translate(event);
        if (translated != null) {
          print('[RealtimeClient] _pump: translated event: ${translated.runtimeType}');
          _events.add(translated);
        }
      },
      onDone: () {
        print('[RealtimeClient] _pump: stream closed (onDone)');
        _connected = false;
        _events.add(const RealtimeStatus(connected: false, detail: 'closed'));
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e) {
        print('[RealtimeClient] _pump: stream error: $e');
        _connected = false;
        _events.add(const RealtimeStatus(connected: false, detail: 'failed'));
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );
    await completer.future;
    print('[RealtimeClient] _pump: completed');
  }

  Future<void> _closeChannel() async {
    final channel = _channel;
    _channel = null;
    try {
      await channel?.close();
    } catch (_) {
      // Already gone. Closing a dead socket is not a failure.
    }
  }

  /// Exponential with jitter, from one second to thirty.
  ///
  /// The ceiling sits above the hosted server's wake-up time on purpose: on the
  /// free tier a sleeping instance can take a minute to answer, so a shorter
  /// ceiling means reconnecting into a server that is not listening yet.
  Duration _backoff(int attempt) {
    final seconds = (1 << attempt.clamp(0, 5)).clamp(1, 30);
    final spread = (seconds * 0.3).round();
    final offset = spread == 0 ? 0 : _random.nextInt(spread * 2 + 1) - spread;
    return Duration(seconds: seconds + offset);
  }

  static Map<String, dynamic>? _decode(dynamic raw) {
    try {
      final decoded = jsonDecode(raw as String);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      // A frame we cannot parse is not worth tearing a connection down for.
      return null;
    }
  }

  static RealtimeEvent? _translate(Map<String, dynamic> event) {
    final type = event['type'];

    if (type == 'ready') {
      return RealtimeReady((event['user_id'] as num?)?.toInt() ?? 0);
    }

    if (type == 'message') {
      final data = event['data'];
      return data is Map<String, dynamic> ? RealtimeMessage(data) : null;
    }

    if (type == 'receipt' || type == 'typing') {
      final data = event['data'];
      if (data is! Map<String, dynamic>) return null;
      final conversationId = (data['conversation_id'] as num?)?.toInt() ?? 0;
      final userId = (data['user_id'] as num?)?.toInt() ?? 0;
      if (type == 'receipt') {
        return RealtimeReceipt(
          conversationId: conversationId,
          userId: userId,
          upToSeq: (data['up_to_seq'] as num?)?.toInt() ?? 0,
          read: data['read'] == true,
        );
      }
      return RealtimeTyping(
        conversationId: conversationId,
        userId: userId,
        typing: data['typing'] == true,
      );
    }

    if (type == 'error') {
      final data = event['data'];
      if (data is Map && data['detail'] != null) {
        return RealtimeFailure(data['detail'].toString());
      }
      return const RealtimeFailure('The server sent something unreadable.');
    }

    // `pong`, and anything newer than this build.
    return null;
  }

  void dispose() {
    unawaited(stop());
    unawaited(_events.close());
  }
}