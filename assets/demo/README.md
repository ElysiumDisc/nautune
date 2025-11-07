# Nautune Demo Assets

This directory keeps the demo-specific files that drive App Store review mode.

## Demo audio (bundled MP3s)

- `demo_online_track.mp3`: “Ocean Vibes” — https://pixabay.com/music/beats-ocean-vibes-391210/ (Pixabay License).
- `demo_offline_track.mp3`: “Sirens and Silence” — https://pixabay.com/music/modern-classical-sirens-and-silence-10036/ (Pixabay License).

Both MP3s are embedded directly in the build so demo playback works on every platform without network access. To replace them, drop new files here and update the metadata inside `lib/demo/demo_content.dart` (track name, artist credit, and asset paths).

## Artwork

For now the demo library intentionally uses Nautune's built-in placeholders:

- Album fallback: `assets/no_album_art.png`
- Artist fallback: `assets/no_artist_art.png`

You can replace these images with custom artwork if desired; doing so automatically updates the demo since the UI already points at these shared assets.
