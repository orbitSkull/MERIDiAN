/// Call log entry and the filters the history screen offers.
///
/// UI-only for now: there is no call endpoint on the backend yet, so this is
/// a shape for the data rather than a decoded payload. The field names match
/// what a `GET /calls` response would use, so `fromJson` can be added without
/// renaming anything.
library;

enum CallDirection { incoming, outgoing }

enum CallKind {
  voice('Voice'),
  video('Video'),
  missedVoice('Missed voice'),
  missedVideo('Missed video');

  const CallKind(this.label);

  final String label;
}

enum CallFilter {
  all('All'),
  missed('Missed'),
  incoming('Incoming'),
  outgoing('Outgoing');

  const CallFilter(this.label);

  final String label;

  bool matches(CallLogEntry entry) => switch (this) {
    CallFilter.all => true,
    CallFilter.missed => entry.missed,
    CallFilter.incoming => entry.direction == CallDirection.incoming,
    CallFilter.outgoing => entry.direction == CallDirection.outgoing,
  };
}

class CallLogEntry {
  const CallLogEntry({
    required this.peerName,
    required this.peerHandle,
    required this.direction,
    required this.kind,
    required this.startedAt,
    this.durationSeconds,
    this.missed = false,
  });

  final String peerName;

  /// Username of the other party, when known. Not shown in the list but used
  /// for call-back and for a "who was this" lookup.
  final String peerHandle;
  final CallDirection direction;
  final CallKind kind;
  final DateTime startedAt;

  /// Null for a missed call, which never connected.
  final int? durationSeconds;
  final bool missed;

  /// `m:ss`, or `h:mm:ss` past an hour. Null for a missed call.
  String? get durationLabel {
    final seconds = durationSeconds;
    if (seconds == null) return null;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  /// Relative when recent, absolute otherwise, matching what people expect
  /// from a call log.
  String get whenLabel {
    final now = DateTime.now();
    final difference = now.difference(startedAt);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return 'Today, ${_clock(startedAt)}';
    if (difference.inDays < 7) return '${difference.inDays} days ago';
    return '${startedAt.day}/${startedAt.month}/${startedAt.year}';
  }

  static String _clock(DateTime value) {
    final h = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final m = value.minute.toString().padLeft(2, '0');
    return '$h:$m ${value.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// Placeholder entries so the layout can be reviewed before there is a server.
///
/// Timestamps are relative to now rather than fixed dates, otherwise the
/// "Today" and "Just now" branches would never be visible during review.
final demoCallLog = <CallLogEntry>[
  CallLogEntry(
    peerName: 'Meera Iyer',
    peerHandle: 'meera.iyer',
    direction: CallDirection.incoming,
    kind: CallKind.voice,
    startedAt: DateTime.now().subtract(const Duration(minutes: 8)),
    durationSeconds: 94,
  ),
  CallLogEntry(
    peerName: 'Ravi Menon',
    peerHandle: 'ravi.menon',
    direction: CallDirection.outgoing,
    kind: CallKind.video,
    startedAt: DateTime.now().subtract(const Duration(hours: 3)),
    durationSeconds: 1583,
  ),
  CallLogEntry(
    peerName: 'Unknown number',
    peerHandle: '',
    direction: CallDirection.incoming,
    kind: CallKind.missedVoice,
    startedAt: DateTime.now().subtract(const Duration(hours: 6)),
    missed: true,
  ),
  CallLogEntry(
    peerName: 'Meera Iyer',
    peerHandle: 'meera.iyer',
    direction: CallDirection.outgoing,
    kind: CallKind.voice,
    startedAt: DateTime.now().subtract(const Duration(days: 2)),
    durationSeconds: 31,
  ),
  CallLogEntry(
    peerName: 'Priya Nair',
    peerHandle: 'priya.nair',
    direction: CallDirection.incoming,
    kind: CallKind.missedVideo,
    startedAt: DateTime.now().subtract(const Duration(days: 3)),
    missed: true,
  ),
  CallLogEntry(
    peerName: 'Karthik Rao',
    peerHandle: 'karthik.rao',
    direction: CallDirection.outgoing,
    kind: CallKind.video,
    startedAt: DateTime.now().subtract(const Duration(days: 6)),
    durationSeconds: 742,
  ),
];