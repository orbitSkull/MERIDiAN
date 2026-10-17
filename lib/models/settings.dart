/// Models for the settings endpoints: preferences, sessions and blocks.
///
/// All of these are decoded defensively. A settings screen that throws because
/// one field arrived in an unexpected shape is worse than one that shows a
/// default, so every read has a fallback and nothing here throws.
library;

/// The notification and privacy preferences stored against the account.
///
/// Twelve booleans, all defaulting to on. The default is "on" because that is
/// what the server defaults to, and a client that guessed "off" would silently
/// disagree with a fresh server row on first launch.
///
/// Field names match the API's, so [toJson] needs no translation and a new
/// preference is one line here plus one in the sync layer.
class UserPreferences {
  const UserPreferences({
    this.pushEnabled = true,
    this.emailEnabled = true,
    this.inAppEnabled = true,
    this.notifyMessages = true,
    this.notifyMentions = true,
    this.notifyCalls = true,
    this.readReceipts = true,
    this.typingIndicator = true,
    this.lastSeen = true,
    this.blockUnknownCallers = true,
    this.hideReadReceiptsFromBlocked = true,
    this.autoDownloadMedia = true,
  });

  // Notification channels.
  final bool pushEnabled;
  final bool emailEnabled;
  final bool inAppEnabled;

  // What to be told about.
  final bool notifyMessages;
  final bool notifyMentions;
  final bool notifyCalls;

  // Privacy, from the other direction: what others can see about you.
  final bool readReceipts;
  final bool typingIndicator;
  final bool lastSeen;

  // What blocked people are shown.
  final bool blockUnknownCallers;
  final bool hideReadReceiptsFromBlocked;

  // Media.
  final bool autoDownloadMedia;

  /// Every preference, in API field order.
  ///
  /// The order is not cosmetic: it is the order of the API's own schema, so a
  /// diff between this and the server's `SettingsOut` is readable.
  static const List<String> fieldNames = <String>[
    'push_enabled',
    'email_enabled',
    'in_app_enabled',
    'notify_messages',
    'notify_mentions',
    'notify_calls',
    'read_receipts',
    'typing_indicator',
    'last_seen',
    'block_unknown_callers',
    'hide_receipts_from_blocked',
    'auto_download_media',
  ];

  static bool _bool(Map<String, dynamic> json, String key) =>
      json[key] is bool ? json[key] as bool : true;

  factory UserPreferences.fromJson(Map<String, dynamic> json) =>
      UserPreferences(
        pushEnabled: _bool(json, 'push_enabled'),
        emailEnabled: _bool(json, 'email_enabled'),
        inAppEnabled: _bool(json, 'in_app_enabled'),
        notifyMessages: _bool(json, 'notify_messages'),
        notifyMentions: _bool(json, 'notify_mentions'),
        notifyCalls: _bool(json, 'notify_calls'),
        readReceipts: _bool(json, 'read_receipts'),
        typingIndicator: _bool(json, 'typing_indicator'),
        lastSeen: _bool(json, 'last_seen'),
        blockUnknownCallers: _bool(json, 'block_unknown_callers'),
        hideReadReceiptsFromBlocked: _bool(json, 'hide_receipts_from_blocked'),
        autoDownloadMedia: _bool(json, 'auto_download_media'),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'push_enabled': pushEnabled,
    'email_enabled': emailEnabled,
    'in_app_enabled': inAppEnabled,
    'notify_messages': notifyMessages,
    'notify_mentions': notifyMentions,
    'notify_calls': notifyCalls,
    'read_receipts': readReceipts,
    'typing_indicator': typingIndicator,
    'last_seen': lastSeen,
    'block_unknown_callers': blockUnknownCallers,
    'hide_receipts_from_blocked': hideReadReceiptsFromBlocked,
    'auto_download_media': autoDownloadMedia,
  };

  /// The single field named [key], or null when the key is not a preference.
  ///
  /// Used by the settings sync layer to turn one toggled switch into the
  /// one-key PATCH the API expects, so the other eleven are never at risk.
  bool? valueOf(String key) {
    final json = toJson();
    final value = json[key];
    return value is bool ? value : null;
  }

  /// Every preference on, used by the "reset" action.
  static const UserPreferences defaults = UserPreferences();
}

/// One signed-in device.
///
/// Never carries a token. The API does not send one and this has no field for
/// it, so a session list cannot become a credential dump with a user interface.
class DeviceSession {
  const DeviceSession({
    required this.id,
    this.deviceLabel,
    required this.createdAt,
    this.lastUsedAt,
    this.isCurrent = false,
  });

  final int id;
  final String? deviceLabel;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  /// True for the device making the request, so the UI can mark it and the
  /// "sign out other devices" action knows which one to keep.
  final bool isCurrent;

