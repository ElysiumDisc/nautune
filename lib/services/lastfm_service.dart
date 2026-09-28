import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../jellyfin/jellyfin_track.dart';
import 'hive_init.dart';

/// Last.fm `api_sig`: md5 of every parameter (except `format` and
/// `callback`) as `name` + `value`, sorted by name, followed by the secret.
String lastFmSignature(Map<String, String> params, String secret) {
  final keys = params.keys
      .where((k) => k != 'format' && k != 'callback')
      .toList()
    ..sort();
  final buffer = StringBuffer();
  for (final k in keys) {
    buffer
      ..write(k)
      ..write(params[k]);
  }
  buffer.write(secret);
  return md5.convert(utf8.encode(buffer.toString())).toString();
}

/// One play waiting to be sent to Last.fm.
class LastFmScrobble {
  const LastFmScrobble({
    required this.artist,
    required this.track,
    required this.timestamp,
    this.album,
    this.durationSeconds,
  });

  final String artist;
  final String track;
  final String? album;

  /// Seconds since epoch when the track started playing.
  final int timestamp;
  final int? durationSeconds;

  Map<String, dynamic> toJson() => {
        'artist': artist,
        'track': track,
        'album': album,
        'timestamp': timestamp,
        'duration': durationSeconds,
      };

  static LastFmScrobble? fromJson(Object? json) {
    if (json is! Map) return null;
    final artist = json['artist'];
    final track = json['track'];
    final ts = json['timestamp'];
    if (artist is! String || track is! String || ts is! num) return null;
    return LastFmScrobble(
      artist: artist,
      track: track,
      album: json['album'] as String?,
      timestamp: ts.toInt(),
      durationSeconds: (json['duration'] as num?)?.toInt(),
    );
  }
}

/// Batch parameters for `track.scrobble` (`artist[0]`, `track[0]`, …).
Map<String, String> lastFmScrobbleParams(List<LastFmScrobble> batch) {
  final params = <String, String>{};
  for (var i = 0; i < batch.length; i++) {
    final s = batch[i];
    params['artist[$i]'] = s.artist;
    params['track[$i]'] = s.track;
    params['timestamp[$i]'] = '${s.timestamp}';
    if (s.album != null && s.album!.isNotEmpty) params['album[$i]'] = s.album!;
    if (s.durationSeconds != null) params['duration[$i]'] = '${s.durationSeconds}';
  }
  return params;
}

/// Last.fm scrobbling with the user's own API account (Last.fm requires an
/// API key and secret per application). Credentials and the session key are
/// kept in the Keychain; plays that fail to send are queued in Hive and
/// retried, like ListenBrainz.
class LastFmService extends ChangeNotifier {
  LastFmService._();
  static final LastFmService instance = LastFmService._();
  factory LastFmService() => instance;

  static const _endpoint = 'https://ws.audioscrobbler.com/2.0/';
  static const _secureKey = 'lastfm_config';
  static const _queueBox = 'lastfm_queue';
  static const _queueKey = 'pending';
  static const int _maxQueue = 1000;
  static const int _batchSize = 50;

  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  http.Client _http = http.Client();

  String? _apiKey;
  String? _secret;
  String? _sessionKey;
  String? _username;
  bool _enabled = true;
  bool _initialized = false;
  List<LastFmScrobble> _pending = [];
  Future<void>? _flushing;

  bool get isConfigured => _sessionKey != null && _apiKey != null && _secret != null;
  bool get isScrobblingEnabled => isConfigured && _enabled;
  String? get username => _username;
  int get pendingCount => _pending.length;

