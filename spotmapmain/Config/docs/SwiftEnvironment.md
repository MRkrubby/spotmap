# Swift environment setup (SpotMap)

SpotMap is an iOS app and requires Xcode + iOS SDKs to build and run. Use the steps below on a macOS machine.

## Prerequisites
- macOS with Xcode installed (App Store or Apple Developer).
- iOS Simulator runtimes (installed via Xcode > Settings > Platforms).
- Optional: a physical iOS device for on-device testing.

## One-time setup
1. Install Xcode.
2. Open Xcode once to finish setup and accept the license.
3. Ensure the command line tools are set:
   ```sh
   xcode-select -s /Applications/Xcode.app
   ```

## Build from the command line
```sh
xcodebuild \
  -project "Spotmap Buildmain/spotmap.xcodeproj" \
  -scheme spotmap \
  -destination "generic/platform=iOS" \
  build
```

## Run in the iOS Simulator
1. List available simulators:
   ```sh
   xcrun simctl list devices available
   ```
2. Pick a device name (e.g. "iPhone 15 Pro").
3. Build and run with:
   ```sh
   xcodebuild \
     -project "Spotmap Buildmain/spotmap.xcodeproj" \
     -scheme spotmap \
     -destination "platform=iOS Simulator,name=iPhone 15 Pro" \
     build
   ```

## Helpful checks
```sh
xcodebuild -version
swift --version
xcrun --version
```

If any of these commands fail, reinstall Xcode or re-run the command line tools setup.
