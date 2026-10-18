import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'chat_models.dart';
import 'chat_store.dart';

/// SQLite-backed [ChatStore] and [Outbox].
///
/// **Two id columns, on purpose.** `row_id` is SQLite's own, assigned when a
/// message is created locally. `server_id` is the server's, null until the send
/// is acknowledged. They are separate columns because a single `id` column would
/// mix two id spaces that both start at 1: an unsent message takes row 1
/// locally, and later an unrelated message arrives from the server with id 1,
/// and the upsert replaces the unsent row. The user's unsent message disappears,
/// silently, because two independently-assigned integers collided.
///
/// The server id gets its own unique index rather than being the primary key,
/// which also means the reconciliation update after a send is an ordinary
/// UPDATE instead of a primary key change.
///
/// The schema follows the server's where it should and departs from it where the
/// device has different needs:
///
/// * A unique index on `client_id`, which the server enforces per conversation
///   but the device needs globally, because that is what it looks up to
///   reconcile an optimistic message with the server's answer.
/// * `state` and `failure_reason`, which have no server equivalent — they are
///   about what this device is still doing about a message, not about the
///   message.
///
/// Times are stored as epoch milliseconds, not ISO strings. They are compared
/// constantly — "what is due", "what is newer" — and string comparison of
/// timestamps is wrong in a way that only shows up on a device whose clock is
/// different from the server's.
class SqliteChatStore implements ChatStore, Outbox {
  // `_database` is private, so an initializing formal would force the public
  // named argument to be private too.
  // ignore: prefer_initializing_formals
  SqliteChatStore({Database? database}) : _database = database;

  static const int schemaVersion = 1;

  Database? _database;

  /// The open handle, for tests that need to close it.
  @visibleForTesting
  Database? get databaseForTests => _database;

  Database get _db {
    final database = _database;
    if (database == null) {
      throw StateError('SqliteChatStore.open() has not completed');
    }
    return database;
  }

