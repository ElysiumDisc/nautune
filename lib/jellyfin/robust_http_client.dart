import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A robust HTTP client with:
/// - Connection pooling (reuses single client instance)
/// - Automatic retry with exponential backoff
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
  final int maxRetries;
  final Duration baseTimeout;
  final bool enableEtagCache;
  final int maxCacheSize;

  // ETag cache: URL -> {etag, lastModified, body}
  // LRU eviction is applied when cache exceeds maxCacheSize
  final Map<String, _CachedResponse> _etagCache = {};
  final List<String> _cacheOrder = []; // Track insertion order for LRU

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
        onTimeout: () => throw TimeoutException('Request timed out', timeout ?? baseTimeout),
      ),
      uri: uri,
      useCache: useCache,
    );
  }

  /// POST request with retry
  Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    return _executeWithRetry(
      () => _client.post(
        uri,
        headers: headers,
        body: body is String ? body : (body != null ? jsonEncode(body) : null),
      ).timeout(
        timeout ?? baseTimeout,
        onTimeout: () => throw TimeoutException('Request timed out', timeout ?? baseTimeout),
      ),
      uri: uri,
      useCache: false,
    );
  }

  /// DELETE request with retry
  Future<http.Response> delete(
    Uri uri, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    return _executeWithRetry(
      () => _client.delete(uri, headers: headers).timeout(
        timeout ?? baseTimeout,
        onTimeout: () => throw TimeoutException('Request timed out', timeout ?? baseTimeout),
      ),
      uri: uri,
      useCache: false,
    );
  }

  Future<http.Response> _executeWithRetry(
    Future<http.Response> Function() request, {
    required Uri uri,
    required bool useCache,
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
        
      } on TimeoutException catch (e) {
        lastError = e;
        debugPrint('⚠️ Timeout retry $attempt/$maxRetries: $uri');
      } on http.ClientException catch (e) {
        lastError = e;
        debugPrint('⚠️ Client error retry $attempt/$maxRetries: $e');
      } catch (e) {
        lastError = e;
        debugPrint('⚠️ Unknown error retry $attempt/$maxRetries: $e');
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
    if (lastError is TimeoutException) {
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

  /// Add entry to cache with LRU eviction
  void _addToCache(String url, _CachedResponse response) {
    // If already in cache, update and move to end (most recently used)
    if (_etagCache.containsKey(url)) {
      _cacheOrder.remove(url);
      _cacheOrder.add(url);
      _etagCache[url] = response;
      return;
    }

    // Evict oldest entries if at capacity
    while (_etagCache.length >= maxCacheSize && _cacheOrder.isNotEmpty) {
      final oldest = _cacheOrder.removeAt(0);
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
class TimeoutException implements Exception {
  final String message;
  final Duration timeout;

  TimeoutException(this.message, this.timeout);

  @override
  String toString() => 'TimeoutException: $message (after ${timeout.inSeconds}s)';
}

/// User-friendly exception for slow server responses
class ServerSlowException implements Exception {
  final String message;
  final Uri uri;

  ServerSlowException(this.message, {required this.uri});

  @override
  String toString() => message;
}
