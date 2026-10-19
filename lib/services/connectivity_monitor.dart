import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Whether this device has a way to reach the network, answered locally.
///
/// Asked and answered entirely on the phone: the operating system knows which
/// radios are up, and asking it costs nothing and takes no time. No request goes
/// anywhere, which matters because this is consulted on every keystroke to
/// decide whether the send button is live -- a check that needed a round trip
/// would be both slow and pointless.
///
/// What it reports is the *radio*, not the internet: a phone showing four bars
/// behind a lift door reports "connected" and every request will fail. So this
/// drives the button's state, and [report] lets the outcome of a real request
/// correct it afterwards. Neither is trusted alone, which is why the app does
/// not claim to know the truth -- it says "we think".
class ConnectivityMonitor extends ChangeNotifier {
  ConnectivityMonitor({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  bool _online = true;
  bool _known = false;

  /// False once something has actually said there is no network.
  ///
  /// Distinct from "online": before the first answer the honest state is "do not
  /// know", and treating that as offline would grey out the send button on every
  /// cold start.
  bool get isOnline => _online;

  bool get isKnown => _known;

  StreamSubscription<List<ConnectivityResult>>? _subscription;

  /// Begin watching. Separate from the constructor so a test can assert against
  /// the values it sets without a platform channel.
  void start() {
    _subscription ??= _connectivity.onConnectivityChanged.listen(_apply);
    // Asked once at startup too, so the button is right before the first change
    // arrives rather than assuming a default for the first few seconds.
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      _apply(await _connectivity.checkConnectivity());
    } on Object catch (error) {
      // A platform that cannot answer is not evidence of no network. Guessing
      // "offline" here would grey out the send button on every device where the
      // plugin is unavailable, including the web build.
      debugPrint('Connectivity check unavailable: $error');
    }
  }

  void _apply(List<ConnectivityResult> results) {
    // The list form exists for platforms that can be on several interfaces at
    // once; "none" is the only answer that means there is no way out.
    final online = results.isNotEmpty && !results.contains(ConnectivityResult.none);
    if (_known && _online == online) return;
    _online = online;
    _known = true;
    notifyListeners();
  }

  /// Correct the answer using the outcome of a real request.
  ///
  /// The radio said yes and the server said no, or the other way round. This is
  /// the signal that actually follows reality, so it is allowed to disagree.
  void report({required bool succeeded}) {
    if (_known && _online == succeeded) return;
    _online = succeeded;
    _known = true;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}