import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';

JellyfinTrack _track({String? container, String? codec}) => JellyfinTrack(
  id: 'abc123',
  name: 'T',
  album: null,
  artists: const [],
  serverUrl: 'https://host:8920/jellyfin',
  token: 'tok+/=',
  userId: 'user1',
  container: container,
  codec: codec,
);

/// Query keys, lower-cased (ASP.NET binds query keys case-insensitively, so
/// two spellings of one key are a duplicate on the server).
List<String> _lowerKeys(Uri uri) =>
    uri.queryParametersAll.keys.map((k) => k.toLowerCase()).toList();

void main() {
  group('universalStreamUrl', () {
    test('uses transcodingProtocol=http (never progressive/hls)', () {
      final uri = Uri.parse(_track().universalStreamUrl(deviceId: 'dev')!);
      expect(uri.path, '/jellyfin/Audio/abc123/universal');
      expect(uri.queryParameters['transcodingProtocol'], 'http');
      expect(uri.toString().toLowerCase(), isNot(contains('progressive')));
      expect(uri.toString().toLowerCase(), isNot(contains('hls')));
      expect(uri.queryParameters['ApiKey'], 'tok+/=');
      expect(uri.queryParameters['userId'], 'user1');
      expect(uri.queryParameters['deviceId'], 'dev');
      expect(uri.port, 8920);
    });

    test(
      'legacy container arg is the direct-play list and transcode target',
      () {
        final uri = Uri.parse(
          _track().universalStreamUrl(
            deviceId: 'd',
            maxBitrate: 320000,
            container: 'mp3',
            audioCodec: 'mp3',
          )!,
        );
        expect(uri.queryParameters['container'], 'mp3');
        expect(uri.queryParameters['transcodingContainer'], 'mp3');
        expect(uri.queryParameters['maxStreamingBitrate'], '320000');
        expect(uri.queryParameters.containsKey('audioBitRate'), isFalse);
      },
    );

    test('no duplicate query keys', () {
      final uri = Uri.parse(
        _track().universalStreamUrl(deviceId: 'd', audioBitrate: 1)!,
      );
      final keys = _lowerKeys(uri);
      expect(keys.toSet().length, keys.length);
    });
  });

  group('originalQualityStreamUrl', () {
    test(
      'advertises AVPlayer-native containers, transcodes the rest to mp3',
      () {
        final uri = Uri.parse(
          _track().originalQualityStreamUrl(deviceId: 'd')!,
        );
        expect(uri.path, '/jellyfin/Audio/abc123/universal');
        final containers = uri.queryParameters['container']!.split(',');
        expect(containers, containsAll(['flac', 'mp3', 'aac', 'm4a|aac|alac']));
        for (final unsupported in ['ogg', 'opus', 'webm', 'asf', 'ape', 'wv']) {
          expect(
            containers.any((c) => c.split('|').first == unsupported),
            isFalse,
            reason: unsupported,
          );
        }
        expect(uri.queryParameters['transcodingContainer'], 'mp3');
        expect(uri.queryParameters['audioCodec'], 'mp3');
        expect(uri.queryParameters['transcodingProtocol'], 'http');
        expect(
          int.parse(uri.queryParameters['maxStreamingBitrate']!),
          greaterThanOrEqualTo(20000000),
        ); // > 24/192 FLAC (~9.2 Mbps)
        expect(uri.queryParameters['audioBitRate'], '320000');
      },
    );

    test('audioCodec matches the server validation regex', () {
      // EncodingHelper.ContainerValidationRegexStr
      final re = RegExp(r'^[a-zA-Z0-9\-\._,|]{0,40}$');
      final uri = Uri.parse(_track().originalQualityStreamUrl(deviceId: 'd')!);
      expect(re.hasMatch(uri.queryParameters['audioCodec']!), isTrue);
      expect(re.hasMatch(uri.queryParameters['transcodingContainer']!), isTrue);
    });
  });

  test('cappedStreamUrl only direct-plays lossy AVPlayer formats', () {
    final uri = Uri.parse(
      _track().cappedStreamUrl(deviceId: 'd', maxBitrate: 192000)!,
    );
    final containers = uri.queryParameters['container']!.split(',');
    expect(containers, isNot(contains('flac')));
    expect(containers, contains('mp3'));
    expect(uri.queryParameters['maxStreamingBitrate'], '192000');
    expect(uri.queryParameters['audioBitRate'], '192000');
    expect(uri.queryParameters['transcodingProtocol'], 'http');
  });

  group('transcodedStreamUrl', () {
    test('only spec params, no case-duplicates', () {
      final uri = Uri.parse(
        _track().transcodedStreamUrl(
          deviceId: 'd',
          audioBitrate: 128000,
          playSessionId: 'ps',
        )!,
      );
      expect(uri.path, '/jellyfin/Audio/abc123/stream.mp3');
      final keys = _lowerKeys(uri);
      expect(keys.toSet().length, keys.length);
      expect(keys.toSet(), {
        'static',
        'mediasourceid',
        'deviceid',
        'audiocodec',
        'audiobitrate',
        'maxaudiochannels',
        'apikey',
        'playsessionid',
      });
      expect(uri.queryParameters['static'], 'false');
      expect(uri.queryParameters['audioBitRate'], '128000');
      expect(uri.queryParameters['playSessionId'], 'ps');
    });
  });

  test('directDownloadUrl sends only the token', () {
    final uri = Uri.parse(_track().directDownloadUrl()!);
    expect(uri.path, '/jellyfin/Items/abc123/Download');
    expect(uri.queryParameters.keys, ['ApiKey']);
  });

  test('stream URLs honour streamUrlOverride', () {
    final t = _track().copyWith(streamUrlOverride: 'file:///x.mp3');
    expect(t.originalQualityStreamUrl(deviceId: 'd'), 'file:///x.mp3');
    expect(t.cappedStreamUrl(deviceId: 'd', maxBitrate: 1), 'file:///x.mp3');
  });

  group('isAvPlayerNativeAudio', () {
    test('native formats', () {
      expect(isAvPlayerNativeAudio(container: 'FLAC', codec: 'FLAC'), isTrue);
      expect(isAvPlayerNativeAudio(container: 'MP3', codec: 'MP3'), isTrue);
      expect(
        isAvPlayerNativeAudio(
          container: 'MOV,MP4,M4A,3GP,3G2,MJ2',
          codec: 'ALAC',
        ),
        isTrue,
      );
      expect(isAvPlayerNativeAudio(container: 'm4a', codec: 'aac'), isTrue);
      expect(
        isAvPlayerNativeAudio(container: 'wav', codec: 'pcm_s16le'),
        isTrue,
      );
    });

    test('formats AVPlayer cannot open', () {
      expect(isAvPlayerNativeAudio(container: 'ogg', codec: 'opus'), isFalse);
      expect(
        isAvPlayerNativeAudio(container: 'OGG', codec: 'FLAC'),
        isFalse,
        reason: 'FLAC-in-Ogg',
      );
      expect(isAvPlayerNativeAudio(container: 'ogg', codec: 'vorbis'), isFalse);
      expect(isAvPlayerNativeAudio(container: 'asf', codec: 'wmav2'), isFalse);
      expect(isAvPlayerNativeAudio(container: 'ape'), isFalse);
      expect(
        isAvPlayerNativeAudio(container: 'matroska,webm', codec: 'opus'),
        isFalse,
      );
      expect(isAvPlayerNativeAudio(codec: 'OPUS'), isFalse);
    });

    test('unknown metadata is assumed playable', () {
      expect(isAvPlayerNativeAudio(), isTrue);
      expect(_track().isAvPlayerNativeFormat, isTrue);
      expect(
        _track(container: 'OGG', codec: 'OPUS').isAvPlayerNativeFormat,
        isFalse,
      );
    });
  });
}
