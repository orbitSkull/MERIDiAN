// The constructor takes public named arguments and assigns them to private
// fields, which the initializing-formals lint reads as a mistake. Collapsing them
// would make the named arguments private and force every caller to pass
// positionally, which is worse at every call site.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/chat_models.dart';
import '../data/chat_store.dart';
import 'api_client.dart';
import 'meridian_api.dart';

/// What one flush did.
@immutable
class FlushReport {
  const FlushReport({
    this.sent = 0,
    this.deferred = 0,
    this.abandoned = 0,
    this.offline = false,
  });

  final int sent;
  final int deferred;
  final int abandoned;

  /// The first failure was a connection problem rather than a refusal.
  ///
  /// Worth distinguishing because it decides whether the UI should say "not
  /// sent, we will retry" or "not sent", and a user who is merely in a lift
  /// should not be told their message failed.
  final bool offline;

  @override
  String toString() =>
      'FlushReport(sent: $sent, deferred: $deferred, abandoned: $abandoned, '
      'offline: $offline)';
}

/// Sends what is in the outbox, and puts an optimistic bubble in the UI first.
///
/// The order is the point. [send] writes the message locally and returns; the
/// network happens afterwards, in the background. Everything the user sees is
/// instant and everything the user writes survives a crash, a dead signal, or
/// the app being killed mid-send — the outbox row is on disk before the first
/// attempt.
///
/// [clientId] is generated once and reused for every retry of the same message.
/// That is the only reason retrying is safe: the server keys idempotency on it,
/// so a send that succeeded but whose response was lost comes back as the same
/// message instead of as a duplicate.
class OutboxSender {
  OutboxSender({
    required MeridianApi api,
    required ChatStore store,
    required Outbox outbox,
    required int senderId,
    Random? random,
    DateTime Function()? clock,
  }) : _api = api,
       _store = store,
       _outbox = outbox,
       _senderId = senderId,
       _random = random ?? Random(),
       _clock = clock ?? DateTime.now;

  final MeridianApi _api;
  final ChatStore _store;
  final Outbox _outbox;

  /// Who this device is signed in as, for the optimistic bubble.
  final int _senderId;

  final Random _random;
  final DateTime Function() _clock;

  /// A retry already in flight.
  ///
  /// Without this, a pull-to-refresh and an app resume two seconds apart both
  /// flush, both pick up the same entry, and the message is sent twice. The
  /// server would deduplicate it by client_id, so nothing would be *wrong* — but
  /// the second request is wasted and the reconciliation races the first.
  Future<FlushReport>? _inFlight;

  /// Write a message locally and queue it. Returns immediately.
  Future<ChatMessage> send(int conversationId, String body) async {
    final now = _clock();
    final clientId = _newClientId();
    final message = ChatMessage(
      conversationId: conversationId,
      clientId: clientId,
      body: body,
      kind: 'text',
      senderId: _senderId,
      createdAt: now,
      state: MessageSendState.sending,
    );
    await _store.upsertMessages([message]);
    await _outbox.add(
      OutboxEntry(
        clientId: clientId,
        conversationId: conversationId,
        body: body,
        createdAt: now,
        attempts: 0,
        nextAttemptAt: now,
      ),
    );
    return message;
  }

  /// Try to send everything that is due.
  ///
  /// Returns the in-flight flush if one is already running, rather than starting
  /// a second over the same rows.
  Future<FlushReport> flush() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final future = _flushOnce();
    _inFlight = future;
    // Cleared on completion, success or failure, so a later flush can try again.
    return future.whenComplete(() => _inFlight = null);
  }

  Future<FlushReport> _flushOnce() async {
    var sent = 0;
    var deferred = 0;
    var abandoned = 0;
    var offline = false;

    final due = await _outbox.due(_clock());
    for (final entry in due) {
      try {
        final message = await _api.sendMessage(
          entry.conversationId,
          clientId: entry.clientId,
          body: entry.body,
        );
        // Reconcile by clientId rather than by id, because the local row has no
        // server id yet and the one the server returned is the thing that
        // identifies it from now on.
        await _store.upsertMessages([message]);
        await _store.markSent(
          clientId: entry.clientId,
          id: message.id!,
          seq: message.seq!,
          state: message.state,
        );
        await _outbox.resolve(entry.clientId);
        sent++;
      } on ApiException catch (error) {
        final status = error.statusCode;

        // 4xx means the server will never take this message. Retrying it forever
        // would leave a permanent ghost in the outbox and a retry button that
        // never works, so the bubble is marked failed and the row is dropped.
        // 401 and 403 are the interesting ones: blocked, or no longer a member.
        if (status != null && status >= 400 && status < 500 && status != 401) {
          await _store.markFailed(
            clientId: entry.clientId,
            reason: error.message,
          );
          await _outbox.abandon(entry.clientId);
          abandoned++;
          continue;
        }

        if (status == null || status >= 500) {
          offline = true;
        }

        final attempts = entry.attempts + 1;
        if (attempts >= OutboxEntry.maxAttempts) {
          // Out of retries. The message stays on the device with its body, and
          // the user decides — a send that silently vanished is worse than one
          // that visibly failed.
          await _store.markFailed(
            clientId: entry.clientId,
            reason: 'Could not be delivered',
          );
          await _outbox.abandon(entry.clientId);
          abandoned++;
          continue;
        }

        await _outbox.defer(
          entry.clientId,
          error: error.message,
          nextAttemptAt: _clock().add(_backoff(attempts)),
        );
        deferred++;
      }
    }

    return FlushReport(
      sent: sent,
      deferred: deferred,
      abandoned: abandoned,
      offline: offline,
    );
  }

  /// Exponential backoff with jitter.
  ///
  /// The jitter is the part people leave out and then cannot explain. Without
  /// it, every device that lost signal in the same lift wakes up at the same
  /// instant and retries at the same instant, so the server gets a thundering
  /// herd exactly when it is least able to serve it — which is the moment the
  /// signal comes back.
  Duration _backoff(int attempts) {
    final base = OutboxEntry.backoffFor(attempts);
    // Up to a third either way, so the ordering guarantee of the backoff still
    // holds and a retry cannot come *earlier* than its predecessor.
    final spread = (base.inMilliseconds * 0.3).round();
    if (spread == 0) return base;
    final offset = _random.nextInt(spread * 2 + 1) - spread;
    return Duration(milliseconds: base.inMilliseconds + offset);
  }

  String _newClientId() => newClientId(_random);
}
/// A v4-shaped random id for a message this device is about to send.
///
/// A random id rather than a monotonic counter: two devices must be able to
/// produce ids in the same space without coordinating, and the server looks
/// these up across every conversation rather than per sender.
///
/// Shared rather than kept inside [OutboxSender] because a media send also needs
/// one, and two copies of an id generator is how a client ends up sending
/// photographs twice because one of them forgot the version bits.
String newClientId(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
