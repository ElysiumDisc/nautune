import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A robust HTTP client with:
/// - Connection pooling (reuses single client instance)
/// - Automatic retry with exponential backoff (GET always; POST/DELETE only
///   when the failure proves the request never reached the server)
/// - Request timeout handling
/// - ETag/Last-Modified caching support
class RobustHttpClient {
  RobustHttpClient({
    http.Client? client,
    this.maxRetries = 3,
    this.baseTimeout = const Duration(seconds: 15),
    this.enableEtagCache = true,
    this.maxCacheSize = 500,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  /// Expose underlying client for backward compatibility (avoid creating new clients)
  http.Client get client => _client;
  final int maxRetries;
  final Duration baseTimeout;
  final bool enableEtagCache;
  final int maxCacheSize;

  // ETag cache: URL -> {etag, lastModified, body}
  // Uses LinkedHashMap for O(1) LRU eviction (access order)
  final Map<String, _CachedResponse> _etagCache = {};
  // Track insertion order for LRU using a Set for O(1) removal
  final _cacheOrder = <String>{}; // LinkedHashSet for O(1) add/remove

  /// GET request with retry and optional ETag caching
  Future<http.Response> get(
    Uri uri, {
    Map<String, String>? headers,
    bool useCache = true,
    Duration? timeout,
  }) async {
    final effectiveHeaders = Map<String, String>.from(headers ?? {});
    
    // Add ETag/Last-Modified headers if we have cached response
    if (enableEtagCache && useCache) {
      final cached = _etagCache[uri.toString()];
      if (cached != null) {
        if (cached.etag != null) {
          effectiveHeaders['If-None-Match'] = cached.etag!;
        }
        if (cached.lastModified != null) {
          effectiveHeaders['If-Modified-Since'] = cached.lastModified!;
        }
      }
    }

    return _executeWithRetry(
      () => _client.get(uri, headers: effectiveHeaders).timeout(
        timeout ?? baseTimeout,
        onTimeout: () => throw HttpTimeoutException('Request timed out', timeout ?? baseTimeout),
      ),
      uri: uri,
      useCache: useCache,
      idempotent: true,
    );
  }

  /// POST request.
  ///
  /// POST is not idempotent (creating a playlist or adding items twice
  /// duplicates them), so by default it is only retried when the connection
  /// could not be established at all. Pass [idempotent] = true for
  /// read-only POST endpoints (e.g. PlaybackInfo) to allow full retries.
  Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
    bool idempotent = false,
  }) async {
    return _executeWithRetry(
      () => _client.post(
        uri,
        headers: headers,
        body: body is String ? body : (body != null ? jsonEncode(body) : null),
      ).timeout(
        timeout ?? baseTimeout,
        onTimeout: () => throw HttpTimeoutException('Request timed out', timeout ?? baseTimeout),
      ),
      uri: uri,
      useCache: false,
      idempotent: idempotent,
    );
  }

  /// DELETE request. Only retried when the connection could not be
  /// established (see [post]).
  Future<http.Response> delete(
    Uri uri, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    return _executeWithRetry(
      () => _client.delete(uri, headers: headers).timeout(
        timeout ?? baseTimeout,
        onTimeout: () => throw HttpTimeoutException('Request timed out', timeout ?? baseTimeout),
      ),
      uri: uri,
      useCache: false,
      idempotent: false,
    );
  }

