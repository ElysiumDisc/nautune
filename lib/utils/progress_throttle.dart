/// Decides when a streaming download should emit a progress update.
///
/// Chunk sizes vary, so byte-modulo checks almost never fire. This emits when
/// at least [interval] has passed since the last emit, or at least
/// [byteInterval] bytes arrived since the last emit, or the transfer is done.
class ProgressThrottle {
  ProgressThrottle({
    this.interval = const Duration(milliseconds: 250),
    this.byteInterval = 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration interval;
  final int byteInterval;
  final DateTime Function() _clock;

  DateTime? _lastEmitAt;
  int _lastEmitBytes = 0;

  /// Returns true if an update should be emitted for [downloadedBytes].
  /// [totalBytes] <= 0 means unknown length.
  bool shouldEmit(int downloadedBytes, int totalBytes) {
    final now = _clock();
    final done = totalBytes > 0 && downloadedBytes >= totalBytes;
    final last = _lastEmitAt;
    final emit = done ||
        last == null ||
        now.difference(last) >= interval ||
        downloadedBytes - _lastEmitBytes >= byteInterval;
    if (emit) {
      _lastEmitAt = now;
      _lastEmitBytes = downloadedBytes;
    }
    return emit;
  }
}
