import 'dart:async';

import '../services/api_client.dart';
import '../services/meridian_api.dart';

/// Short-lived links to media, remembered until they lapse.
///
/// Every link is issued against a membership check and dies after a few
/// minutes, so an image list has two costs to avoid paying on every rebuild:
/// asking the server again for a link it already gave out, and decoding the same
/// photograph again because the widget was rebuilt.
///
/// Links are kept per media id rather than per widget, because the same
/// photograph appears in more than one place at once and a cache keyed by widget
/// would fetch it once per place.
///
/// A link is discarded slightly before it actually expires. Fetching one at the
/// last moment and having it die mid-decode shows a broken image, and the cost of
/// asking again thirty seconds early is one request.
class MediaCache {
  MediaCache(this._api);

  final MeridianApi _api;
  final Map<int, _Link> _links = {};

  /// In-flight requests, so ten bubbles for one photograph make one call.
  final Map<int, Future<String?>> _pending = {};

  /// How long before real expiry a link is treated as spent.
  static const _safetyMargin = Duration(seconds: 45);

  /// The current link for [mediaId], fetching one if there is none worth having.
  ///
  /// Null means the server declined: the file expired, or the person asking is
  /// not in the conversation. Both are rendered as a placeholder rather than as
  /// an error, because from the reader's side they are the same thing -- there is
  /// nothing there to show.
  Future<String?> urlFor(int mediaId) async {
    final held = _links[mediaId];
    if (held != null && held.isUsable) return held.url;

    final inFlight = _pending[mediaId];
    if (inFlight != null) return inFlight;

    final request = _fetch(mediaId);
    _pending[mediaId] = request;
    try {
      return await request;
    } finally {
      _pending.remove(mediaId);
    }
  }

  Future<String?> _fetch(int mediaId) async {
    try {
      final link = await _api.mediaLink(mediaId);
      _links[mediaId] = _Link(
        url: link.url,
        usableUntil: DateTime.now().add(
          Duration(seconds: link.expiresInSeconds),
        ),
      );
      return link.url;
    } on ApiException {
      // Not cached. A missing file will keep missing, but a network blip will
      // not, and caching the failure would turn one dropped connection into a
      // permanently blank bubble.
      return null;
    }
  }

  /// Drop one link, e.g. after the server says the file has gone.
  void forget(int mediaId) => _links.remove(mediaId);

  /// Drop everything.
  ///
  /// Called on sign-out: these links were issued to a session that has ended, and
  /// a cache of them outliving the account is exactly the sort of thing that
  /// should not be left lying around.
  void clear() {
    _links.clear();
    _pending.clear();
  }
}

class _Link {
  _Link({required this.url, required this.usableUntil});

  final String url;
  final DateTime usableUntil;

  bool get isUsable => DateTime.now().isBefore(usableUntil.subtract(
    MediaCache._safetyMargin,
  ));
}