#!/usr/bin/env python3
"""Patch the upstream AirSync source with a custom Android banner.

Only mirrored Android notifications are affected. The macOS notification
system continues to handle calls, Quick Share and generic AirSync alerts.
"""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: iphone_style_notifications.py path/to/AppState.swift")

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")

anchor = r'''        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "\(appName) - \(title)"
'''

intercept = r'''        // macOS controls its own Notification Center's app logo and layout.
        // These Android-only banners are custom desktop windows instead.
        // Set the AirSyncCustomAndroidBanners preference to false to revert.
        let useCustomAndroidBanners =
            UserDefaults.standard.object(forKey: "AirSyncCustomAndroidBanners") as? Bool ?? true

        if let androidPackage = package, useCustomAndroidBanners {
            DispatchQueue.main.async {
                AirSyncMirrorBannerPresenter.shared.show(
                    appName: appName,
                    title: title,
                    message: body,
                    icon: appIcon,
                    package: androidPackage,
                    soundName: self.notificationSound
                )
            }
            return
        }

'''

if source.count(anchor) != 1:
    raise SystemExit("Upstream notification function changed; refusing unsafe patch")

extension = r'''

// MARK: - Custom Android notifications: right icon, centered, no AirSync logo.
//
// These desktop banners are not native Notification Center entries because
// macOS provides no supported way to remove/reposition the sender app icon.
private final class AirSyncMirrorBannerPresenter {
    static let shared = AirSyncMirrorBannerPresenter()

    private var bannerPanel: NSPanel?
    private var dismissal: DispatchWorkItem?

    func show(
        appName: String,
        title: String,
        message: String,
        icon: NSImage?,
        package: String,
        soundName: String
    ) {
        // Invoked on the main thread by postNativeNotification.
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        dismiss()

        let banner = AirSyncMirrorBannerView(
            appName: appName,
            title: title,
            message: message,
            icon: icon,
            onOpen: { [weak self] in
                self?.dismiss()
                if AppState.shared.openAppOnNotificationClick {
                    _ = MacAppLaunchManager.open(package: package)
                }
            }
        )

        let hostingView = NSHostingView(rootView: banner)
        let width: CGFloat = 440
        // SwiftUI calculates the height, so one- and multi-line content
        // share the same vertical center without fixed text offsets.
        let height = max(CGFloat(86), min(CGFloat(200), hostingView.fittingSize.height))
        let area = screen.visibleFrame
        let frame = NSRect(
            x: area.maxX - width - 14,
            y: area.maxY - height - 12,
            width: width,
            height: height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        bannerPanel = panel

        let name = soundName == "default" ? "Glass" : soundName
        NSSound(named: NSSound.Name(name))?.play()

        // The most recent Android alert replaces the prior desktop banner.
        // Android history remains in the AirSync app's notification list.
        let task = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: task)
    }

    private func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        bannerPanel?.orderOut(nil)
        bannerPanel?.close()
        bannerPanel = nil
    }
}

private struct AirSyncMirrorBannerView: View {
    let appName: String
    let title: String
    let message: String
    let icon: NSImage?
    let onOpen: () -> Void

    private var heading: String {
        title.isEmpty ? appName : "\(appName) - \(title)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let icon = icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("\(appName) icon")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 440)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
    }
}
'''

if "AirSyncMirrorBannerPresenter" in source:
    raise SystemExit("Custom notification patch is already present")

updated = source.replace(anchor, intercept + anchor, 1)
updated += extension
path.write_text(updated, encoding="utf-8")
print(f"Applied iPhone-style Android notification patch to {path}")
