import 'package:flutter/foundation.dart';

/// Represents the current sync status
enum SyncStatus {
  idle,      // No sync activity
  syncing,   // Active sync in progress
  pending,   // Has queued offline actions
  error,     // Last sync failed
  offline,   // No network connection
}

/// Manages sync status and pending offline actions visibility.
///
/// Responsibilities:
/// - Track current sync state (idle, syncing, pending, error, offline)
/// - Count pending offline actions
/// - Track last sync timestamp
/// - Provide sync error information
/// - Notify listeners of state changes
class SyncStatusProvider extends ChangeNotifier {
  SyncStatus _status = SyncStatus.idle;
  int _pendingActionsCount = 0;
  DateTime? _lastSyncTime;
  String? _lastError;
  String? _currentSyncOperation;
  int _activeSyncOperations = 0;

  // Getters
  SyncStatus get status => _status;
  int get pendingActionsCount => _pendingActionsCount;
  DateTime? get lastSyncTime => _lastSyncTime;
  String? get lastError => _lastError;
  String? get currentSyncOperation => _currentSyncOperation;
  bool get hasPendingActions => _pendingActionsCount > 0;
  bool get isSyncing => _status == SyncStatus.syncing;
  bool get hasError => _status == SyncStatus.error;
  bool get isOffline => _status == SyncStatus.offline;

  /// Human-readable description of current status
  String get statusDescription {
    switch (_status) {
      case SyncStatus.idle:
        return 'Up to date';
      case SyncStatus.syncing:
        return _currentSyncOperation ?? 'Syncing...';
      case SyncStatus.pending:
        return '$_pendingActionsCount pending';
      case SyncStatus.error:
        return 'Sync failed';
      case SyncStatus.offline:
        return 'Offline';
    }
  }

  /// Short status text for badges
  String get badgeText {
    if (_pendingActionsCount > 0) {
      return _pendingActionsCount > 99 ? '99+' : '$_pendingActionsCount';
    }
    return '';
  }

  /// Time since last sync in human-readable format
  String? get timeSinceLastSync {
    if (_lastSyncTime == null) return null;

    final diff = DateTime.now().difference(_lastSyncTime!);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return null;
  }

  /// Set the offline status
  void setOffline(bool isOffline) {
    if (isOffline && _status != SyncStatus.offline) {
      _status = SyncStatus.offline;
      notifyListeners();
    } else if (!isOffline && _status == SyncStatus.offline) {
      // _updateStatus() preserves the offline state, so leave it first.
      _status = SyncStatus.idle;
      _updateStatus();
      notifyListeners();
    }
  }

  /// Start a sync operation
  void startSync([String? operation]) {
    _activeSyncOperations++;
    _currentSyncOperation = operation;
    _lastError = null;
    _status = SyncStatus.syncing;
    notifyListeners();
  }

  /// Complete a sync operation successfully
  void completeSync() {
    _activeSyncOperations = (_activeSyncOperations - 1).clamp(0, 100);
    if (_activeSyncOperations == 0) {
      _currentSyncOperation = null;
      _lastSyncTime = DateTime.now();
      _lastError = null;
      _updateStatus();
      notifyListeners();
    }
  }

  /// Fail a sync operation
  void failSync(String error) {
    _activeSyncOperations = (_activeSyncOperations - 1).clamp(0, 100);
    if (_activeSyncOperations == 0) {
      _currentSyncOperation = null;
      _lastError = error;
      _status = SyncStatus.error;
      notifyListeners();
    }
  }

  /// Update pending actions count
  void setPendingActionsCount(int count) {
    if (_pendingActionsCount != count) {
      _pendingActionsCount = count;
      _updateStatus();
      notifyListeners();
    }
  }

  /// Increment pending actions
  void addPendingAction() {
    _pendingActionsCount++;
    _updateStatus();
    notifyListeners();
  }

  /// Decrement pending actions
  void removePendingAction() {
    _pendingActionsCount = (_pendingActionsCount - 1).clamp(0, 1000);
    _updateStatus();
    notifyListeners();
  }

  /// Clear all pending actions (e.g., after successful sync)
  void clearPendingActions() {
    if (_pendingActionsCount > 0) {
      _pendingActionsCount = 0;
      _updateStatus();
      notifyListeners();
    }
  }

  /// Clear error state
  void clearError() {
    if (_lastError != null) {
      _lastError = null;
      _updateStatus();
      notifyListeners();
    }
  }

  /// Update status based on current state
  void _updateStatus() {
    if (_status == SyncStatus.offline) return; // Preserve offline state

    if (_activeSyncOperations > 0) {
      _status = SyncStatus.syncing;
    } else if (_lastError != null) {
      _status = SyncStatus.error;
    } else if (_pendingActionsCount > 0) {
      _status = SyncStatus.pending;
    } else {
      _status = SyncStatus.idle;
    }
  }

  /// Reset all state
  void reset() {
    _status = SyncStatus.idle;
    _pendingActionsCount = 0;
    _lastSyncTime = null;
    _lastError = null;
    _currentSyncOperation = null;
    _activeSyncOperations = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    reset();
    super.dispose();
  }
}
