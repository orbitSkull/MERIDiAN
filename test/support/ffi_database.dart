import 'dart:io';

import 'package:meridian/data/sqlite_chat_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _initialised = false;
int _counter = 0;

void _ensureInitialised() {
  if (_initialised) return;
  sqfliteFfiInit();
  // The no-isolate factory. A background isolate holding the database handle
  // outlives the test that opened it and makes closing it unreliable, which
  // shows up as files that cannot be deleted on Windows.
  databaseFactory = databaseFactoryFfiNoIsolate;
  _initialised = true;
}

/// A [SqliteChatStore] on a real SQLite database, plus a cleanup callback.
///
/// The point of these tests is the SQL — the DDL, the unique indexes, the
/// `ON CONFLICT` behaviour and the ordering. Asserting those against a hand
/// written fake would only prove the fake behaves like the fake, so this opens
/// the same engine the app runs on.
///
/// A fresh file per test rather than `inMemoryDatabasePath`. The factory caches
/// databases by path, so every `openDatabase(':memory:')` hands back the *same*
/// handle and the whole file silently shares one set of tables. That showed up
/// as outbox entries from an earlier test turning up in a later one, which is a
/// confusing way to lose an afternoon.
Future<({SqliteChatStore store, Future<void> Function() cleanup})> openTestChatStore() async {
  _ensureInitialised();
  _counter++;

  final directory = Directory.systemTemp.createTempSync('meridian_chat_test_');
  final path = '${directory.path}/store_$_counter.db';

  final database = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: SqliteChatStore.schemaVersion,
      onConfigure: (db) async {
        // The same pragma the real store sets. Without it these tests would not
        // exercise cascade behaviour, and would pass while the device did not.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await SqliteChatStore.createSchema(db);
      },
    ),
  );

  final store = SqliteChatStore(database: database);
  await store.open();

  Future<void> cleanup() async {
    await store.databaseForTests?.close();
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }

  return (store: store, cleanup: cleanup);
}