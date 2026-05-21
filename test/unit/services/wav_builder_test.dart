import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/wav_builder.dart';

void main() {
  group('buildWavPcm16', () {
    int u32le(Uint8List bytes, int offset) =>
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);

    int u16le(Uint8List bytes, int offset) =>
        bytes[offset] | (bytes[offset + 1] << 8);

    String ascii(Uint8List bytes, int offset, int length) =>
        String.fromCharCodes(bytes.sublist(offset, offset + length));

    test('writes a 44-byte header for an empty sample buffer', () {
      final wav = buildWavPcm16(Int16List(0));

      expect(wav.length, 44);
      expect(ascii(wav, 0, 4), 'RIFF');
      expect(ascii(wav, 8, 4), 'WAVE');
      expect(ascii(wav, 12, 4), 'fmt ');
      expect(ascii(wav, 36, 4), 'data');
      expect(u32le(wav, 40), 0); // data size
    });

    test('encodes RIFF/WAVE/fmt/data chunk identifiers', () {
      final wav = buildWavPcm16(Int16List.fromList([0, 0, 0, 0]));

      expect(ascii(wav, 0, 4), 'RIFF');
      expect(ascii(wav, 8, 4), 'WAVE');
      expect(ascii(wav, 12, 4), 'fmt ');
      expect(ascii(wav, 36, 4), 'data');
    });

    test('total file size = 44 + samples * 2 for mono', () {
      final samples = Int16List.fromList(List<int>.filled(100, 0));
      final wav = buildWavPcm16(samples);

      expect(wav.length, 44 + 200);
      expect(u32le(wav, 4), wav.length - 8); // RIFF chunk size
      expect(u32le(wav, 40), 200);            // data chunk size
    });

    test('fmt chunk declares PCM (audio format 1) and 16-bit samples', () {
      final wav = buildWavPcm16(Int16List(1));

      expect(u32le(wav, 16), 16);            // fmt chunk size
      expect(u16le(wav, 20), 1);             // PCM
      expect(u16le(wav, 34), 16);            // bitsPerSample
    });

    test('default sample rate is 44100 Hz, mono', () {
      final wav = buildWavPcm16(Int16List(1));

      expect(u16le(wav, 22), 1);              // channels
      expect(u32le(wav, 24), 44100);          // sampleRate
      expect(u32le(wav, 28), 44100 * 1 * 2);  // byteRate = sr*ch*bps/8
      expect(u16le(wav, 32), 1 * 2);          // blockAlign = ch*bps/8
    });

    test('honors stereo channel count and 48 kHz sample rate', () {
      final wav = buildWavPcm16(
        Int16List(8),
        sampleRate: 48000,
        channels: 2,
      );

      expect(u16le(wav, 22), 2);              // stereo
      expect(u32le(wav, 24), 48000);          // 48 kHz
      expect(u32le(wav, 28), 48000 * 2 * 2);  // byteRate
      expect(u16le(wav, 32), 2 * 2);          // blockAlign
    });

    test('writes 16-bit samples little-endian in the data section', () {
      // 0x0102 -> 02 01, signed -2 -> FE FF
      final samples = Int16List.fromList([0x0102, -2]);
      final wav = buildWavPcm16(samples);

      expect(wav[44], 0x02);
      expect(wav[45], 0x01);
      expect(wav[46], 0xFE);
      expect(wav[47], 0xFF);
    });
  });
}
