# Native per-app notification icons — implementation plan

Status: investigation / not enabled in builds.

## Verified upstream behavior
- `AppState.addNotification` calls `postNativeNotification` and posts through `UNUserNotificationCenter.current()`, owned by AirSync.
- Android app icons are currently attached as `UNNotificationAttachment`; this does not replace the macOS sender icon.
- `NotificationDelegate` handles `ACT_*` reply/button actions, `VIEW_ACTION`, default taps, call actions, and Quick Share.
- `syncWithSystemNotifications` assumes all mirrored notifications are posted by AirSync's own notification center.

## Why simply invoking notifly is insufficient
notifly creates a separate sender app with a custom bundle icon, but its current CLI is a one-shot notification sender. It does not relay inline reply responses or dismissals back to AirSync. Replacing the existing call would silently break message replies, actions, and notification sync.

## Required implementation
1. Add a feature flag, default OFF, for per-app native notification senders.
2. Create a persistent per-app notification helper with unique bundle identifier, signed locally, and icon supplied by AirSync's Android app icon cache.
3. Provide an authenticated local IPC channel (for example an app-group-independent Unix domain socket with strict filesystem permissions) to forward notification action identifiers, reply text, and notification IDs to AirSync.
4. Extend the helper's `UNUserNotificationCenterDelegate` to forward tap, reply, and action events; reuse AirSync's existing action handling rather than duplicating Android protocol logic.
5. Coordinate delivered-notification state and dismissals across per-app notification centers; avoid treating missing AirSync-owned notifications as Android dismissals.
6. Preserve call and Quick Share notifications in the original AirSync sender until their specialized actions are supported.
7. Test with WhatsApp/Instagram/Messages: icon only on left, sender/title/body, inline reply, open/view, dismiss, reconnect, duplicate IDs, notification permissions, and macOS 27.
8. Only enable by default after a successful build and device-level verification.

## Existing build
`.github/workflows/build.yml` clones the upstream repository and patches clipboard handling. Keep that patch unchanged.

## References
- https://github.com/nsorros/notifly
- https://github.com/sameerasw/airsync-mac/blob/main/airsync-mac/Core/AppState.swift
- https://github.com/sameerasw/airsync-mac/blob/main/airsync-mac/Core/Util/NotificationDelegate.swift
