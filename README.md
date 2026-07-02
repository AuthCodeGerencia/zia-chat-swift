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

## Push Notifications

ZiaChat uses native APNs. It does not use or modify Azank App's Expo push tokens.

1. Enable Push Notifications for bundle ID `authcode.ZiaChat` in Apple Developer.
2. Create an APNs `.p8` key.
3. Deploy the Convex functions from `azank-react/convex` to the deployment used
   by the app.
4. Configure these Convex environment variables in the same deployment:

```sh
npx convex env set APNS_TEAM_ID ... --prod
npx convex env set APNS_KEY_ID ... --prod
npx convex env set APNS_PRIVATE_KEY '-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----' --prod
npx convex env set APNS_BUNDLE_ID authcode.ZiaChat --prod
npx convex env set APNS_PRODUCTION true --prod
```

For the development deployment, omit `--prod`:

```sh
npx convex env set APNS_TEAM_ID ...
npx convex env set APNS_KEY_ID ...
npx convex env set APNS_PRIVATE_KEY '-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----'
npx convex env set APNS_BUNDLE_ID authcode.ZiaChat
npx convex env set APNS_PRODUCTION true
```

The required keys are:

```sh
  APNS_TEAM_ID=... \
  APNS_KEY_ID=... \
  APNS_PRIVATE_KEY='-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----' \
  APNS_BUNDLE_ID=authcode.ZiaChat \
  APNS_PRODUCTION=true
```

5. Deploy Convex:

```sh
cd ../azank-react
npx convex deploy
```

The legacy Supabase Edge Function and SQL trigger are no longer part of the
push path once chat messages are sent through Convex. The app registers APNs
tokens through `push:registerToken`, and `messages:send` schedules
`pushActions:sendForMessage`.
