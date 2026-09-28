/// Base class for Jellyfin-related errors.
class JellyfinException implements Exception {
  JellyfinException(this.message);

  final String message;

  @override
  String toString() => 'JellyfinException: $message';
}

class JellyfinAuthException extends JellyfinException {
  JellyfinAuthException(super.message);
}

class JellyfinRequestException extends JellyfinException {
  JellyfinRequestException(super.message);
}

/// The persisted session exists (or may exist) but can't be read right now —
/// typically the iOS keychain is locked (cold start from CarPlay / background
/// before first unlock). Callers must NOT treat this as "logged out" or wipe
/// anything; retry later (e.g. on app resume).
class SessionStorageUnavailableException extends JellyfinException {
  SessionStorageUnavailableException(super.message, [this.cause]);

  final Object? cause;

  @override
  String toString() =>
      'SessionStorageUnavailableException: $message${cause != null ? ' ($cause)' : ''}';
}
