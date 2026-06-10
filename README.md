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
3. Deploy `supabase/functions/zia-chat-apns`.
4. Configure these Edge Function secrets:

```sh
supabase secrets set \
  APNS_TEAM_ID=... \
  APNS_KEY_ID=... \
  APNS_PRIVATE_KEY='-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----' \
  APNS_BUNDLE_ID=authcode.ZiaChat \
  APNS_PRODUCTION=true \
  ZIA_CHAT_PUSH_WEBHOOK_SECRET=...
```

5. Add the trigger secrets in Supabase SQL Editor:

```sql
select vault.create_secret(
  'https://supabase.authcode.biz/functions/v1/zia-chat-apns',
  'zia_chat_push_webhook_url'
);
select vault.create_secret('SAME_RANDOM_SECRET', 'zia_chat_push_webhook_secret');
```

6. Apply `supabase/migrations/20260610090000_zia_chat_apns.sql`.
