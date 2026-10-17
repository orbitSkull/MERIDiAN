/// The authenticated user as returned by `GET /auth/me`.
class UserProfile {
  final int id;
  final String role;
  final String status;
  final String firstName;
  final String surname;
  final String? prn;
  final String? empId;
  final String? email;
  final String? collegeCode;

  /// Public handle, unique across the platform.
  ///
  /// The backend does not return this yet, so it decodes to an empty string
  /// until the username endpoints land. Treat it as optional everywhere rather
  /// than falling back to a name, because a guessed handle shown to another
  /// user is worse than showing none.
  final String username;

  const UserProfile({
    required this.id,
    required this.role,
    required this.status,
    required this.firstName,
    required this.surname,
    this.prn,
    this.empId,
    this.email,
    this.collegeCode,
    this.username = '',
  });

  bool get hasUsername => username.isNotEmpty;

factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
  // Defensive: a truncated or unexpected payload must not crash the app with
  // a cast error. Defaults match the API's own fallbacks.
  id: json['id'] is int ? json['id'] as int : 0,
  role: json['role'] as String? ?? 'student',
  status: json['status'] as String? ?? 'active',
  firstName: json['first_name'] as String? ?? '',
  surname: json['surname'] as String? ?? '',
  prn: json['prn'] as String?,
  empId: json['emp_id'] as String?,
  email: json['email'] as String?,
collegeCode: json['college_code'] as String?,
    username: json['username'] as String? ?? '',
  );

  String get fullName =>
      firstName.isEmpty ? surname : '$firstName $surname';

  /// Human-facing institutional identifier, whichever the account carries.
  /// Empty string when neither a PRN nor an employee ID is set.
  String get identifier => prn ?? empId ?? '';

  /// Display form of [identifier], or null when there is nothing to show, so
  /// callers do not have to invent a placeholder.
  String? get identifierLabel => identifier.isEmpty ? null : identifier;

  bool get isModerator => role == 'moderator';

  bool get isFaculty => role == 'faculty';

  bool get isStudent => role == 'student';

  /// Round-trippable form for caching the profile while offline.
  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'status': status,
    'first_name': firstName,
    'surname': surname,
    'prn': prn,
    'emp_id': empId,
    'email': email,
    'college_code': collegeCode,
    'username': username,
  };
}

/// Token pair returned by login and refresh.
class TokenPair {
  final String accessToken;
  final String refreshToken;

  const TokenPair({required this.accessToken, required this.refreshToken});

  factory TokenPair.fromJson(Map<String, dynamic> json) => TokenPair(
    accessToken: json['access_token'] as String,
    refreshToken: json['refresh_token'] as String,
  );
}
