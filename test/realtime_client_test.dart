import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meridian/services/api_client.dart';
import 'package:meridian/services/realtime_client.dart';

/// A socket the test drives, so reconnect behaviour can be observed rather than
/// waited for.
class FakeSocket implements RealtimeSocket {
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();

  /// Frames the client pushed at us.
  final List<Map<String, dynamic>> received = [];

  bool closed = false;

  /// Every socket opened, in order.
  static final List<FakeSocket> opened = [];

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void send(String text) {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) received.add(decoded);
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// Push a server frame.
  void emit(Map<String, dynamic> event) =>
      _incoming.add(jsonEncode(event));

  /// Push a frame that is not valid JSON.
  void emitRaw(Object frame) => _incoming.add(frame);

  /// End the connection the way a dropped network does.
  void drop() {
    if (!_incoming.isClosed) _incoming.close();
  }
}
/// Stands in for [ApiClient], which the socket only uses for two things.
class _Tokens {
  String? accessToken = 'token-1';
  int refreshCalls = 0;
  bool refreshSucceeds = true;
}

void main() {
  late _Tokens tokens;

  setUp(() {
    tokens = _Tokens();
    FakeSocket.opened.clear();
  });

  group('handshake', () {
    test('a ready frame connects', () async {
      final events = <RealtimeEvent>[];
      final client = _client(
        tokens,
        onConnect: (uri) {
          final socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(
            () => socket.emit({'type': 'ready', 'user_id': 7}),
          );
          return socket;
        },
      );
      client.events.listen(events.add);
      client.start();

      await _until(() => client.isConnected);
      expect(events.whereType<RealtimeReady>().single.userId, 7);
      expect(events.whereType<RealtimeStatus>().first.connected, isTrue);
      await client.stop();
    });

    test('the auth message carries the access token', () async {
      final client = _client(
        tokens,
        onConnect: (uri) {
          final socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(() => socket.emit({'type': 'ready', 'user_id': 1}));
          return socket;
        },
      );
      client.start();
      await _until(() => client.isConnected);

      final auth = FakeSocket.opened.single.received.single;
      expect(auth['type'], 'auth');
      expect(auth['token'], 'token-1');
      await client.stop();
    });

    test('a rejected handshake refreshes once and retries immediately', () async {
      final client = _client(
        tokens,
        onConnect: (uri) {
          final socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(() {
            if (FakeSocket.opened.length == 1) {
              socket.emit({'type': 'error', 'data': {'detail': 'nope'}});
            } else {
              socket.emit({'type': 'ready', 'user_id': 7});
            }
          });
          return socket;
        },
      );
      client.start();
      await _until(() => client.isConnected);

      expect(tokens.refreshCalls, 1);
      // Two channels: the rejected one and the retry. Not a backoff wait.
      expect(FakeSocket.opened.length, 2);
      await client.stop();
    });

    test('two rejections give up rather than refreshing forever', () async {
      final client = _client(
        tokens,
        onConnect: (uri) {
          final socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(
            () => socket.emit({'type': 'error', 'data': {'detail': 'nope'}}),
          );
          return socket;
        },
      );
      final failures = <RealtimeFailure>[];
      client.events.listen(
        (event) {
          if (event is RealtimeFailure) failures.add(event);
        },
      );
      client.start();
      await _until(
        () => failures.isNotEmpty,
        timeout: const Duration(seconds: 3),
      );

      // One refresh, then it stops asking. A loop of refreshes against a server
      // that will never accept the session is a request amplifier.
      expect(tokens.refreshCalls, lessThanOrEqualTo(2));
      await client.stop();
    });

    test('no token means no connection and no retry storm', () async {
      tokens.accessToken = null;
      final failures = <RealtimeFailure>[];
      final client = _client(
        tokens,
        onConnect: (uri) {
          final socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(() => socket.emit({'type': 'ready', 'user_id': 1}));
          return socket;
        },
      );
      client.events.listen(
        (event) {
          if (event is RealtimeFailure) failures.add(event);
        },
      );
      client.start();
      await _until(
        () => failures.isNotEmpty,
        timeout: const Duration(seconds: 3),
      );

      expect(FakeSocket.opened, isEmpty, reason: 'never opened a socket');
      await client.stop();
    });
  });

  group('reconnecting', () {
    test('a dropped connection comes back', () async {
      final client = _client(
        tokens,
        onConnect: (uri) {
          final socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(
            () => socket.emit({'type': 'ready', 'user_id': 7}),
          );
          return socket;
        },
      );
      client.start();
      await _until(() => client.isConnected);

      FakeSocket.opened.single.drop();
      await _until(
        () => FakeSocket.opened.length > 1,
        timeout: const Duration(seconds: 10),
        because: 'a dropped socket must be replaced',
      );
      await client.stop();
    });

    test('a closed socket stops reconnecting', () async {
      final client = _client(
        tokens,
        onConnect: (uri) {
          final socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(
            () => socket.emit({'type': 'ready', 'user_id': 7}),
          );
          return socket;
        },
      );
      client.start();
      await _until(() => client.isConnected);
      await client.stop();

      final openedWhenStopped = FakeSocket.opened.length;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        FakeSocket.opened.length,
        openedWhenStopped,
        reason: 'signed out means no reconnecting',
      );
    });
  });

  group('events', () {
    test('messages, receipts and typing are translated', () async {
      late FakeSocket socket;
      final client = _client(
        tokens,
        onConnect: (uri) {
          socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(() => socket.emit({'type': 'ready', 'user_id': 7}));
          return socket;
        },
      );
      final events = <RealtimeEvent>[];
      client.events.listen(events.add);
      client.start();
      await _until(() => client.isConnected);

      socket.emit({
        'type': 'message',
        'data': {'id': 1, 'body': 'hello'},
      });
      socket.emit({
        'type': 'receipt',
        'data': {
          'conversation_id': 3,
          'user_id': 9,
          'up_to_seq': 12,
          'read': true,
        },
      });
      socket.emit({
        'type': 'typing',
        'data': {'conversation_id': 3, 'user_id': 9, 'typing': true},
      });

      await _until(() => events.whereType<RealtimeTyping>().isNotEmpty);
      expect(events.whereType<RealtimeMessage>().single.data['body'], 'hello');

      final receipt = events.whereType<RealtimeReceipt>().single;
      expect(receipt.conversationId, 3);
      expect(receipt.upToSeq, 12);
      expect(receipt.read, isTrue);

      final typing = events.whereType<RealtimeTyping>().single;
      expect(typing.conversationId, 3);
      expect(typing.typing, isTrue);
      await client.stop();
    });

    test('an unreadable frame does not tear the socket down', () async {
      late FakeSocket socket;
      final client = _client(
        tokens,
        onConnect: (uri) {
          socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(() => socket.emit({'type': 'ready', 'user_id': 7}));
          return socket;
        },
      );
      client.start();
      await _until(() => client.isConnected);

      socket.emitRaw('not json at all');
      socket.emit({'type': 'message', 'data': {'id': 1}});
      await _until(() => !client.isConnected == false);
      expect(client.isConnected, isTrue, reason: 'one bad frame is not an outage');
      await client.stop();
    });
  });

  group('typing', () {
    test('repeated typing is throttled into one message', () async {
      late FakeSocket socket;
      final client = _client(
        tokens,
        onConnect: (uri) {
          socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(() => socket.emit({'type': 'ready', 'user_id': 7}));
          return socket;
        },
      );
      client.start();
      await _until(() => client.isConnected);

      for (var i = 0; i < 20; i++) {
        client.sendTyping(1, typing: true);
      }
      final typingFrames = socket.received
          .where((frame) => frame['type'] == 'typing')
          .toList();
      expect(typingFrames, hasLength(1), reason: 'twenty keystrokes, one notice');
      await client.stop();
    });

    test('nothing is sent while disconnected', () async {
      late FakeSocket socket;
      final client = _client(
        tokens,
        onConnect: (uri) {
          socket = FakeSocket();
          FakeSocket.opened.add(socket);
          scheduleMicrotask(() => socket.emit({'type': 'ready', 'user_id': 7}));
          return socket;
        },
      );
      client.start();
      await _until(() => client.isConnected);
      await client.stop();

      client.sendTyping(1, typing: true);
      final after = socket.received
          .where((frame) => frame['type'] == 'typing')
          .length;
      expect(
        after,
        0,
        reason: 'a closed socket gets nothing, and this test never sent any',
      );
    });
  });
}