  /// What to show as the device's name.
  ///
  /// Falls back to a generic label rather than guessing from timestamps: "Signed
  /// in 3 March" is honest, "Chrome on Windows" would be a fabrication, and a
  /// wrong device name is exactly what makes someone revoke the wrong session.
  String get displayName {
    final label = deviceLabel?.trim();
    if (label == null || label.isEmpty) return 'Unknown device';
    return label;
  }

  /// Whether this device looks abandoned, so the UI can suggest signing it out.
  ///
  /// Null when it has never been seen again since signing in, because "no
  /// information" and "not used" are different answers.
  bool? get isIdle {
    final last = lastUsedAt;
    if (last == null) return null;
    return DateTime.now().toUtc().difference(last.toUtc()).inDays >= 30;
  }

  factory DeviceSession.fromJson(Map<String, dynamic> json) => DeviceSession(
    id: json['id'] is int ? json['id'] as int : 0,
    deviceLabel: json['device_label'] as String?,
    createdAt: _date(json['created_at']) ?? DateTime.now().toUtc(),
    lastUsedAt: _date(json['last_used_at']),
    isCurrent: json['current'] is bool && json['current'] as bool,
  );

  static DateTime? _date(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }
}

/// Someone in the college, as returned by a handle lookup.
///
/// Deliberately thin. A search result is not a profile: it carries what is
/// needed to decide whether to talk to somebody, and nothing that would turn the
/// lookup into a directory of the college.
class DirectoryUser {
  const DirectoryUser({
    required this.username,
    required this.firstName,
    required this.surname,
    required this.role,
    this.collegeCode,
  });

  final String username;
  final String firstName;
  final String surname;
  final String role;
  final String? collegeCode;

  String get fullName {
    final joined = '$firstName $surname'.trim();
    return joined.isEmpty ? username : joined;
  }

  String get roleLabel => switch (role) {
    'student' => 'Student',
    'faculty' => 'Faculty',
    'moderator' => 'Moderator',
    _ => role,
  };

  factory DirectoryUser.fromJson(Map<String, dynamic> json) => DirectoryUser(
    username: json['username'] as String? ?? '',
    firstName: json['first_name'] as String? ?? '',
    surname: json['surname'] as String? ?? '',
    role: json['role'] as String? ?? 'student',
    collegeCode: json['college_code'] as String?,
  );
}

/// The answer to "does this handle exist, and who is it".
///
/// [available] is the same signal the availability checker gives: true means the
/// handle is free or simply does not match anybody. The endpoint answers
/// identically for both on purpose, so this cannot be used to find out who is
/// registered.
class UserLookup {
  const UserLookup({required this.found, this.user});

  final bool found;
  final DirectoryUser? user;

  /// No match, whether because the handle is free or because the lookup was
  /// answered without a query.
  static const UserLookup notFound = UserLookup(found: false);

  factory UserLookup.fromJson(Map<String, dynamic> json) {
    final raw = json['user'];
    final user = raw is Map<String, dynamic>
        ? DirectoryUser.fromJson(raw)
        : null;
    // `found` and the body are read together rather than trusting one: a
    // response claiming to have found somebody with no user object is treated
    // as a miss, not rendered as a blank tile.
    return UserLookup(found: json['found'] == true && user != null, user: user);
  }
}

/// A page of people matching a handle search.
///
/// [truncated] is the field that matters most here: the server caps how many
/// rows one search returns, and without being told, a list of twenty reads as
/// "these are the only twenty people at the college".
class UserSearch {
  const UserSearch({
    required this.query,
    required this.results,
    this.truncated = false,
  });

  final String query;
  final List<DirectoryUser> results;

  /// More people matched than were returned.
  final bool truncated;

  static const UserSearch empty = UserSearch(query: '', results: []);

  bool get isEmpty => results.isEmpty;

  factory UserSearch.fromJson(Map<String, dynamic> json) {
    final raw = json['results'];
    final rows = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(DirectoryUser.fromJson)
              .toList()
        : const <DirectoryUser>[];
    return UserSearch(
      query: json['query'] as String? ?? '',
      results: rows,
      truncated: json['truncated'] == true,
    );
  }
}

/// Someone this account has blocked.
class BlockedUser {
  const BlockedUser({
    required this.username,
    this.displayName,
    required this.firstName,
    required this.surname,
    this.reason,
    required this.blockedAt,
  });

  final String username;
  final String? displayName;
  final String firstName;
  final String surname;
  final String? reason;
  final DateTime blockedAt;

  /// What to show as the name, preferring what they set themselves.
  String get name {
    final custom = displayName?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    final full = '$firstName $surname'.trim();
    return full.isEmpty ? username : full;
  }

  factory BlockedUser.fromJson(Map<String, dynamic> json) => BlockedUser(
    username: json['username'] as String? ?? '',
    displayName: json['display_name'] as String?,
    firstName: json['first_name'] as String? ?? '',
    surname: json['surname'] as String? ?? '',
    reason: json['reason'] as String?,
    blockedAt:
        DeviceSession._date(json['blocked_at']) ?? DateTime.now().toUtc(),
  );
}
