import 'api_client.dart';

/// Whether a handle is free, and what to offer if not.
///
/// Lives in the service layer rather than the screen so the transport can be
/// swapped without touching the widget, and so the widget test can pass a fake
/// without constructing a Dio instance.
abstract class UsernameAvailability {
  /// Throws [ApiException] on transport failure; callers decide how to show it.
  Future<AvailabilityResult> check(String username);
}

class AvailabilityResult {
  const AvailabilityResult({
    required this.available,
    this.suggestions = const [],
  });

  /// Convenience for the common "free" case.
  const AvailabilityResult.ok() : this(available: true);

  final bool available;

  /// Alternatives, already ordered by the server. Empty when there is nothing
  /// useful to offer.
  final List<String> suggestions;
}

/// Talks to `GET /users/username/check`.
///
/// The server returns 200 for both outcomes on purpose: a 404 would let a
/// caller distinguish them without reading the body, which is the same
/// enumeration leak the endpoint is built to avoid. So [available] comes from
/// the payload rather than the status code.
class ApiUsernameAvailability implements UsernameAvailability {
  ApiUsernameAvailability(this._client);

  final ApiClient _client;

  @override
  Future<AvailabilityResult> check(String username) async {
    final response = await _client.getJson(
      '/users/username/check',
      query: {'username': username},
    );

    final raw = response['suggestions'];
    return AvailabilityResult(
      available: response['available'] == true,
      suggestions: raw is List
          ? raw.whereType<String>().toList(growable: false)
          : const [],
    );
  }
}

/// Local stand-in.
///
/// Kept for widget tests and for the brief window where the API is unreachable
/// during development, where showing a guess beats showing an error. It is not
/// the answer to anything: only the server knows what is taken.
class FakeUsernameAvailability implements UsernameAvailability {
  FakeUsernameAvailability({Set<String>? taken})
    : _taken = taken ?? const {'aarav.sharma', 'meera.iyer'};

  final Set<String> _taken;

  @override
  Future<AvailabilityResult> check(String username) async {
    // A short delay so pending state is visible, which is what a real round
    // trip looks like.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (_taken.contains(username)) {
      final base = username.contains('.')
          ? username.substring(0, username.lastIndexOf('.'))
          : username;
      return AvailabilityResult(
        available: false,
        suggestions: [
          for (var n = 2; n <= 4; n++)
            if (!_taken.contains('$base.$n')) '$base.$n',
        ],
      );
    }
    return const AvailabilityResult.ok();
  }
}

/// Throws [ApiException] on transport failure; callers decide how to show it.
///
/// Named so the reference in [UsernameAvailability.check] resolves.
typedef AvailabilityTransportException = ApiException;