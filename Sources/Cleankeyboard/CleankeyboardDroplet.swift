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
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var assertionID: IOPMAssertionID = 0

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
                return nil // Drop the event
            },
            userInfo: nil
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
                        kIOPMAssertionTypeNoDisplaySleep as CFString,
                        UInt32(kIOPMAssertionLevelOn),
                        "Droppy Clean Keyboard" as CFString,
                        &assertionID
                    )
                    if success != kIOReturnSuccess {
                        host?.log.info("Failed to create power assertion to prevent display sleep.")
                    }
                }
                
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
        
        eventTap = nil
        runLoopSource = nil
        isCleaning = false
        host?.log.info("Stopped cleaning mode, keyboard restored.")
        publishActivity()
    }
    
    private func publishActivity() {
        if isCleaning {
            activitySubject.send(
                LiveActivityState(
                    priority: 999999,
                    accessibilityTitle: "Keyboard Locked",
                    isInteractive: true,
                    joinsPersistentActivitySet: true,
                    compactPresentation: CompactLiveActivityPresentationMetadata(
                        id: "cleankeyboard",
                        accessibilityLabel: "Keyboard",
                        accessibilityValue: "Locked",
                        preferredWidth: 64
                    )
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
        Button {
            droplet.toggleCleaning()
        } label: {
            ZStack {
                if let path = Bundle.module.path(forResource: "Keyboard", ofType: "png"),
                   let nsImage = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.8)
                }
                
                Color.black.opacity(0.2) // extra darkening
                    
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    HStack(spacing: DroppySpacing.xsm) {
                        Image(systemName: "keyboard.macwindow")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Clean Keyboard")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    
                    Spacer(minLength: 0)
                    
                    HStack {
                        Spacer()
                        Text(droplet.isCleaning ? "Click to Stop" : "Click to Start")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(droplet.isCleaning ? Color.red : Color.blue)
                            .cornerRadius(8)
                        Spacer()
                    }
                    
                    Spacer(minLength: 0)
                }
                .padding(DroppySpacing.mdl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .buttonStyle(.plain)
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
            HStack {
                Image(systemName: "keyboard.macwindow")
                    .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .padding(.trailing, DroppySpacing.sm)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(
            HStack {
                Spacer(minLength: 0)
                Button { 
                    self.toggleCleaning() 
                } label: { 
                    Image(systemName: "xmark") 
                }
                .buttonStyle(DroppyLiveActivityControlStyle(prominence: .accent))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        )
    }

    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(
            ZStack {
                if let path = Bundle.module.path(forResource: "Keyboard", ofType: "png"),
                   let nsImage = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.8)
                }
                
                Color.black.opacity(0.2) // Darken to make text legible
                    
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: "keyboard.macwindow")
                                .font(.system(size: 14, weight: .medium))
                            Text("Clean Keyboard")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text(self.isCleaning ? "Locking..." : "Ready")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .foregroundStyle(.white)
                    
                    Spacer(minLength: DroppySpacing.mdl)
                    
                    Button {
                        self.toggleCleaning()
                    } label: {
                        Text(self.isCleaning ? "Stop" : "Start")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 20)
                            .background(self.isCleaning ? Color.red : Color.blue)
                            .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DroppySpacing.md)
            }
            .frame(width: context.availableWidth, height: DroppyLiveActivityMetrics.cardContentHeight)
            .clipped()
        )
    }

    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView {
        AnyView(
            Image(systemName: "keyboard.macwindow")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        )
    }

    public func makeCompanionDetail(context: LiveActivityContext) -> AnyView? { nil }
}

// MARK: - Settings

extension CleankeyboardDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(CleankeyboardSettingsPane())
    }
}

private struct CleankeyboardSettingsPane: View {
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

// MARK: - Menu Bar Extra

extension CleankeyboardDroplet: MenuBarExtraProviding {
    public func makeMenuBarExtra() -> MenuBarExtraDescriptor? {
        MenuBarExtraDescriptor(title: "Clean Keyboard", systemImage: "keyboard.macwindow") {
            AnyView(
                Button(self.isCleaning ? "Stop Cleaning Keyboard" : "Start Cleaning Keyboard") {
                    self.toggleCleaning()
                }
            )
        }
    }
}
