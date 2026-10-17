import 'package:meridian/services/token_store.dart';

/// In-memory [TokenBackend] for tests, so nothing touches real secure storage.
class FakeTokenBackend implements TokenBackend {
  FakeTokenBackend([Map<String, String>? initial]) : values = {...?initial};

  Map<String, String> values;
  int clearCount = 0;

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);

  @override
  Future<void> writeAll(Map<String, String> newValues) async {
    values = Map.of(newValues);
  }

  @override
  Future<void> clear() async {
    clearCount++;
    values = {};
  }
}
