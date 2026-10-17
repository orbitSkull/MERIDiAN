import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/settings.dart' as model;
import '../../../services/api_client.dart';
import '../../../services/meridian_api.dart';
import '../../../services/settings_store.dart';
import '../widgets/settings_tile.dart';

/// People this account has blocked.
///
/// Blocking is a property of the account, not the device, so the list is read
/// from and written to the server. Keeping a local copy would mean unblocking on
/// a phone and still being blocked on a laptop.
///
/// The list deliberately does not say whether a handle exists. Blocking answers
/// the same way for a real handle, an unknown one and yourself, so this screen
/// cannot be used to find out who is registered on MERIDiAN.
class BlockListScreen extends StatefulWidget {
  const BlockListScreen({super.key, required this.api});

  final MeridianApi api;

  @override
  State<BlockListScreen> createState() => _BlockListScreenState();
}

class _BlockListScreenState extends State<BlockListScreen> {
  late Future<List<model.BlockedUser>> _load;
  String? _busyHandle;

  @override
  void initState() {
    super.initState();
    _load = widget.api.blockedUsers();
  }

  void _reload() {
    // The mounted guard is not decoration: a person can tap Unblock and go back
    // before the request answers, and setting state on a disposed State throws.
    if (!mounted) return;
    // A block, not an arrow. `() => _load = ...` returns the assigned Future, and
    // setState rejects a callback that returns one.
    setState(() {
      _load = widget.api.blockedUsers();
    });
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _unblock(model.BlockedUser user) async {
    setState(() => _busyHandle = user.username);
    try {
      await widget.api.unblock(user.username);
      _message('Unblocked @${user.username}.');
      _reload();
    } on ApiException catch (error) {
      _message(error.message);
    } finally {
      if (mounted) setState(() => _busyHandle = null);
    }
  }

  Future<void> _addBlocked() async {
    final added = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddBlockSheet(api: widget.api),
    );
    if (added == null || !mounted) return;
    _message('Blocked @$added.');
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: 'Block list',
      children: [
        FutureBuilder<List<model.BlockedUser>>(
          future: _load,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
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
                    Text(
                      snapshot.error is ApiException
                          ? (snapshot.error as ApiException).message
                          : 'Could not load your block list.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: _reload,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              );
            }
            final blocked = snapshot.data ?? const <model.BlockedUser>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsSection(
                  title: 'Blocked (${blocked.length})',
                  subtitle: 'Blocked people cannot message or call you.',
                  footer:
                      'Blocking is applied on your account, so it takes effect '
                      'on every device you are signed in to.',
                  children: blocked.isEmpty
                      ? [
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.block_outlined,
                                  size: 40,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'Nobody is blocked',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Add a handle below to block someone.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ]
                      : [
                          for (final user in blocked)
                            _BlockedTile(
                              user: user,
                              busy: _busyHandle == user.username,
                              onUnblock: () => _unblock(user),
                            ),
                        ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    onPressed: _addBlocked,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Block someone'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
        const SettingsSection(
          title: 'Blocked by others',
          subtitle:
              'People who have blocked you cannot be shown here. You will only '
              'notice when a message fails to send.',
          children: [
            ComingSoonTile(
              icon: Icons.block_outlined,
              title: 'Not available yet',
              subtitle: 'Requires a server endpoint to query',
            ),
          ],
        ),
        const SettingsSection(
          title: 'Preferences',
          children: [_BlockPreferences()],
        ),
      ],
    );
  }
}

class _BlockedTile extends StatelessWidget {
  const _BlockedTile({
    required this.user,
    required this.busy,
    required this.onUnblock,
  });

  final model.BlockedUser user;
  final bool busy;
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text(
          user.name.isEmpty ? '?' : user.name[0].toUpperCase(),
        ),
      ),
      title: Text(
        user.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          '@${user.username}',
          if (user.reason != null && user.reason!.isNotEmpty) user.reason!,
        ].join('  ·  '),
      ),
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(onPressed: onUnblock, child: const Text('Unblock')),
    );
  }
}

/// Sheet for blocking a handle.
///
/// Deliberately does not check whether the handle exists. The server refuses to
/// answer that question either, so adding a field here would only promise
/// something the API will not deliver.
class _AddBlockSheet extends StatefulWidget {
  const _AddBlockSheet({required this.api});

  final MeridianApi api;

  @override
  State<_AddBlockSheet> createState() => _AddBlockSheetState();
}

class _AddBlockSheetState extends State<_AddBlockSheet> {
  final TextEditingController _handle = TextEditingController();
  final TextEditingController _reason = TextEditingController();

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _handle.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.block(
        _handle.text.trim(),
        reason: _reason.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(_handle.text.trim());
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Block someone',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(
            'They will not be able to message or call you.',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _handle,
            autofocus: true,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Username',
              prefixText: '@  ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            onChanged: (_) => setState(() {}),
            maxLength: 280,
            decoration: const InputDecoration(
              labelText: 'Reason (optional)',
              helperText: 'Only you can see this.',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving || _handle.text.trim().isEmpty
                  ? null
                  : _submit,
              child: Text(_saving ? 'Blocking...' : 'Block'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlockPreferences extends StatelessWidget {
  const _BlockPreferences();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();

    return Column(
      children: [
        SettingsSwitchTile(
          icon: Icons.block_outlined,
          title: 'Block unknown callers',
          subtitle: 'Numbers and usernames not in your contacts',
          value: store.blockUnknownCallers,
          onChanged: store.setBlockUnknownCallers,
        ),
        SettingsSwitchTile(
          icon: Icons.visibility_off_outlined,
          title: 'Hide read receipts from blocked',
          subtitle: 'Do not tell them when you read a message',
          value: store.hideReadReceiptsFromBlocked,
          onChanged: store.setHideReadReceiptsFromBlocked,
        ),
      ],
    );
  }
}