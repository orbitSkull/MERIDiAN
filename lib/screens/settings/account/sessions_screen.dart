import 'package:flutter/material.dart';

import '../../../models/settings.dart';
import '../../../services/api_client.dart';
import '../../../services/meridian_api.dart';
import '../widgets/settings_tile.dart';

/// Devices signed in to this account.
///
/// Reads like a security screen, so it is built to be legible under pressure:
/// the current device is marked, the timestamps say when rather than how long
/// ago, and revoking is behind a confirmation naming the device. Signing
/// yourself out of the phone in your hand is an easy mistake to make and an
/// annoying one to undo.
///
/// The current device comes from the server, which identifies it by the session
/// claim inside the access token. The app does not try to work it out from the
/// device, because two devices look identical from here.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.api});

  final MeridianApi api;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  late Future<List<DeviceSession>> _load;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load = widget.api.sessions();
  }

  void _reload() {
    // Guarded, and block-bodied: a person can leave this screen while a revoke
    // is still in flight, and an arrow closure here would hand setState the
    // assigned Future, which it rejects.
    if (!mounted) return;
    setState(() {
      _load = widget.api.sessions();
    });
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _revoke(DeviceSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out this device?'),
        content: Text(
          session.isCurrent
              // Revoking the device you are using is not an error, but it ends
              // the session immediately, so it is called out rather than hidden
              // behind the same wording as the others.
              ? 'This is the device you are using. You will be signed out and '
                    'asked to sign in again.'
              : '${session.displayName} will have to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyId = '${session.id}');
    try {
      await widget.api.revokeSession(session.id);
      _message('Signed out ${session.displayName}.');
      _reload();
    } on ApiException catch (error) {
      _message(error.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _revokeOthers() async {
    // The dialog needs a count, which means a read before the tap. Guarded on
    // mounted because the screen can be popped while that read is in flight,
    // and showing a dialog for a screen that is gone throws.
    final sessions = await widget.api.sessions();
    if (!mounted) return;
    final count = sessions.where((s) => !s.isCurrent).length;
    if (count == 0) {
      _message('No other devices are signed in.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sign out $count other device${count == 1 ? '' : 's'}?'),
        content: const Text('This device stays signed in.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyId = 'others');
    try {
      await widget.api.revokeOtherSessions();
      _message('Signed out $count device${count == 1 ? '' : 's'}.');
      _reload();
    } on ApiException catch (error) {
      _message(error.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Active sessions',
      children: [
        FutureBuilder<List<DeviceSession>>(
          future: _load,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _ErrorView(
                message: snapshot.error is ApiException
                    ? (snapshot.error as ApiException).message
                    : 'Could not load your sessions.',
                onRetry: _reload,
              );
            }
            final sessions = snapshot.data ?? const <DeviceSession>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsSection(
                  title: 'Signed in',
                  subtitle:
                      'If you do not recognise a device, sign it out and '
                      'change your password.',
                  children: [
                    for (final session in sessions)
                      _SessionTile(
                        session: session,
                        busy: _busyId == '${session.id}',
                        onRevoke: () => _revoke(session),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    onPressed: _busyId == 'others' ? null : _revokeOthers,
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text('Sign out other devices'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.busy,
    required this.onRevoke,
  });

  final DeviceSession session;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      icon: session.isCurrent
          ? Icons.smartphone_rounded
          : Icons.devices_other_rounded,
      title: session.displayName,
      subtitle: _subtitle(),
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: 'Sign out this device',
              onPressed: onRevoke,
              icon: const Icon(Icons.logout_rounded, size: 20),
            ),
    );
  }

  String _subtitle() {
    final parts = <String>[];
    if (session.isCurrent) parts.add('This device');
    final last = session.lastUsedAt;
    if (last != null) {
      parts.add('Last used ${_relative(last)}');
    } else {
      // Not "never". The honest reading of no timestamp is that the server has
      // not seen this device refresh yet.
      parts.add('Signed in ${_relative(session.createdAt)}');
    }
    return parts.join('  ·  ');
  }

  /// "just now", "3 days ago".
  ///
  /// Absolute dates make it impossible to scan a list for the one device that
  /// has been idle for months, which is the thing being looked for.
  static String _relative(DateTime when) {
    final difference = DateTime.now().toUtc().difference(when.toUtc());
    if (difference.isNegative || difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) {
      final hours = difference.inHours;
      return '$hours hour${hours == 1 ? '' : 's'} ago';
    }
    final days = difference.inDays;
    if (days < 30) return '$days day${days == 1 ? '' : 's'} ago';
    final months = days ~/ 30;
    return '$months month${months == 1 ? '' : 's'} ago';
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 40,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
