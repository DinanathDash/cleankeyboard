//
//  CleankeyboardDroplet.swift
//  Cleankeyboard
//

import Combine
import CoreGraphics
import ApplicationServices
import IOKit.pwr_mgt
import AppKit
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(CleankeyboardPrincipal)
public final class CleankeyboardPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { CleankeyboardDroplet() }
}

/// Clean Keyboard.
@MainActor
public final class CleankeyboardDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "cleankeyboard"

    private var host: DropletHost?
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)

    @Published public private(set) var isCleaning: Bool = false
    @Published private var isShowingUnlockConfirmation: Bool = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var assertionID: IOPMAssertionID = 0
    private var notificationObservers: [NSObjectProtocol] = []

    public func activate(host: DropletHost) throws {
        self.host = host
        host.log.info("Clean Keyboard activated")
        UserDefaults.standard.register(defaults: ["preventScreenSleep": true])
        
        if host.isGranted(.globalShortcuts) {
            host.shortcuts.register(id: "toggle", title: "Toggle Clean Keyboard", defaultShortcut: nil) { [weak self] in
                self?.toggleCleaning()
            }
        }
    }

    public func deactivate() {
        if isCleaning {
            stopCleaning()
        }
        activitySubject.send(nil)
        host = nil
    }

    public func toggleCleaning() {
        if isCleaning {
            stopCleaning()
        } else {
            startCleaning()
        }
    }

    private func startCleaning() {
        guard !isCleaning else { return }
        
        isShowingUnlockConfirmation = false
        
        // Prompt for Accessibility permissions if not already granted
        let options = ["AXTrustedCheckOptionPrompt": true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        guard accessEnabled else {
            host?.log.info("Accessibility permissions missing. Prompting user...")
            return
        }
        
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | 
                                (1 << CGEventType.keyUp.rawValue) | 
                                (1 << CGEventType.flagsChanged.rawValue) | 
                                (1 << 14) // NX_SYSDEFINED
        
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let ref = refcon {
                        let droplet = Unmanaged<CleankeyboardDroplet>.fromOpaque(ref).takeUnretainedValue()
                        if let tap = droplet.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                return nil // Drop the event
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        
        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                isCleaning = true
                host?.log.info("Started cleaning mode, keyboard blocked.")
                
                if UserDefaults.standard.bool(forKey: "preventScreenSleep") {
                    let success = IOPMAssertionCreateWithName(
                        kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                        UInt32(kIOPMAssertionLevelOn),
                        "Droppy Clean Keyboard" as CFString,
                        &assertionID
                    )
                    if success != kIOReturnSuccess {
                        host?.log.info("Failed to create power assertion to prevent display sleep.")
                    }
                }
                
                let center = NSWorkspace.shared.notificationCenter
                notificationObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.host?.log.info("System is sleeping, automatically disabling Clean Keyboard.")
                        self?.stopCleaning()
                    }
                })
                notificationObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.host?.log.info("Screens slept, automatically disabling Clean Keyboard.")
                        self?.stopCleaning()
                    }
                })
                notificationObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.host?.log.info("Screen locked, automatically disabling Clean Keyboard.")
                        self?.stopCleaning()
                    }
                })
                
                publishActivity()
            } else {
                host?.log.info("Failed to create run loop source.")
            }
        } else {
            host?.log.info("Failed to create event tap. Make sure Droppy has Accessibility permissions.")
        }
    }

    private func stopCleaning() {
        guard isCleaning else { return }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        
        for observer in notificationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        notificationObservers.removeAll()
        
        eventTap = nil
        runLoopSource = nil
        isCleaning = false
        isShowingUnlockConfirmation = true
        host?.log.info("Stopped cleaning mode, keyboard restored.")
        publishActivity()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if !self.isCleaning && self.isShowingUnlockConfirmation {
                self.isShowingUnlockConfirmation = false
                self.publishActivity()
            }
        }
    }
    
    private func publishActivity() {
        if isCleaning || isShowingUnlockConfirmation {
            activitySubject.send(
                LiveActivityState(
                    priority: 200,
                    accessibilityTitle: isCleaning ? "Keyboard Locked" : "Keyboard Unlocked",
                    isInteractive: false,
                    joinsPersistentActivitySet: false,
                    compactPresentation: nil,
                    expandedWidgetID: "cleankeyboard"
                )
            )
        } else {
            activitySubject.send(nil)
        }
    }
}

// MARK: - Shelf widget

extension CleankeyboardDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "cleankeyboard",
                title: "Clean Keyboard",
                systemImage: "keyboard",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(150)
                )
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(CleankeyboardWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

/// The widget.
private struct CleankeyboardWidget: View {
    @ObservedObject var droplet: CleankeyboardDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text("Clean Keyboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            
            Spacer(minLength: 0)
            
            HStack {
                Spacer(minLength: 0)
                Button {
                    droplet.toggleCleaning()
                } label: {
                    Text(droplet.isCleaning ? "Stop Cleaning" : "Start Cleaning")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.primaryTextAuto)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(DroppyQuietButtonStyle())
                Spacer(minLength: 0)
            }
            
            Spacer(minLength: 0)
        }
        .padding(DroppySpacing.mdl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Live activity

extension CleankeyboardDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func liveActivitySeatDidChange(_ seat: DropletLiveActivitySeat) {
        host?.log.debug("live activity seat is now \(seat)")
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(
            Image(systemName: isShowingUnlockConfirmation ? "checkmark.circle.fill" : "keyboard.macwindow")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .id(isShowingUnlockConfirmation)
                .transition(DroppyTransition.compactContent)
        )
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(
            Image(systemName: isShowingUnlockConfirmation ? "lock.open.fill" : "lock.fill")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .id(isShowingUnlockConfirmation)
                .transition(DroppyTransition.compactContent)
        )
    }

    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(EmptyView())
    }

    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView {
        AnyView(
            Image(systemName: isShowingUnlockConfirmation ? "checkmark.circle.fill" : "keyboard.macwindow")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        )
    }

    public func makeCompanionDetail(context: LiveActivityContext) -> AnyView? { nil }
}

// MARK: - Settings

extension CleankeyboardDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(CleankeyboardSettingsPane(droplet: self))
    }
}

private struct CleankeyboardSettingsPane: View {
    @ObservedObject var droplet: CleankeyboardDroplet
    @AppStorage("preventScreenSleep") private var preventScreenSleep = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Prevent display from sleeping",
                    subtitle: "Keeps the screen awake while cleaning so you aren't locked out of your Mac.",
                    isOn: $preventScreenSleep
                )
            }
        }
    }
}

