

### Run in Debug Mode
```bash
flutter run -d linux --debug
```

### Build Release
```bash
flutter build linux --release
```

### Build AppImage (Linux)
```bash
flutter build linux --release && \
rm -rf AppDir && \
mkdir -p AppDir/usr/bin && \
cp -r build/linux/x64/release/bundle/* AppDir/usr/bin/ && \
cp linux/nautune.desktop AppDir/ && \
cp linux/nautune.png AppDir/ && \
cd AppDir && ln -s usr/bin/nautune AppRun && cd .. && \
mkdir -p dist && \
ARCH=x86_64 ./appimagetool AppDir dist/Nautune-x86_64-7.4.0.AppImage
```

### Build Deb Package (Linux)
```bash
# Requires: dart pub global activate fastforge
fastforge package --platform linux --targets deb
```

### Build Flatpak (Linux)

Nautune is distributed on Flathub as a source build using [flatpak-flutter](https://github.com/TheAppgineer/flatpak-flutter). The Flatpak manifest lives in a **separate Flathub repo** (not this repo) and points to a specific commit hash in this repo.

#### How it works

There are **two repos** involved:

| Repo | Purpose |
|------|---------|
| `ElysiumDisc/nautune` (this repo) | App source code + `flatpak-flutter.yml` (source of truth) + `flatpak-local-test.yml` (local testing) |
| `flathub/com.github.ElysiumDisc.nautune` | Flathub build repo with generated manifest + `shared-modules` submodule + `generated/` files |

The Flathub repo contains the **generated** manifest (`com.github.ElysiumDisc.nautune.yml`) which is produced by running `flatpak-flutter` against `flatpak-flutter.yml` from this repo.

#### Key files in this repo

- **`flatpak-flutter.yml`** — Source of truth. Defines the build: runtime, SDK extensions, dependencies, build commands. Contains a `commit:` field that must point to the latest pushed commit hash.
- **`flatpak-local-test.yml`** — Same as the generated manifest but uses `type: dir` instead of `type: git`, so you can test locally without pushing first.
- **`com.github.ElysiumDisc.nautune.yml`** — Generated manifest (output of `flatpak-flutter`). Kept in this repo for reference; the real one lives in the Flathub repo.

#### Prerequisites (one-time setup)
```bash
# Install Flatpak tools
sudo apt install flatpak flatpak-builder

# Add Flathub remote
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Install the SDK, runtime, and extensions
flatpak install flathub org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08
flatpak install flathub org.freedesktop.Sdk.Extension.llvm20//25.08
flatpak install flathub org.freedesktop.Sdk.Extension.vala//25.08

# Clone the Flathub repo (separate from this repo)
git clone git@github.com:ElysiumDisc/flathub.git ~/flathub
```

#### Build and test locally
```bash
# Use the local test manifest (type: dir, no commit hash needed)
flatpak-builder --user --install --force-clean build-dir flatpak-local-test.yml

# Run it
flatpak run com.github.ElysiumDisc.nautune
```

#### Upgrade Flutter SDK for Flatpak
When you upgrade your local Flutter SDK (e.g., `flutter upgrade`), the Flatpak build
will fail if the new Flutter version pins different transitive dependency versions
(like `material_color_utilities`). The error looks like:
```
Because no versions of material_color_utilities match 0.13.0 ...
```

To fix this, update all three Flatpak files to use the new Flutter version:

```bash
# 1. Check your local Flutter version
flutter --version
# e.g., Flutter 3.41.2

# 2. Update flatpak-flutter.yml — change the Flutter tag
# Find the line:  tag: 3.38.9
# Change it to:   tag: 3.41.2

# 3. Regenerate the Flutter SDK module (requires flatpak-flutter tool)
cd ~/flathub
~/flathub/.venv/bin/python3 ~/flathub/.flatpak-flutter-tool/flatpak-flutter.py ~/nautune/flatpak-flutter.yml

# This regenerates in ~/flathub:
#   generated/modules/flutter-sdk-3.41.2.json  (new Flutter SDK module with correct engine URLs + hashes)
#   generated/sources/pubspec.json             (pinned Dart dependencies)
#   com.github.ElysiumDisc.nautune.yml         (the full build manifest)

# 4. Copy regenerated files back to this repo
cp ~/flathub/generated/modules/flutter-sdk-*.json ~/nautune/generated/modules/
cp ~/flathub/generated/sources/pubspec.json ~/nautune/generated/sources/
cp ~/flathub/com.github.ElysiumDisc.nautune.yml ~/nautune/

# 5. Update flatpak-local-test.yml — change the module reference
# Find the line:  - generated/modules/flutter-sdk-3.38.9.json
# Change it to:   - generated/modules/flutter-sdk-3.41.2.json

# 6. (Optional) Remove the old module file
rm ~/nautune/generated/modules/flutter-sdk-3.38.9.json

# 7. Test locally
flatpak-builder --user --install --force-clean build-dir flatpak-local-test.yml
flatpak run com.github.ElysiumDisc.nautune
```

**Why this happens**: The Flatpak builds offline — it pre-downloads all Dart packages
and the Flutter SDK engine artifacts. Each Flutter version pins exact transitive
dependency versions (e.g., `material_color_utilities 0.13.0`). If the Flatpak uses
Flutter 3.38.9 but your `pubspec.lock` was resolved with Flutter 3.41.2, the offline
`pub get` fails because the pinned packages don't match.

#### Regenerate manifest after dependency changes
When you add/remove/update packages in `pubspec.yaml`, you need to regenerate the
offline manifest so Flathub can build without network access:

```bash
# 1. Commit and push your changes to this repo
git add . && git commit -m "your changes" && git push

# 2. Update the commit hash in flatpak-flutter.yml to the commit you just pushed
git rev-parse HEAD
# Edit flatpak-flutter.yml: replace the commit: field with the new hash

# 3. Clone flatpak-flutter tool and set up a venv (one-time setup)
git clone https://github.com/TheAppgineer/flatpak-flutter.git ~/flathub/.flatpak-flutter-tool
python3 -m venv ~/flathub/.venv
~/flathub/.venv/bin/pip install -r ~/flathub/.flatpak-flutter-tool/requirements.txt

# 4. Run the pre-processor (from the Flathub repo directory)
cd ~/flathub
~/flathub/.venv/bin/python3 ~/flathub/.flatpak-flutter-tool/flatpak-flutter.py ~/nautune/flatpak-flutter.yml

# This regenerates in ~/flathub:
#   com.github.ElysiumDisc.nautune.yml  (the build manifest)
#   generated/sources/pubspec.json      (pinned Dart dependencies)
#   generated/modules/flutter-sdk-*.json (Flutter SDK module)
```

#### Publish an update to Flathub
Every time you release a new version of Nautune:

```bash
# 1. Make your changes in this repo, commit and push
cd ~/nautune
git add . && git commit -m "v7.0.0 - new features" && git push

# 2. Update commit hash in flatpak-flutter.yml to the new commit
git rev-parse HEAD
# Edit flatpak-flutter.yml with the new hash

# 3a. If you changed pubspec.yaml OR upgraded Flutter:
#     Regenerate the full manifest (see sections above)

# 3b. If you did NOT change dependencies or Flutter version:
#     Just update the commit hash in ~/flathub/com.github.ElysiumDisc.nautune.yml

# 4. (Optional) Test locally first
flatpak-builder --user --install --force-clean build-dir flatpak-local-test.yml
flatpak run com.github.ElysiumDisc.nautune

# 5. Push to Flathub repo
cd ~/flathub
git add com.github.ElysiumDisc.nautune.yml generated/
git commit -m "Update to v7.3.0"
git push

# Flathub auto-builds on push — your update goes live within a few hours.
```

#### SDK 25.08 notes

The Freedesktop SDK 25.08 has some quirks that the manifest works around:
- **clang++ required**: SDK sets `CXX=clang++` but doesn't include it — the `org.freedesktop.Sdk.Extension.llvm20` extension provides it
- **No PyGObject**: SDK removed `gi` module — icons are pre-generated with ImageMagick (`assets/icons/icon-{512,256,128}.png`) instead of resized at build time
- **System tray deps**: `tray_manager` needs `libayatana-appindicator3` which is provided by [Flathub shared-modules](https://github.com/flathub/shared-modules) (added as a git submodule in the Flathub repo)

### Static Analysis
```bash
flutter analyze
```



### Desktop Shortcut with TUI Option (KDE/GNOME)

Add a right-click menu option to launch TUI mode from your desktop shortcut.

Edit your `.desktop` file (e.g., `~/.local/share/applications/nautune.desktop`):

```ini
[Desktop Entry]
Actions=tui;
Comment=
Exec=/path/to/Nautune-x86_64.AppImage
GenericName=Jellyfin Music Player
Icon=/path/to/icon.png
Name=Nautune
NoDisplay=false
StartupNotify=true
Terminal=false
Type=Application

[Desktop Action tui]
Exec=/path/to/Nautune-x86_64.AppImage --tui
Icon=/path/to/icon.png
Name=Launch TUI Mode
```

Now you can:
- **Left-click** → Launch normal GUI
- **Right-click** → Choose "Launch TUI Mode"

### Requirements

- Linux only (TUI mode is not available on iOS/macOS/Windows)
- Must be logged in via GUI mode first (session persists)

---



## 🖥️ TUI Mode (Linux)

<img src="screenshots/tui.png" width="600" alt="Nautune TUI Mode">

A terminal-inspired interface for keyboard-driven music browsing, inspired by [jellyfin-tui](https://github.com/dhonus/jellyfin-tui).

### Launching TUI Mode

#### AppImage
```bash
./Nautune-x86_64.AppImage --tui
```

#### Deb Package
```bash
nautune --tui
```

#### Environment Variable (Alternative)
```bash
NAUTUNE_TUI_MODE=1 nautune
```

#### Development
```bash
flutter run -d linux --dart-define=TUI_MODE=true
```

## 🛠 Technical Foundation
- **Framework**: Flutter (Dart)
- **Local Storage**: Hive (NoSQL) for high-speed metadata caching
- **Audio Engine**: Audioplayers with custom platform-specific optimizations
- **Equalizer**: PulseAudio LADSPA (Linux only)
- **FFT Processing**: Custom Cooley-Tukey (Linux), Apple Accelerate vDSP (iOS)
- **Image Processing**: Material Color Utilities for vibrant palette generation

## 📂 File Structure (Linux)
Nautune follows a clean data structure on Linux for easy backups and management:
- `~/Documents/nautune/`: Primary application data
- `~/Documents/nautune/downloads/`: High-quality offline audio files
- `~/Documents/nautune/downloads/artwork/`: Cached album artwork (stored per-album to save space)
- `~/Documents/nautune/network/audio/`: Network easter egg offline channels
- `~/Documents/nautune/network/images/`: Network channel artwork
- `~/Documents/nautune/charts/`: Frets on Fire cached chart data
- `~/Documents/nautune/legendary/`: Through the Fire and Flames track and unlock state
- `~/Documents/nautune/essential/audio/`: Essential Mix offline audio
- `~/Documents/nautune/waveforms/`: Extracted waveform data for visualization
