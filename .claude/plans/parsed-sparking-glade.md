# Fix: Collaborative Playlist Not Syncing When Joining via QR Code

## Problem
When scanning a QR code on iOS to join a collaborative playlist started on Linux:
- iOS device joins the group but only shows 1 listener
- The participant list doesn't reflect the actual members in the group

## Root Cause
In `lib/services/syncplay_service.dart`, the `_joinGroupInternal()` method (line 136-180) initializes the session using a stale `_availableGroups` cache:

```dart
// Line 149-157: Uses potentially stale cached data
final group = _availableGroups.firstWhere(
  (g) => g.groupId == groupId,
  orElse: () => SyncPlayGroup(...),
);
```

When joining via QR code deep link, `_availableGroups` hasn't been refreshed, so the participant list is empty or outdated.

## Solution
Call `refreshGroups()` after successfully joining the group via API but before initializing the session. This ensures the participant list is current.

## File to Modify
- `lib/services/syncplay_service.dart`

## Changes

### In `_joinGroupInternal()` method (around line 144-148):

**Before:**
```dart
await _client.joinGroup(
  credentials: _credentials,
  groupId: groupId,
);

await _connectWebSocket();

// Initialize session state
final group = _availableGroups.firstWhere(
```

**After:**
```dart
await _client.joinGroup(
  credentials: _credentials,
  groupId: groupId,
);

// Refresh groups to get current participants after joining
await refreshGroups();

await _connectWebSocket();

// Initialize session state
final group = _availableGroups.firstWhere(
```

## Verification
1. Start a collaborative playlist on Linux
2. Generate QR code and scan on iOS
3. iOS should now show correct participant count (2 listeners) immediately upon joining
4. Both devices should see each other in the participant list
