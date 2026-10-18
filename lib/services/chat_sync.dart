// The constructors below take public named arguments and assign them to private
// fields, which the initializing-formals lint reads as a mistake. Collapsing
// them would make the named arguments private too and force every caller to use
// positional arguments.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/chat_store.dart';
import 'api_client.dart';
import 'meridian_api.dart';

/// What one sync pass did.
@immutable
class SyncOutcome {
  const SyncOutcome({
    this.messages = 0,
    this.conversations = 0,
    this.pages = 0,
    this.newestSeq = 0,
    this.hasMore = false,
    this.stoppedEarly = false,
  });

  /// How many messages were written. Not how many were new: a re-sync writes
  /// the same rows again, and a count of "new" would be zero on every ordinary
  /// sync, which looks like nothing happened.
  final int messages;
  final int conversations;
  final int pages;
  final int newestSeq;

  /// The server has more in this direction.
  final bool hasMore;

  /// The pass hit its page ceiling with more to fetch.
  ///
  /// Surfaced rather than hidden. A sync that quietly stops early looks exactly
  /// like a conversation that has stopped receiving messages, which is the one
  /// thing a user would definitely notice and nobody could explain.
  final bool stoppedEarly;

  @override
  String toString() =>
      'SyncOutcome(messages: $messages, conversations: $conversations, '
      'pages: $pages, newestSeq: $newestSeq, hasMore: $hasMore, '
      'stoppedEarly: $stoppedEarly)';
}

/// Pulls the server's history into the device's own store.
///
/// **Nothing here deletes.** That is the whole contract, and it is the opposite
/// of what a naive sync does. The server deletes messages after 28 days and is
/// supposed to; a device that treated a message missing from a response as
/// deleted would empty every conversation a month after it started. So the only
/// things a response can do here are add and update.
///
/// The consequence is that a conversation whose messages have all expired on the
/// server keeps its messages here, marked expired, and a device reinstalled
/// starts from whatever the server still has. That is the intended trade: the
/// device is the archive, and the server is a window.
class ChatSync {
  // The constructor takes public named arguments and assigns them to private
  // fields, which the initializing-formals lint reads as a mistake. Collapsing
  // them would make the named arguments private and force positional callers.
  ChatSync({required MeridianApi api, required ChatStore store})
    : _api = api,
      _store = store;

  final MeridianApi _api;
  final ChatStore _store;

  /// Pages per pass.
  ///
  /// A conversation a month old can hold thousands of messages. Fetching all of
  /// them on open would be slow, expensive and pointless — the user is looking
  /// at the last screenful. Older pages are fetched when the user scrolls back.
  static const int maxPagesPerPass = 5;

  static const int pageSize = 50;

  Future<SyncOutcome> syncAll() async {
    final conversations = await _api.conversations();
    await _store.upsertConversations(conversations);

    var messages = 0;
    var newestSeq = 0;
    for (final conversation in conversations) {
      final outcome = await syncConversation(
        conversation.id,
        newestSeqKnown: conversation.lastSeq,
      );
      messages += outcome.messages;
      newestSeq = outcome.newestSeq > newestSeq ? outcome.newestSeq : newestSeq;
    }
    return SyncOutcome(
      messages: messages,
      conversations: conversations.length,
      newestSeq: newestSeq,
    );
  }

  /// Fetch the newest pages of one conversation into the store.
  ///
  /// [newestSeqKnown] is what the device already holds, used to stop after the
  /// first page when nothing has changed — which is the common case, because
  /// most syncs happen when the app opens and most of the time nobody has
  /// written anything.
  Future<SyncOutcome> syncConversation(
    int conversationId, {
    int? newestSeqKnown,
  }) async {
    return _walk(
      conversationId,
      startBefore: null,
      maxPages: maxPagesPerPass,
      stopWhenCaughtUp: newestSeqKnown != null && newestSeqKnown > 0,
      knownNewest: newestSeqKnown,
    );
  }

  /// Fetch pages older than [beforeSeq].
  ///
  /// Separate from [syncConversation] because it starts from a cursor rather
  /// than the newest end. Without it there is no way to scroll back in a
  /// conversation: the catch-up sync only ever asks for the newest page, so
  /// history beyond it would be unreachable no matter how far the user scrolled.
  Future<SyncOutcome> fetchOlder(
    int conversationId, {
    required int beforeSeq,
    int maxPages = maxPagesPerPass,
  }) async {
    return _walk(
      conversationId,
      startBefore: beforeSeq,
      maxPages: maxPages,
    );
  }

  /// The one paging loop, shared so the two entry points cannot drift.
  ///
  /// [stopWhenCaughtUp] ends the walk after the first page when the server's
  /// newest sequence is not ahead of what the device already had. Without it,
  /// opening a conversation nobody has written to since the last sync walks
  /// backwards through the entire history for nothing.
  Future<SyncOutcome> _walk(
    int conversationId, {
    required int? startBefore,
    required int maxPages,
    bool stopWhenCaughtUp = false,
    int? knownNewest,
  }) async {
    int? before = startBefore;
    var newestSeq = knownNewest ?? 0;
    var fetched = 0;
    var pages = 0;
    var hasMore = false;

    while (pages < maxPages) {
      final ChatPage page;
      try {
        page = await _api.messages(
          conversationId,
          beforeSeq: before,
          limit: pageSize,
        );
      } on ApiException catch (error) {
        // Offline is the normal case, not an error worth surfacing as one. The
        // pages already fetched are kept, because they are good, and the next
        // pass continues from there.
        debugPrint(
          'Sync of conversation $conversationId stopped: ${error.message}',
        );
        return SyncOutcome(
          messages: fetched,
          pages: pages,
          newestSeq: newestSeq,
          hasMore: hasMore,
          stoppedEarly: true,
        );
      }

      if (page.messages.isEmpty) {
        hasMore = false;
        break;
      }

      await _store.upsertMessages(page.messages);
      fetched += page.messages.length;
      pages++;
      hasMore = page.hasMore;

      // Walk backwards by the oldest sequence number *in the page*, which the
      // server already sorted ascending. Null should be impossible for a server
      // message; if it happens, there is no cursor to continue from.
      final oldest = page.messages.first.seq;
      if (oldest == null) break;

      if (stopWhenCaughtUp && pages == 1 && page.newestSeq <= newestSeq) {
        return SyncOutcome(
          messages: fetched,
          pages: pages,
          newestSeq: page.newestSeq,
          hasMore: page.hasMore,
        );
      }

      newestSeq = page.newestSeq > newestSeq ? page.newestSeq : newestSeq;
      before = oldest;

      if (!page.hasMore) break;
    }

    return SyncOutcome(
      messages: fetched,
      pages: pages,
      newestSeq: newestSeq,
      hasMore: hasMore,
      stoppedEarly: pages >= maxPages && hasMore,
    );
  }
}