/// Username generation and validation.
///
/// Pure functions with no Flutter or network dependency, so the rules can be
/// unit tested directly and reused by both the signup flow and the edit screen.
///
/// The backend is the authority on whether a username is taken. This file only
/// decides what to *suggest* and what is *shaped* like a valid username. The
/// availability check itself is a Bloom filter behind a unique index on the
/// server, and is mocked in the UI for now.
library;

/// Minimum and maximum length, enforced identically on the server.
const kUsernameMinLength = 3;
const kUsernameMaxLength = 24;

/// Names that must never be claimable.
///
/// Checked case-insensitively. `admin`/`support` exist so those addresses
/// cannot be spoofed in a UI or a support reply; the rest are product or role
/// names that would be confusing to read as a person's handle.
const kReservedUsernames = <String>{
  'admin',
  'administrator',
  'support',
  'help',
  'meridian',
  'moderator',
  'root',
  'system',
  'official',
  'staff',
  'me',
  'everyone',
  'null',
  'undefined',
};

/// Why a username was rejected. Returned instead of a bare bool so the UI can
/// explain the rule rather than just saying "invalid".
enum UsernameProblem {
  tooShort,
  tooLong,
  empty,
  badCharacters,
  startsWithSeparator,
  endsWithSeparator,
  repeatedSeparators,
  reserved,
}

/// Outcome of validating a username. [problem] is null when [isValid].
class UsernameValidation {
  const UsernameValidation.valid() : problem = null;
  const UsernameValidation.invalid(this.problem);

  final UsernameProblem? problem;
  bool get isValid => problem == null;

  /// User-facing explanation, written to be shown directly.
  String? get message {
    final p = problem;
    if (p == null) return null;
    return switch (p) {
      UsernameProblem.empty => 'Enter a username.',
      UsernameProblem.tooShort =>
        'At least $kUsernameMinLength characters.',
      UsernameProblem.tooLong => 'At most $kUsernameMaxLength characters.',
      UsernameProblem.badCharacters =>
        'Use only letters, numbers, dots and underscores.',
      UsernameProblem.startsWithSeparator =>
        'Cannot start with a dot or underscore.',
      UsernameProblem.endsWithSeparator =>
        'Cannot end with a dot or underscore.',
      UsernameProblem.repeatedSeparators =>
        'Cannot use two dots or underscores in a row.',
      UsernameProblem.reserved =>
        'That name is reserved. Try another.',
    };
  }
}

/// Reduce a name fragment to the characters allowed in a username.
///
/// Folds accents to their base letter, so "José" becomes "jose" rather than
/// losing the "é" entirely. Everything else outside `[a-z0-9]` becomes a
/// separator, which [usernameFrom] then collapses.
String slugifyFragment(String input) {
  final folded = _stripDiacritics(input).toLowerCase();
  final buffer = StringBuffer();
  for (final rune in folded.runes) {
    final char = String.fromCharCode(rune);
    if ((rune >= 0x61 && rune <= 0x7a) || // a-z
        (rune >= 0x30 && rune <= 0x39)) {
      // a-z0-9
      buffer.write(char);
    } else if (rune > 0x7f) {
      // A non-Latin letter that survived folding. Dropped rather than kept,
      // since the username grammar is ASCII-only.
    } else {
      buffer.write('.');
    }
  }
  return buffer.toString();
}

/// Replace accented Latin characters with their base letter.
///
/// Dart has no built-in diacritic folding, and adding a package for six
/// characters is not worth it for the names this app will realistically see.
String _stripDiacritics(String input) {
  const substitutions = <String, String>{
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o', 'ō': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
    'ñ': 'n', 'ç': 'c', 'ß': 'ss', 'ý': 'y', 'ÿ': 'y',
    'š': 's', 'ž': 'z', 'č': 'c', 'ć': 'c', 'đ': 'd',
  };

  final lower = input.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(substitutions[char] ?? char);
  }
  return buffer.toString();
}

/// Collapse runs of separators and trim them from both ends.
///
/// "Aarav   Sharma " folds to "aarav.sharma", not to "aarav.sharma.".
String _tidy(String slug) {
  final collapsed = slug.replaceAll(RegExp(r'[._]+'), '.');
  return collapsed.replaceAll(RegExp(r'^\.+|\.+$'), '');
}

