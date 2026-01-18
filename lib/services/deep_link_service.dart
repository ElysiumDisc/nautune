import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Service for handling deep links and app links.
///
/// Supported link formats:
/// - nautune://syncplay/join/{groupId}
/// - https://nautune.app/syncplay/{groupId}
class DeepLinkService {
  DeepLinkService._();

  static final DeepLinkService _instance = DeepLinkService._();
  static DeepLinkService get instance => _instance;

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _subscription;

  // Stream for SyncPlay join requests
  final _syncPlayJoinController = StreamController<String>.broadcast();
  Stream<String> get syncPlayJoinStream => _syncPlayJoinController.stream;

  /// Initialize the deep link service
  Future<void> initialize() async {
    _appLinks = AppLinks();

    // Handle links when app is already running
    _subscription = _appLinks.uriLinkStream.listen(
      _handleUri,
      onError: (error) {
        debugPrint('DeepLinkService: Error receiving link: $error');
      },
    );

    // Check for initial link (app launched from link)
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _handleUri(initialUri);
      }
    } catch (e) {
      debugPrint('DeepLinkService: Failed to get initial link: $e');
    }
  }

  void _handleUri(Uri uri) {
    debugPrint('DeepLinkService: Received link: $uri');

    // Handle nautune:// scheme
    if (uri.scheme == 'nautune') {
      _handleNautuneLink(uri);
      return;
    }

    // Handle https://nautune.app links
    if (uri.scheme == 'https' && uri.host == 'nautune.app') {
      _handleWebLink(uri);
      return;
    }

    debugPrint('DeepLinkService: Unhandled link scheme: ${uri.scheme}');
  }

  void _handleNautuneLink(Uri uri) {
    // nautune://syncplay/join/{groupId}
    final pathSegments = uri.pathSegments;

    if (pathSegments.length >= 2 && pathSegments[0] == 'syncplay') {
      if (pathSegments[1] == 'join' && pathSegments.length >= 3) {
        final groupId = pathSegments[2];
        _syncPlayJoinController.add(groupId);
        debugPrint('DeepLinkService: SyncPlay join request for group: $groupId');
        return;
      }
    }

    debugPrint('DeepLinkService: Unhandled nautune link: $uri');
  }

  void _handleWebLink(Uri uri) {
    // https://nautune.app/syncplay/{groupId}
    final pathSegments = uri.pathSegments;

    if (pathSegments.isNotEmpty && pathSegments[0] == 'syncplay') {
      if (pathSegments.length >= 2) {
        final groupId = pathSegments[1];
        _syncPlayJoinController.add(groupId);
        debugPrint('DeepLinkService: SyncPlay join request for group: $groupId');
        return;
      }
    }

    debugPrint('DeepLinkService: Unhandled web link: $uri');
  }

  /// Parse a SyncPlay join link and extract the group ID
  static String? parseJoinLink(String link) {
    try {
      final uri = Uri.parse(link);

      // nautune://syncplay/join/{groupId}
      if (uri.scheme == 'nautune') {
        final pathSegments = uri.pathSegments;
        if (pathSegments.length >= 3 &&
            pathSegments[0] == 'syncplay' &&
            pathSegments[1] == 'join') {
          return pathSegments[2];
        }
      }

      // https://nautune.app/syncplay/{groupId}
      if (uri.scheme == 'https' && uri.host == 'nautune.app') {
        final pathSegments = uri.pathSegments;
        if (pathSegments.length >= 2 && pathSegments[0] == 'syncplay') {
          return pathSegments[1];
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Build a SyncPlay join link
  static String buildJoinLink(String groupId) {
    return 'nautune://syncplay/join/$groupId';
  }

  /// Build a SyncPlay join URL (for web sharing)
  static String buildJoinUrl(String groupId) {
    return 'https://nautune.app/syncplay/$groupId';
  }

  void dispose() {
    _subscription?.cancel();
    _syncPlayJoinController.close();
  }
}
