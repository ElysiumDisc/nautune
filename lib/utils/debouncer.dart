import 'dart:async';

/// A debouncer that delays execution until a pause in calls.
/// Useful for search-as-you-type to avoid excessive API calls.
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 300)});

  final Duration delay;
  Timer? _timer;

  /// Run the action after a delay. Cancels any pending action.
  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Cancel any pending action.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Whether there's a pending action.
  bool get isPending => _timer?.isActive ?? false;

  /// Dispose the debouncer.
  void dispose() {
    cancel();
  }
}
