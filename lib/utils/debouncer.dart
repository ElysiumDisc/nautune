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

/// A throttler that ensures a minimum time between executions.
/// Useful for scroll events or rapid-fire actions.
class Throttler {
  Throttler({this.interval = const Duration(milliseconds: 100)});

  final Duration interval;
  DateTime? _lastRun;
  Timer? _pendingTimer;
  void Function()? _pendingAction;

  /// Run the action, throttled to the interval.
  /// If called during cooldown, queues one execution for after.
  void run(void Function() action) {
    final now = DateTime.now();
    
    if (_lastRun == null || now.difference(_lastRun!) >= interval) {
      // Execute immediately
      _lastRun = now;
      action();
      _pendingAction = null;
      _pendingTimer?.cancel();
    } else {
      // Queue for later (only keep latest)
      _pendingAction = action;
      _pendingTimer?.cancel();
      final remaining = interval - now.difference(_lastRun!);
      _pendingTimer = Timer(remaining, () {
        _lastRun = DateTime.now();
        _pendingAction?.call();
        _pendingAction = null;
      });
    }
  }

  /// Cancel any pending action.
  void cancel() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingAction = null;
  }

  /// Dispose the throttler.
  void dispose() {
    cancel();
  }
}