  Future<http.Response> _executeWithRetry(
    Future<http.Response> Function() request, {
    required Uri uri,
    required bool useCache,
    required bool idempotent,
  }) async {
    int attempt = 0;
    Object? lastError;

    while (attempt < maxRetries) {
      try {
        final response = await request();

        // Handle 304 Not Modified - return cached response
        if (response.statusCode == 304 && enableEtagCache && useCache) {
          final cached = _etagCache[uri.toString()];
          if (cached != null) {
            debugPrint('📦 Cache hit (304): $uri');
            return http.Response(
              cached.body,
              200,
              headers: response.headers,
              request: response.request,
            );
          }
        }

        // Cache successful GET responses with ETag/Last-Modified
        if (response.statusCode == 200 && enableEtagCache && useCache) {
          final etag = response.headers['etag'];
          final lastModified = response.headers['last-modified'];
          if (etag != null || lastModified != null) {
            _addToCache(
              uri.toString(),
              _CachedResponse(
                etag: etag,
                lastModified: lastModified,
                body: response.body,
                cachedAt: DateTime.now(),
              ),
            );
          }
        }

        // The server received a non-idempotent request: never replay it,
        // whatever the status (a 5xx may still have applied the change).
        if (!idempotent) {
          return response;
        }

        // Don't retry on client errors (4xx) except 408, 429
        if (response.statusCode >= 400 && response.statusCode < 500) {
          if (response.statusCode != 408 && response.statusCode != 429) {
            return response;
          }
        }

        // Success or server error that we won't retry
        if (response.statusCode < 500) {
          return response;
        }

        // Server error (5xx) - retry
        lastError = 'Server error: ${response.statusCode}';
        debugPrint('⚠️ Retry $attempt/$maxRetries: $lastError');
        
      } on HttpTimeoutException catch (e) {
        lastError = e;
        if (!idempotent) {
          // The request may already have been processed; don't replay it.
          throw ServerSlowException(
            'Server is taking too long to respond. Check your connection or try again later.',
            uri: uri,
          );
        }
        debugPrint('⚠️ Timeout retry $attempt/$maxRetries: $uri');
      } catch (e) {
        lastError = e;
        if (!idempotent && !isConnectionEstablishmentFailure(e)) {
          throw RobustHttpException(
            'Request failed (not retried: non-idempotent)',
            uri: uri,
            lastError: e,
          );
        }
        debugPrint('⚠️ Error retry $attempt/$maxRetries: $e');
      }

      attempt++;
      
      if (attempt < maxRetries) {
        // Exponential backoff with up to 30% jitter to prevent thundering herd
        final baseMs = pow(2, attempt).toInt() * 500;
        final jitter = (baseMs * 0.3 * Random().nextDouble()).toInt();
        final delay = Duration(milliseconds: baseMs + jitter);
        debugPrint('⏳ Waiting ${delay.inMilliseconds}ms before retry...');
        await Future.delayed(delay);
      }
    }

    // All retries exhausted - provide user-friendly error
    if (lastError is HttpTimeoutException) {
      throw ServerSlowException(
        'Server is taking too long to respond. Check your connection or try again later.',
        uri: uri,
      );
    }
    
    throw RobustHttpException(
      'Request failed after $maxRetries attempts',
      uri: uri,
      lastError: lastError,
    );
  }

  /// True when [error] proves the request never reached the server (DNS
  /// failure, connection refused/unreachable, TLS handshake failure), so a
  /// non-idempotent request can be safely retried.
  static bool isConnectionEstablishmentFailure(Object error) {
    if (error is HandshakeException) return true;
    String? message;
    if (error is SocketException) {
      message = '${error.message} ${error.osError?.message ?? ''}';
    } else if (error is http.ClientException) {
      message = error.message;
    }
    if (message == null) return false;
    final m = message.toLowerCase();
    const preSendMarkers = [
      'failed host lookup',
      'connection refused',
      'network is unreachable',
      'no route to host',
      'host is down',
      'nodename nor servname',
      'no address associated',
    ];
    return preSendMarkers.any(m.contains);
  }

  /// Add entry to cache with LRU eviction
  void _addToCache(String url, _CachedResponse response) {
    // If already in cache, update (remove+re-add moves to end of iteration order)
    if (_etagCache.containsKey(url)) {
      _cacheOrder.remove(url);
      _cacheOrder.add(url);
      _etagCache[url] = response;
      return;
    }

    // Evict oldest entries if at capacity
    while (_etagCache.length >= maxCacheSize && _cacheOrder.isNotEmpty) {
      final oldest = _cacheOrder.first;
      _cacheOrder.remove(oldest);
      _etagCache.remove(oldest);
    }

    // Add new entry
    _etagCache[url] = response;
    _cacheOrder.add(url);
  }

  /// Clear the ETag cache
  void clearCache() {
    _etagCache.clear();
    _cacheOrder.clear();
  }

  /// Clear cache entries older than duration
  void clearOldCache(Duration maxAge) {
    final now = DateTime.now();
    final keysToRemove = <String>[];
    _etagCache.forEach((key, cached) {
      if (now.difference(cached.cachedAt) > maxAge) {
        keysToRemove.add(key);
      }
    });
    for (final key in keysToRemove) {
      _etagCache.remove(key);
      _cacheOrder.remove(key);
    }
  }

  /// Close the underlying HTTP client
  void close() {
    _client.close();
  }
}

class _CachedResponse {
  final String? etag;
  final String? lastModified;
  final String body;
  final DateTime cachedAt;

  _CachedResponse({
    this.etag,
    this.lastModified,
    required this.body,
    required this.cachedAt,
  });
}

class RobustHttpException implements Exception {
  final String message;
  final Uri uri;
  final Object? lastError;

  RobustHttpException(this.message, {required this.uri, this.lastError});

  @override
  String toString() => 'RobustHttpException: $message (uri: $uri, lastError: $lastError)';
}

/// Timeout exception for clearer error messages
class HttpTimeoutException implements Exception {
  final String message;
  final Duration timeout;

  HttpTimeoutException(this.message, this.timeout);

  @override
  String toString() => 'HttpTimeoutException: $message (after ${timeout.inSeconds}s)';
}

/// User-friendly exception for slow server responses
class ServerSlowException implements Exception {
  final String message;
  final Uri uri;

  ServerSlowException(this.message, {required this.uri});

  @override
  String toString() => message;
}
