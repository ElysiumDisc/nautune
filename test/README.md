# Nautune tests

```
test/
  unit/
    services/       — pure-Dart services (math, state stores, etc.)
  widget_test.dart  — top-level smoke test (placeholder)
```

## Running

```
flutter test
```

## Adding tests

Prefer extracting pure logic into a free-standing library file
(see `lib/services/fft_math.dart` for the pattern) so it can be tested
without bringing up the audio / Hive / Jellyfin subsystems.

For services that need a Hive box, write a thin in-memory fake in
`test/helpers/` rather than depending on the real Hive — Hive's
`initFlutter` requires a writable path and clashes between parallel tests.

For services that need a real `AudioPlayer`, the audioplayers package
does not ship test doubles. Extract a narrow interface at the call
site and inject a fake for tests.