  @override
  Future<void> open() async {
    if (_database != null) return;
    final directory = await getApplicationSupportDirectory();
    final path = '${directory.path}/meridian_chat.db';
    _database = await openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) async {
        // Cascades are declared in the schema but are off by default in SQLite,
        // so without this a deleted message leaves its receipts behind and they
        // accumulate forever.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await createSchema(db);
      },
    );
  }

  /// The schema, as a function of a bare [Database].
  ///
  /// Static and public so the tests can build the same schema rather than a
  /// copy of it. A duplicated DDL in a test is a DDL that quietly stops
  /// matching, and then the tests pass against a database the app will never
  /// see.
  static Future<void> createSchema(Database db) async {
    await db.execute('''
        CREATE TABLE conversations (
          id INTEGER PRIMARY KEY,
          kind TEXT NOT NULL,
          title TEXT,
          avatar_url TEXT,
          last_seq INTEGER NOT NULL DEFAULT 0,
          last_message_at INTEGER,
          unread_count INTEGER NOT NULL DEFAULT 0,
          preview TEXT
        )
      ''');
    await db.execute('''
        CREATE TABLE messages (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          server_id INTEGER,
          -- Deliberately NOT a foreign key to conversations.
          --
          -- An FK with ON DELETE CASCADE would be a trap here: conversations
          -- are upserted with REPLACE, and REPLACE deletes the conflicting row
          -- first. With a cascade that would delete every message in the
          -- conversation, so re-syncing a conversation whose title changed would
          -- wipe the user's history. A message outliving its conversation row is
          -- exactly what the retention design wants; it is only wiped by clear(),
          -- on sign-out.
          conversation_id INTEGER NOT NULL,
          client_id TEXT NOT NULL,
          seq INTEGER,
          body TEXT NOT NULL,
          kind TEXT NOT NULL DEFAULT 'text',
          sender_id INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          expires_at INTEGER,
          attachment_id INTEGER,
          expired INTEGER NOT NULL DEFAULT 0,
          attachment_expired INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL DEFAULT 'sent',
          failure_reason TEXT
        )
      ''');
    // The reconciliation lookup. Global rather than per conversation because
    // clientId is a device-generated UUID and two conversations cannot
    // produce the same one.
    await db.execute(
      'CREATE UNIQUE INDEX ux_messages_client_id ON messages(client_id)',
    );
    // SQLite treats NULLs as distinct in a unique index, so every unsent
    // message can sit at NULL here without colliding with any other unsent
    // message. That is what makes this index possible at all.
    await db.execute(
      'CREATE UNIQUE INDEX ux_messages_server_id ON messages(server_id)',
    );
    // The message list query: one conversation, newest page, walking
    // backwards. Without this the list is a scan of every message ever
    // received on the device.
    await db.execute('''
      CREATE INDEX ix_messages_conversation_seq
        ON messages(conversation_id, seq)
      ''');
    await db.execute('''
        CREATE TABLE outbox (
          client_id TEXT PRIMARY KEY,
          conversation_id INTEGER NOT NULL,
          body TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          next_attempt_at INTEGER NOT NULL,
          last_error TEXT
        )
      ''');
    await db.execute('CREATE INDEX ix_outbox_due ON outbox(next_attempt_at)');
  }

  @override
  Future<List<ConversationSummary>> conversations() async {
    final rows = await _db.query(
      'conversations',
      orderBy: 'last_message_at DESC, id DESC',
    );
    return rows.map(_conversationFromRow).toList();
  }

  @override
  Future<ConversationSummary?> conversation(int id) async {
    final rows = await _db.query('conversations', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _conversationFromRow(rows.first);
  }

  @override
  Future<List<ChatMessage>> messages(
    int conversationId, {
    int limit = 50,
    int? beforeSeq,
  }) async {
    final where = <String>['conversation_id = ?'];
    final args = <Object?>[conversationId];
    if (beforeSeq != null) {
      where.add('(seq IS NULL OR seq < ?)');
      args.add(beforeSeq);
    }
    // seq DESC gives the newest page, which is what a chat opens on, and the
    // reversed result is what the list renders. Unsent messages have no seq and
    // sort to the top, which is right: they are the newest thing in the thread.
    final rows = await _db.query(
      'messages',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'seq IS NULL DESC, seq DESC, created_at DESC, row_id DESC',
      limit: limit,
    );
    return rows.reversed.map(_messageFromRow).toList();
  }

  @override
  Future<ChatMessage?> messageByClientId(String clientId) async {
    final rows = await _db.query(
      'messages',
      where: 'client_id = ?',
      whereArgs: [clientId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _messageFromRow(rows.first);
  }

  @override
  Future<void> upsertMessages(List<ChatMessage> messages) async {
    if (messages.isEmpty) return;
    final batch = _db.batch();
    for (final message in messages) {
      batch.insert(
        'messages',
        _messageToRow(message),
        // REPLACE, not IGNORE. An optimistic row already sits under this
        // client_id with a null server_id, and IGNORE would treat that as a
        // conflict and drop the server's answer on the floor -- leaving the
        // message stuck at "sending" forever, because nothing else ever writes
        // that row again. REPLACE deletes the stale row and inserts the
        // authoritative one, which is the correct outcome when the server and
        // the device disagree about a message.
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> upsertConversations(List<ConversationSummary> conversations) async {
    if (conversations.isEmpty) return;
    final batch = _db.batch();
    for (final conversation in conversations) {
      batch.insert(
        'conversations',
        _conversationToRow(conversation),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> markSent({
    required String clientId,
    required int id,
    required int seq,
    required MessageSendState state,
  }) async {
    await _db.update(
      'messages',
      {
        'server_id': id,
        'seq': seq,
        'state': state.name,
        'failure_reason': null,
      },
      where: 'client_id = ?',
      whereArgs: [clientId],
    );
  }

  @override
  Future<void> markFailed({required String clientId, required String reason}) async {
    await _db.update(
      'messages',
      {'state': MessageSendState.failed.name, 'failure_reason': reason},
      where: 'client_id = ?',
      whereArgs: [clientId],
    );
  }

  @override
  Future<void> applyReceipt({
    required int conversationId,
    required int userId,
    required int upToSeq,
    required bool read,
  }) async {
    // Forward-only, expressed in the WHERE clause rather than in Dart.
    //
    // A delivered receipt that arrives after a read one has to be ignored, and
    // the race is between two sockets and two devices rather than something
    // this process can order. "Only move to delivered if it is not already read"
    // is one predicate that is correct no matter what order they arrive in.
    final target = read ? MessageSendState.read : MessageSendState.delivered;
    final eligible = read
        ? const [MessageSendState.sent, MessageSendState.delivered]
        : const [MessageSendState.sent];

    await _db.update(
      'messages',
      {'state': target.name},
      where: 'conversation_id = ? AND sender_id != ? AND seq IS NOT NULL '
          'AND seq <= ? AND state IN (${eligible.map((_) => '?').join(',')})',
      whereArgs: [conversationId, userId, upToSeq, ...eligible.map((s) => s.name)],
    );
  }

  @override
  Future<void> clear() async {
    final batch = _db.batch();
    batch.delete('messages');
    batch.delete('conversations');
    batch.delete('outbox');
    await batch.commit(noResult: true);
  }

  // ------------------------------------------------------------------
  // outbox

  @override
  Future<void> add(OutboxEntry entry) async {
    await _db.insert(
      'outbox',
      {
        'client_id': entry.clientId,
        'conversation_id': entry.conversationId,
        'body': entry.body,
        'created_at': entry.createdAt.millisecondsSinceEpoch,
        'attempts': entry.attempts,
        'next_attempt_at': entry.nextAttemptAt.millisecondsSinceEpoch,
        'last_error': entry.lastError,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<OutboxEntry>> due(DateTime now, {int limit = 20}) async {
    final rows = await _db.query(
      'outbox',
      where: 'next_attempt_at <= ?',
      whereArgs: [now.millisecondsSinceEpoch],
      orderBy: 'next_attempt_at ASC, created_at ASC',
      limit: limit,
    );
    return rows.map(_outboxFromRow).toList();
  }

  @override
  Future<OutboxEntry?> byClientId(String clientId) async {
    final rows = await _db.query(
      'outbox',
      where: 'client_id = ?',
      whereArgs: [clientId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _outboxFromRow(rows.first);
  }

  @override
  Future<void> resolve(String clientId) async {
    await _db.delete('outbox', where: 'client_id = ?', whereArgs: [clientId]);
  }

  @override
  Future<void> defer(
    String clientId, {
    required String error,
    required DateTime nextAttemptAt,
  }) async {
    // Attempts is incremented in Dart rather than SQL so the backoff and the
    // count that decides when to give up cannot disagree about what attempt
    // number this is.
    final entry = await byClientId(clientId);
    if (entry == null) return;
    await _db.update(
      'outbox',
      {
        'attempts': entry.attempts + 1,
        'next_attempt_at': nextAttemptAt.millisecondsSinceEpoch,
        'last_error': error,
      },
      where: 'client_id = ?',
      whereArgs: [clientId],
    );
  }

  @override
  Future<void> abandon(String clientId) async {
    await resolve(clientId);
  }

  @override
  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM outbox');
    return (rows.first['n'] as int?) ?? 0;
  }

  // ------------------------------------------------------------------
  // row mapping

  static ConversationSummary _conversationFromRow(Map<String, Object?> row) {
    return ConversationSummary(
      id: row['id']! as int,
      kind: row['kind']! as String,
      title: row['title'] as String?,
      avatarUrl: row['avatar_url'] as String?,
      lastSeq: (row['last_seq'] as int?) ?? 0,
      lastMessageAt: _fromMillis(row['last_message_at'] as int?),
      unreadCount: (row['unread_count'] as int?) ?? 0,
      preview: row['preview'] as String?,
    );
  }

  static Map<String, Object?> _conversationToRow(ConversationSummary conversation) {
    return {
      'id': conversation.id,
      'kind': conversation.kind,
      'title': conversation.title,
      'avatar_url': conversation.avatarUrl,
      'last_seq': conversation.lastSeq,
      'last_message_at': conversation.lastMessageAt?.millisecondsSinceEpoch,
      'unread_count': conversation.unreadCount,
      'preview': conversation.preview,
    };
  }

  static ChatMessage _messageFromRow(Map<String, Object?> row) {
    return ChatMessage(
      id: row['server_id'] as int?,
      conversationId: row['conversation_id']! as int,
      clientId: row['client_id']! as String,
      seq: row['seq'] as int?,
      body: row['body']! as String,
      kind: row['kind']! as String,
      senderId: row['sender_id']! as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
      expiresAt: _fromMillis(row['expires_at'] as int?),
      attachmentId: row['attachment_id'] as int?,
      expired: (row['expired'] as int? ?? 0) == 1,
      attachmentExpired: (row['attachment_expired'] as int? ?? 0) == 1,
      state: MessageSendState.values.firstWhere(
        (state) => state.name == row['state'],
        // An unrecognised state means a newer build wrote this row. Defaulting
        // to failed shows a retry rather than silently dropping a message, which
        // is the safer of the two wrong answers.
        orElse: () => MessageSendState.failed,
      ),
      failureReason: row['failure_reason'] as String?,
    );
  }

  static Map<String, Object?> _messageToRow(ChatMessage message) {
    return {
      // Deliberately no row_id: SQLite assigns it. Writing it would let a
      // caller claim a row that belongs to a different message.
      'server_id': message.id,
      'conversation_id': message.conversationId,
      'client_id': message.clientId,
      'seq': message.seq,
      'body': message.body,
      'kind': message.kind,
      'sender_id': message.senderId,
      'created_at': message.createdAt.millisecondsSinceEpoch,
      'expires_at': message.expiresAt?.millisecondsSinceEpoch,
      'attachment_id': message.attachmentId,
      'expired': message.expired ? 1 : 0,
      'attachment_expired': message.attachmentExpired ? 1 : 0,
      'state': message.state.name,
      'failure_reason': message.failureReason,
    };
  }

  static OutboxEntry _outboxFromRow(Map<String, Object?> row) {
    return OutboxEntry(
      clientId: row['client_id']! as String,
      conversationId: row['conversation_id']! as int,
      body: row['body']! as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
      attempts: (row['attempts'] as int?) ?? 0,
      nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(row['next_attempt_at']! as int),
      lastError: row['last_error'] as String?,
    );
  }

  static DateTime? _fromMillis(int? value) =>
      value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
}