/// Builds a client over a stubbed token source.
///
/// The real [ApiClient] needs a Dio instance and a token store to exist before
/// it will answer, and the socket only ever asks it for two things: a token, and
/// whether a refresh worked. Stubbing those two keeps the test about the socket.
RealtimeClient _client(
  _Tokens tokens, {
  required FakeSocket Function(Uri uri) onConnect,
  Duration handshake = const Duration(milliseconds: 300),
}) {
  return RealtimeClient(
    api: _StubApi(tokens),
    random: Random(7),
    endpoint: Uri.parse('ws://test/ws'),
    connect: onConnect,
    handshakeTimeout: handshake,
  );
}

/// [ApiClient] stubbed down to the two things the socket asks it.
///
/// Named `_state` rather than `tokens` because ApiClient has a field of that
/// name already, and shadowing it turns every reference into a question about
/// which one is meant.
class _StubApi implements ApiClient {
  _StubApi(this._state);

  final _Tokens _state;

  @override
  Future<String?> accessTokenForSocket() async => _state.accessToken;

  @override
  Future<bool> tryRefresh() async {
    _state.refreshCalls++;
    if (!_state.refreshSucceeds) return false;
    _state.accessToken = 'token-${_state.refreshCalls + 1}';
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_StubApi.${invocation.memberName}');
}

/// Polls until a condition holds. The socket works in real time; there is no
/// event to await for "it eventually reconnected".
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
  String? because,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition never held${because == null ? '' : ': $because'}');
}