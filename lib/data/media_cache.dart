import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../services/api_client.dart';
import '../services/meridian_api.dart';

/// Photographs, kept on disk so they are there without a network.
///
/// The problem this solves: a signed link lasts five minutes and an offline
/// device cannot get one at all. So a photo that is only ever a URL is a photo
/// that disappears the moment the phone loses signal -- which means "offline
/// viewing", the thing everybody expects a chat app to do, quietly does not
/// work for messages carrying images.
///
/// Every file downloaded once is written under the app's support directory,
/// keyed by media id. That directory is the app's own, not the gallery, so the
/// user is not accumulating copies of other people's photographs in their
/// camera roll and the files go when the app is removed.
///
/// Media expires server-side after seven days, so nothing here is an archive
/// that will quietly outlive its own permission to exist; the retention pass on
/// the server drops the rows and the bytes stop being reachable.
class MediaCache {
  MediaCache(this._api, {Directory? directory}) : _overrideDirectory = directory;

  final MeridianApi _api;

  /// Where files go, when the caller knows.
  ///
  /// Injectable because the real location needs a platform channel, and a cache
  /// whose only test is "does it work on a phone" is a cache nobody runs the
  /// tests for. Null in production, which asks the platform.
  final Directory? _overrideDirectory;

  /// Links we have been given, and when each stops being useful.
  final Map<int, _Link> _links = {};

  /// Downloads in flight, so ten bubbles showing one photograph make one
  /// request rather than ten.
  final Map<int, Future<File?>> _pending = {};

  /// How long before real expiry a link is treated as spent.
  static const _safetyMargin = Duration(seconds: 45);

  /// Whether a file is already on disk.
  ///
  /// Synchronous on purpose: this is called during build, and answering "have we
  /// got it" should not need a microtask before a placeholder can be skipped.
  File? cachedFile(int mediaId) {
    final path = _paths[mediaId];
    if (path == null) return null;
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  /// Whether we have already looked, so an absent file is not re-checked on
  /// every rebuild.
  final Set<int> _checked = {};

  bool hasChecked(int mediaId) => _checked.contains(mediaId);

  final Map<int, String> _paths = {};

  /// Get a file on disk, downloading it if there is a connection and it is not
  /// there yet.
  ///
  /// Null means "not available right now", which is a different thing from
  /// "gone": a photo that has never been downloaded and a photo whose download
  /// just failed both render as a placeholder, and a failed download is not
  /// remembered as a missing photo so it is retried next time.
  Future<File?> file(int mediaId) async {
    final existing = cachedFile(mediaId);
    if (existing != null) return existing;

    final inFlight = _pending[mediaId];
    if (inFlight != null) return inFlight;

    final request = _download(mediaId);
    _pending[mediaId] = request;
    try {
      return await request;
    } finally {
      _pending.remove(mediaId);
    }
  }

  Future<File?> _download(int mediaId) async {
    try {
      final link = await _api.mediaLink(mediaId);
      if (link.url.isEmpty) return null;

      _links[mediaId] = _Link(
        url: link.url,
        usableUntil: DateTime.now().add(
          Duration(seconds: link.expiresInSeconds),
        ),
      );

      final response = await _api.fetchBytes(link.url);
      if (response == null || response.isEmpty) return null;

      final target = File('${(await _directory()).path}/media_$mediaId');
      await target.writeAsBytes(response, flush: true);
      _paths[mediaId] = target.path;
      return target;
    } on ApiException {
      return null;
    } on Object {
      // No network, DNS gone, disk full. Any of them means "not now" rather than
      // "never", so nothing is cached as a permanent failure.
      return null;
    }
  }

  /// Rebuild the id-to-path index from what is actually on disk.
  ///
  /// Called once at startup, because the file names carry the media id and
  /// nothing else remembers the mapping: an in-memory map built on download is
  /// empty again on the next launch, and every photo would look like it had
  /// never been seen.
  Future<void> reindex() async {
    try {
      final directory = await _directory();
      final entities = await directory.list().toList();
      for (final entity in entities) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('media_')) continue;
        final id = int.tryParse(name.substring('media_'.length));
        if (id == null) continue;
        _paths[id] = entity.path;
        _checked.add(id);
      }
    } on Object {
      // An unreadable cache directory is not worth failing a launch over. It
      // only means photos are re-downloaded.
    }
  }

  Future<Directory> _directory() async {
    final override = _overrideDirectory;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/media');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Forget a file, e.g. after the server says it has expired.
  void forget(int mediaId) {
    final path = _paths.remove(mediaId);
    if (path != null) {
      unawaited(File(path).delete().catchError((_) => File(path)));
    }
    _links.remove(mediaId);
    _checked.add(mediaId);
  }

  /// Forget everything.
  ///
  /// Called on sign-out. These are other people's photographs sitting in this
  /// app's storage, and they have no business outliving the account.
  Future<void> clear() async {
    _links.clear();
    _pending.clear();
    _checked.clear();
    _paths.clear();
    try {
      final directory = await _directory();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on Object {
      // Best effort. Sign-out has already happened by this point.
    }
  }
}

/// A signed link, and when it stops being worth using.
class _Link {
  _Link({required this.url, required this.usableUntil});

  final String url;
  final DateTime usableUntil;

  bool get isUsable =>
      DateTime.now().isBefore(usableUntil.subtract(MediaCache._safetyMargin));
}