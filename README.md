# Tally

**Tally** is a minimalist macOS Menu Bar app designed for seamless time tracking. Built with SwiftUI and a focus on essential productivity, it stays out of your way while keeping your project time perfectly accounted for.

## Key Features

- **MenuBar-First UI**: Access your timers instantly from the macOS Menu Bar. No Dock icon, no clutter.
- **Cumulative Project Tracking**: Track total time spent across multiple sessions for each project.
- **Heartbeat Persistence**: Automatically saves your progress every 30 seconds. If the app crashes or the system shuts down, Tally recovers your session to the last heartbeat.
- **System Idle Detection**: Automatically pauses your timer after 5 minutes of system inactivity to ensure your tracking is accurate.
- **Minimalist Aesthetic**: A focused, dual-tone theme (`#2a2529` and `#f3f0e7`) that adapts to your system's Light and Dark modes.
- **Project Management**: Dedicated settings page to reset timers or delete projects with safe confirmation overlays.
- **Session History**: Detailed history of all recorded sessions with the ability to manually adjust time in 5-minute increments.

## Technology Stack

- **Language**: Swift 6.0
- **Framework**: SwiftUI (macOS 14+)
- **System APIs**: `IOKit` (HIDIdleTime for inactivity detection), `UserNotifications` for gap recovery alerts.
- **Persistence**: `Codable` and `UserDefaults` for reliable data storage.

## Building and Running

### Prerequisites
- macOS 14.0 or later
- Xcode 15.0 or later (for the Swift compiler)

### Build via Terminal
To compile Tally into a standalone App Bundle:

```bash
# Compile the Swift source
swiftc -O -o Tally Tally.swift -framework SwiftUI -framework IOKit -framework UserNotifications -framework AppKit -parse-as-library

# Create the App Bundle structure
mkdir -p Tally.app/Contents/MacOS
cp Tally Tally.app/Contents/MacOS/Tally

# Create the Info.plist (required for Menu Bar Agent mode)
cat <<EOF > Tally.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Tally</string>
    <key>CFBundleIdentifier</key>
    <string>com.sam.tally</string>
    <key>CFBundleName</key>
    <string>Tally</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# Launch the app
open Tally.app
```

## License

Personal use project.
