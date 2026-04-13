import 'dart:typed_data';

/// Build a RIFF/WAV (PCM16) byte buffer from signed 16-bit samples.
/// Shared by piano, healing-frequency, and any future synth feature.
Uint8List buildWavPcm16(
  Int16List samples, {
  int sampleRate = 44100,
  int channels = 1,
}) {
  const bitsPerSample = 16;
  final dataSize = samples.length * 2;
  final fileSize = 44 + dataSize;

  final buffer = ByteData(fileSize);
  var offset = 0;

  // RIFF header
  buffer.setUint8(offset++, 0x52); // R
  buffer.setUint8(offset++, 0x49); // I
  buffer.setUint8(offset++, 0x46); // F
  buffer.setUint8(offset++, 0x46); // F
  buffer.setUint32(offset, fileSize - 8, Endian.little);
  offset += 4;
  buffer.setUint8(offset++, 0x57); // W
  buffer.setUint8(offset++, 0x41); // A
  buffer.setUint8(offset++, 0x56); // V
  buffer.setUint8(offset++, 0x45); // E

  // fmt sub-chunk
  buffer.setUint8(offset++, 0x66); // f
  buffer.setUint8(offset++, 0x6D); // m
  buffer.setUint8(offset++, 0x74); // t
  buffer.setUint8(offset++, 0x20); // ' '
  buffer.setUint32(offset, 16, Endian.little);
  offset += 4;
  buffer.setUint16(offset, 1, Endian.little); // PCM
  offset += 2;
  buffer.setUint16(offset, channels, Endian.little);
  offset += 2;
  buffer.setUint32(offset, sampleRate, Endian.little);
  offset += 4;
  buffer.setUint32(
    offset,
    sampleRate * channels * bitsPerSample ~/ 8,
    Endian.little,
  );
  offset += 4;
  buffer.setUint16(offset, channels * bitsPerSample ~/ 8, Endian.little);
  offset += 2;
  buffer.setUint16(offset, bitsPerSample, Endian.little);
  offset += 2;

  // data sub-chunk
  buffer.setUint8(offset++, 0x64); // d
  buffer.setUint8(offset++, 0x61); // a
  buffer.setUint8(offset++, 0x74); // t
  buffer.setUint8(offset++, 0x61); // a
  buffer.setUint32(offset, dataSize, Endian.little);
  offset += 4;

  for (final sample in samples) {
    buffer.setInt16(offset, sample, Endian.little);
    offset += 2;
  }

  return buffer.buffer.asUint8List();
}
