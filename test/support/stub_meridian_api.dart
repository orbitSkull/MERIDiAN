import 'package:meridian/services/meridian_api.dart';

/// A [MeridianApi] that implements none of it.
///
/// The messaging and settings fakes each cover the handful of endpoints their
/// own tests need, and [MeridianApi] grows over time. Without this base, every
/// new endpoint would have to be added to every fake in the suite, including the
/// ones that have no business knowing it exists — a search test gaining a
/// `markRead` stub is noise that hides the real stub.
///
/// Members reached through here throw [UnimplementedError] rather than returning
/// null, so a test that accidentally depends on an unstubbed endpoint fails with
/// a message naming the call instead of a confusing null dereference three
/// frames later.
abstract class StubMeridianApi implements MeridianApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'StubMeridianApi has no ${invocation.memberName}. The test that called '
        'it needs a stub for it.',
      );
}