  @visibleForTesting
  set httpClient(http.Client client) => _http = client;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final raw = await _secure.read(key: _secureKey);
      if (raw != null) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _apiKey = json['apiKey'] as String?;
        _secret = json['secret'] as String?;
        _sessionKey = json['sessionKey'] as String?;
        _username = json['username'] as String?;
        _enabled = json['enabled'] as bool? ?? true;
      }
      await ensureHiveInitialized();
      final box = await Hive.openBox<dynamic>(_queueBox);
      final stored = box.get(_queueKey);
      if (stored is List) {
        _pending = [
          for (final e in stored) ?LastFmScrobble.fromJson(e),
        ];
      }
    } catch (e) {
      debugPrint('Last.fm: failed to load config: $e');
    }
    notifyListeners();
  }

  Future<void> _saveConfig() => _secure.write(
        key: _secureKey,
        value: jsonEncode({
          'apiKey': _apiKey,
          'secret': _secret,
          'sessionKey': _sessionKey,
          'username': _username,
          'enabled': _enabled,
        }),
      );

  Future<void> _saveQueue() async {
    try {
      final box = Hive.isBoxOpen(_queueBox)
          ? Hive.box<dynamic>(_queueBox)
          : await Hive.openBox<dynamic>(_queueBox);
      await box.put(_queueKey, [for (final s in _pending) s.toJson()]);
    } catch (e) {
      debugPrint('Last.fm: failed to save queue: $e');
    }
  }

  Future<Map<String, dynamic>> _call(
    Map<String, String> params, {
    required String apiKey,
    required String secret,
  }) async {
    final signed = {...params, 'api_key': apiKey};
    signed['api_sig'] = lastFmSignature(signed, secret);
    signed['format'] = 'json';
    final response = await _http
        .post(Uri.parse(_endpoint), body: signed)
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw Exception('Unexpected Last.fm response');
    }
    if (body['error'] != null) {
      throw LastFmException(body['error'] as int? ?? 0, '${body['message']}');
    }
    return body;
  }

  /// Log in with the user's API key/secret and Last.fm credentials. The
  /// password is only used to get a session key and is not stored.
  Future<void> connect({
    required String apiKey,
    required String secret,
    required String username,
    required String password,
  }) async {
    final result = await _call(
      {
        'method': 'auth.getMobileSession',
        'username': username,
        'password': password,
      },
      apiKey: apiKey,
      secret: secret,
    );
    final session = result['session'];
    if (session is! Map || session['key'] is! String) {
      throw Exception('Last.fm did not return a session');
    }
    _apiKey = apiKey;
    _secret = secret;
    _sessionKey = session['key'] as String;
    _username = session['name'] as String? ?? username;
    _enabled = true;
    await _saveConfig();
    notifyListeners();
    unawaited(flush());
  }

  Future<void> disconnect() async {
    _apiKey = _secret = _sessionKey = _username = null;
    _pending = [];
    await _secure.delete(key: _secureKey);
    await _saveQueue();
    notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await _saveConfig();
    notifyListeners();
  }

  Future<void> updateNowPlaying(JellyfinTrack track) async {
    if (!isScrobblingEnabled) return;
    try {
      await _call(
        {
          'method': 'track.updateNowPlaying',
          'artist': track.displayArtist,
          'track': track.name,
          if (track.album != null) 'album': track.album!,
          if (track.duration != null) 'duration': '${track.duration!.inSeconds}',
          'sk': _sessionKey!,
        },
        apiKey: _apiKey!,
        secret: _secret!,
      );
    } catch (e) {
      debugPrint('Last.fm now playing failed: $e');
    }
  }

  /// Queue a play (started at [startedAt]) and try to send the queue.
  Future<void> scrobble(JellyfinTrack track, DateTime startedAt) async {
    if (!isScrobblingEnabled) return;
    _pending.add(LastFmScrobble(
      artist: track.displayArtist,
      track: track.name,
      album: track.album,
      timestamp: startedAt.millisecondsSinceEpoch ~/ 1000,
      durationSeconds: track.duration?.inSeconds,
    ));
    if (_pending.length > _maxQueue) {
      _pending.removeRange(0, _pending.length - _maxQueue);
    }
    await _saveQueue();
    notifyListeners();
    await flush();
  }

  /// Send queued plays in batches of 50. Single-flight.
  Future<void> flush() => _flushing ??= _flush().whenComplete(() => _flushing = null);

  Future<void> _flush() async {
    while (_pending.isNotEmpty && isScrobblingEnabled) {
      final batch = _pending.take(_batchSize).toList();
      try {
        await _call(
          {
            'method': 'track.scrobble',
            ...lastFmScrobbleParams(batch),
            'sk': _sessionKey!,
          },
          apiKey: _apiKey!,
          secret: _secret!,
        );
      } on LastFmException catch (e) {
        // 9 = invalid session: the user must log in again. Other errors
        // (rate limits, outages) are retried later.
        debugPrint('Last.fm scrobble failed: $e');
        if (e.code == 9) {
          _sessionKey = null;
          await _saveConfig();
          notifyListeners();
        }
        return;
      } catch (e) {
        debugPrint('Last.fm scrobble failed (will retry): $e');
        return;
      }
      _pending.removeRange(0, batch.length);
      await _saveQueue();
      notifyListeners();
    }
  }
}

class LastFmException implements Exception {
  const LastFmException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'Last.fm error $code: $message';
}