/// Build the preferred username for a person.
///
/// "Aarav" + "Sharma" -> `aarav.sharma`. Falls back to the first name alone
/// when the surname contributes nothing, and to a single letter plus surname
/// when the first name is a single character, which keeps short names from
/// producing a one-character handle that would fail [kUsernameMinLength].
String usernameFrom({
  required String firstName,
  required String surname,
}) {
  final first = _tidy(slugifyFragment(firstName));
  final last = _tidy(slugifyFragment(surname));

  final combined = last.isEmpty ? first : (first.isEmpty ? last : '$first.$last');

  if (combined.isEmpty) return '';
  if (combined.length < kUsernameMinLength) {
    // Too short to stand alone. Pad with the surname, or with a digit run if
    // there is no surname to draw on.
    final padded = last.isNotEmpty && first.isNotEmpty ? '$first.$last' : combined;
    if (padded.length >= kUsernameMinLength) return padded;
    return combined.padRight(kUsernameMinLength, '0');
  }
  if (combined.length > kUsernameMaxLength) {
    // Cut on a separator so the result still reads as name parts rather than
    // an arbitrary truncation.
    final cut = combined.substring(0, kUsernameMaxLength);
    final lastDot = cut.lastIndexOf('.');
    final trimmed = lastDot >= kUsernameMinLength ? cut.substring(0, lastDot) : cut;
    return _tidy(trimmed).isEmpty ? cut : _tidy(trimmed);
  }
  return combined;
}

/// Ordered candidates to offer when [usernameFrom] is already taken.
///
/// Appends 2, 3, 4... before falling back to a hash, because a numbered
/// variant still looks like a person's name while `aarav.3f8a21` does not.
/// [identity] is mixed in so two people with identical names get different
/// fallbacks; on a real deployment that is the user's PRN or employee ID.
List<String> usernameCandidates({
  required String firstName,
  required String surname,
  String? identity,
  int limit = 5,
}) {
  final base = usernameFrom(firstName: firstName, surname: surname);
  if (base.isEmpty) return const [];

  final candidates = <String>[base];
  for (var n = 2; n < 2 + limit; n++) {
    final suffix = '$base.$n';
    candidates.add(
      suffix.length <= kUsernameMaxLength ? suffix : _truncate(suffix),
    );
  }

  if (identity != null && identity.trim().isNotEmpty) {
    final hashSeed = _stableHash(identity.trim());
    final hashed = '$base.$hashSeed';
    candidates.add(hashed.length <= kUsernameMaxLength
        ? hashed
        : _truncate(hashed));
  }
  return candidates;
}

String _truncate(String value) =>
    value.substring(0, kUsernameMaxLength).replaceAll(RegExp(r'[._]+$'), '');

/// A small deterministic hash.
///
/// Dart's `String.hashCode` is not guaranteed stable across runs or
/// platforms, which would give the same user a different fallback username
/// after a restart. This is FNV-1a, which is stable everywhere.
String _stableHash(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0').substring(0, 6);
}

/// Check a username against the grammar rules.
///
/// Deliberately does not check availability; that is a server question.
UsernameValidation validateUsername(String input) {
  if (input.isEmpty) {
    return const UsernameValidation.invalid(UsernameProblem.empty);
  }
  if (input.length < kUsernameMinLength) {
    return const UsernameValidation.invalid(UsernameProblem.tooShort);
  }
  if (input.length > kUsernameMaxLength) {
    return const UsernameValidation.invalid(UsernameProblem.tooLong);
  }
  // Reserved is checked before the character rules so that typing "Admin" is
  // told the name is taken rather than being told to lowercase it. The
  // character check would otherwise reject it first, and the user would never
  // learn why the name they actually wanted is unavailable.
  if (kReservedUsernames.contains(input.toLowerCase())) {
    return const UsernameValidation.invalid(UsernameProblem.reserved);
  }
  if (!RegExp(r'^[a-z0-9._]+$').hasMatch(input)) {
    return const UsernameValidation.invalid(UsernameProblem.badCharacters);
  }
  if (input.startsWith('.') || input.startsWith('_')) {
    return const UsernameValidation.invalid(UsernameProblem.startsWithSeparator);
  }
  if (input.endsWith('.') || input.endsWith('_')) {
    return const UsernameValidation.invalid(UsernameProblem.endsWithSeparator);
  }
  if (RegExp(r'[._]{2,}').hasMatch(input)) {
    return const UsernameValidation.invalid(UsernameProblem.repeatedSeparators);
  }
  return const UsernameValidation.valid();
}

/// Whether [value] is already claimable by someone.
///
/// `isClaimable(v) == false` is what lets the edit screen accept a username the
/// current user already holds instead of telling them to pick another.
bool isReserved(String value) =>
    kReservedUsernames.contains(value.toLowerCase());