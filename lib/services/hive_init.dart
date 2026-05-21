import 'package:hive_flutter/hive_flutter.dart';

/// Single source of truth for Hive initialisation.
///
/// Multiple services used to keep their own `static bool _hiveInitialized`
/// flag, each calling `Hive.initFlutter('nautune')` lazily on first use.
/// That works because `Hive.initFlutter` is idempotent, but it scatters the
/// subdirectory string ('nautune') across the codebase and races on parallel
/// service initialisation. This helper centralises the guard.
Future<void> ensureHiveInitialized() async {
  if (_initialized) return;
  await Hive.initFlutter('nautune');
  _initialized = true;
}

bool _initialized = false;
