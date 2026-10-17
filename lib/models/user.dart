/// The authenticated user.
///
/// Decoded from `GET /api/v1/me`, which is a superset of `GET /auth/me`: same
/// identity fields plus the editable profile and the verification flag. One
/// endpoint is enough for the whole app, and reading the richer one means the
/// handle, display name and avatar are available without a second request.
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
  /// Empty only when the server did not send one, which should not happen on
  /// any account created after usernames shipped. Never substituted with a
  /// guess: a handle shown to another user that is not really yours is worse
  /// than showing none.
  final String username;

  /// Name shown instead of the legal one. Null means "fall back to the name".
  final String? displayName;

  final String? bio;
  final String? avatarUrl;

  /// Whether [email] has been confirmed. False for an address that was never
  /// verified, and also for one that was just changed, since a new address has
  /// not been proven.
  final bool emailVerified;

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
    this.displayName,
    this.bio,
    this.avatarUrl,
    this.emailVerified = false,
  });

  bool get hasUsername => username.isNotEmpty;

  /// The name to show in a header: what they chose, else their legal name.
  String get preferredName {
    final chosen = displayName?.trim();
    if (chosen != null && chosen.isNotEmpty) return chosen;
    return fullName;
  }

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
  displayName: json['display_name'] as String?,
  bio: json['bio'] as String?,
  avatarUrl: json['avatar_url'] as String?,
  emailVerified: json['email_verified'] is bool && json['email_verified'] as bool,
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
    'display_name': displayName,
    'bio': bio,
    'avatar_url': avatarUrl,
    'email_verified': emailVerified,
  };

  /// A copy with the given fields replaced.
  ///
  /// Used after an edit so the cached profile matches what the server stored.
  /// Passing null leaves a field alone, which is why this cannot express
  /// "clear the bio": the API is asked to clear it and its answer is decoded
  /// into a whole new profile instead.
  UserProfile copyWith({
    String? username,
    String? email,
    String? displayName,
    String? bio,
    String? avatarUrl,
    bool? emailVerified,
  }) => UserProfile(
    id: id,
    role: role,
    status: status,
    firstName: firstName,
    surname: surname,
    prn: prn,
    empId: empId,
    email: email ?? this.email,
    collegeCode: collegeCode,
    username: username ?? this.username,
    displayName: displayName ?? this.displayName,
    bio: bio ?? this.bio,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    emailVerified: emailVerified ?? this.emailVerified,
  );
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
