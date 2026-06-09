# ZiaChat

ZiaChat is a SwiftUI starter for a chat-style iOS app.

## Open

Open `ZiaChat.xcodeproj` in Xcode.

## Build

From the command line:

```sh
xcodebuild -project ZiaChat.xcodeproj -scheme ZiaChat -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Structure

- `ZiaChat.xcodeproj` is the only Xcode project.
- `ZiaChat/` contains the app source and asset catalog.
- `ZiaChat/ContentView.swift` contains the starter inbox and chat detail views.
