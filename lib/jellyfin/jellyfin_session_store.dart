import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import 'jellyfin_session.dart';

class JellyfinSessionStore {
  static const _boxName = 'nautune_session';
  static const _sessionKey = 'session';
  static const _deviceIdKey = 'device_id';
  static const _secureStorageKey = 'hive_encryption_key';
  
  final _secureStorage = const FlutterSecureStorage();

  /// Retrieves or generates a persistent unique Device ID
  Future<String> getDeviceId() async {
    try {
      final box = await _box();
      String? deviceId = box.get(_deviceIdKey);
      
      if (deviceId == null) {
        deviceId = const Uuid().v4();
        await box.put(_deviceIdKey, deviceId);
        debugPrint('🆔 JellyfinSessionStore: Generated new Device ID');
      }
      return deviceId;
    } catch (e) {
      debugPrint('❌ JellyfinSessionStore: Failed to get device ID: $e');
      return 'nautune-fallback-${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  Future<Box> _box() async {
    try {
      if (!Hive.isBoxOpen(_boxName)) {
        debugPrint('📦 JellyfinSessionStore: Opening Hive box: $_boxName');
        
        // Check for existing encryption key
        String? keyString = await _secureStorage.read(key: _secureStorageKey);
        Uint8List encryptionKey;
        
        if (keyString == null) {
          debugPrint('🔐 JellyfinSessionStore: Generating new encryption key');
          // Check for unencrypted data to migrate
          if (await Hive.boxExists(_boxName)) {
            debugPrint('📦 JellyfinSessionStore: Found existing box, attempting migration');
            dynamic oldData;
            bool migrationSucceeded = false;

            try {
              final oldBox = await Hive.openBox(_boxName);
              oldData = oldBox.get(_sessionKey);
              await oldBox.close();
              migrationSucceeded = true;
            } catch (e) {
              debugPrint('⚠️ JellyfinSessionStore: Failed to read old data: $e');
            }

            // Generate and save new key
            final key = Hive.generateSecureKey();
            await _secureStorage.write(
              key: _secureStorageKey,
              value: base64UrlEncode(key),
            );
            encryptionKey = Uint8List.fromList(key);

            // Write to new encrypted box FIRST, then delete old data
            // This prevents data loss if the app crashes mid-migration
            final tempBoxName = '${_boxName}_encrypted';
            final newBox = await Hive.openBox(
              tempBoxName,
              encryptionCipher: HiveAesCipher(encryptionKey),
            );
            if (migrationSucceeded && oldData != null) {
              await newBox.put(_sessionKey, oldData);
              debugPrint('✅ JellyfinSessionStore: Data written to encrypted box');
            }
            await newBox.close();

            // Now safe to delete old unencrypted box
            try {
              await Hive.deleteBoxFromDisk(_boxName);
            } catch (_) {
              // Ignore deletion errors — old box is harmless
            }

            // Rename encrypted box to the standard name by copying
            final finalBox = await Hive.openBox(
              _boxName,
              encryptionCipher: HiveAesCipher(encryptionKey),
            );
            if (migrationSucceeded && oldData != null) {
              await finalBox.put(_sessionKey, oldData);
            }
            // Clean up temp box
            try {
              await Hive.deleteBoxFromDisk(tempBoxName);
            } catch (_) {}

            if (migrationSucceeded && oldData != null) {
              debugPrint('✅ JellyfinSessionStore: Migration completed successfully');
            } else if (!migrationSucceeded) {
              debugPrint('ℹ️ JellyfinSessionStore: Starting fresh after failed migration');
            }
            return finalBox;
          }
          
          // Generate new key
          final key = Hive.generateSecureKey();
          await _secureStorage.write(
            key: _secureStorageKey, 
            value: base64UrlEncode(key),
          );
          encryptionKey = Uint8List.fromList(key);
        } else {
          encryptionKey = base64Url.decode(keyString);
        }

        final box = await Hive.openBox(
          _boxName,
          encryptionCipher: HiveAesCipher(encryptionKey),
        );
        debugPrint('✅ JellyfinSessionStore: Encrypted box opened successfully');
        return box;
      }
      return Hive.box(_boxName);
    } catch (e) {
      debugPrint('❌ JellyfinSessionStore: Failed to open box: $e');
      rethrow;
    }
  }

  Future<JellyfinSession?> load() async {
    try {
      final box = await _box();
      final raw = box.get(_sessionKey);
      
      if (raw == null) {
        debugPrint('📭 JellyfinSessionStore: No session found in storage');
        return null;
      }

      debugPrint('📥 JellyfinSessionStore: Loading session from storage');

      // Hive stores data as Map<dynamic, dynamic> which needs to be converted
      // Support both Map (from Hive) and String (legacy from SharedPreferences)
      final Map<String, dynamic> json;
      if (raw is Map) {
        // Convert Map<dynamic, dynamic> to Map<String, dynamic>
        json = raw.map((key, value) {
          // Recursively convert nested maps
          if (value is Map) {
            return MapEntry(
              key.toString(),
              value.map((k, v) => MapEntry(k.toString(), v)),
            );
          }
          return MapEntry(key.toString(), value);
        });
      } else if (raw is String) {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } else {
        debugPrint('⚠️ JellyfinSessionStore: Invalid session data type: ${raw.runtimeType}');
        return null;
      }
      
      final session = JellyfinSession.fromJson(json);
      debugPrint('✅ JellyfinSessionStore: Session loaded for ${session.username}');
      return session;
    } catch (e) {
      debugPrint('❌ JellyfinSessionStore: Failed to load session: $e');
      try {
        final box = await _box();
        await box.delete(_sessionKey);
      } catch (_) {}
      return null;
    }
  }

  Future<void> save(JellyfinSession session) async {
    try {
      debugPrint('💾 JellyfinSessionStore: Saving session for ${session.username}');
      final box = await _box();
      // Store as Map for better Hive performance/usage
      await box.put(_sessionKey, session.toJson());
      debugPrint('✅ JellyfinSessionStore: Session saved successfully');
    } catch (e) {
      debugPrint('❌ JellyfinSessionStore: Failed to save session: $e');
      rethrow;
    }
  }

  Future<void> clear() async {
    try {
      debugPrint('🗑️ JellyfinSessionStore: Clearing session');
      final box = await _box();
      await box.delete(_sessionKey);
      debugPrint('✅ JellyfinSessionStore: Session cleared');
    } catch (e) {
      debugPrint('❌ JellyfinSessionStore: Failed to clear session: $e');
      rethrow;
    }
  }
}
