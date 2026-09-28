// ignore_for_file: experimental_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nautune/services/engine/engine_player.dart';

void main() {
  test('local files play from disk (file:// paths too)', () {
    final a = const EngineSource.file('/music/a.flac').toAudioSource() as UriAudioSource;
    expect(a.uri, Uri.file('/music/a.flac'));
    final b = const EngineSource.file('file:///music/b.mp3').toAudioSource() as UriAudioSource;
    expect(b.uri, Uri.file('/music/b.mp3'));
  });

  test('streams with a cache file are saved while playing', () {
    final file = File('${Directory.systemTemp.path}/nautune_engine_test');
    final s = EngineSource.url('https://h/Audio/1/universal', cacheFile: file).toAudioSource();
    expect(s, isA<LockCachingAudioSource>());
  });

  test('streams without a cache file (transcodes) stream directly', () {
    final s = const EngineSource.url('https://h/Audio/1/stream.mp3').toAudioSource();
    expect(s, isA<UriAudioSource>());
    expect(s, isNot(isA<LockCachingAudioSource>()));
  });

  test('assets keep their full path', () {
    final s = const EngineSource.asset('assets/demo/x.mp3').toAudioSource() as UriAudioSource;
    expect(s.uri.toString(), contains('assets/demo/x.mp3'));
  });
}
