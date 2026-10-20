import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import XCTest
@testable import MacResourceMonitor

@MainActor
final class SettingsInteractionTests: XCTestCase {
    func testDashboardDoesNotStretchIntoExtraVerticalSpaceAfterSelectionRoundTrip() throws {
        let name = "SettingsInteractionTests.layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MonitoringSettings(defaults: defaults)
        let store = MonitoringStore(settings: settings)
        store.stop()
        let navigation = DashboardNavigation()
        var measuredHeight: CGFloat = 0
        let hosting = NSHostingView(rootView: DashboardView(store: store, navigation: navigation)
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { measuredHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { measuredHeight = $0 }
                })
                .frame(width: 380, height: 1600, alignment: .top))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 1600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 1600)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func layout() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        layout()
        let initialHeight = measuredHeight
        XCTAssertGreaterThan(initialHeight, 100)
        XCTAssertLessThan(initialHeight, 1000, "Home should fit its cards rather than stretch to the host height")
        for section in MetricSection.allCases {
            navigation.openSettings()
            settings.set(section, enabled: false)
            layout()
            navigation.returnHome()
            layout()
            navigation.openSettings()
            settings.set(section, enabled: true)
            layout()
            navigation.returnHome()
            layout()
            XCTAssertEqual(measuredHeight, initialHeight, accuracy: 1, "Restoring \(section) should restore the original compact height")
        }
    }

    func testDashboardRowsCompactHiddenSectionsWithoutAnEmptyGridRow() {
        var selection = MetricSelection.all
        selection.set(.memory, enabled: false)
        XCTAssertEqual(DashboardPresentation(selection: selection).cardRows,
                       [[.cpu, .upload], [.download, .chipTemperature], [.fan]])
        selection.set(.memory, enabled: true)
        XCTAssertEqual(DashboardPresentation(selection: selection).cardRows,
                       [[.cpu, .memory], [.upload, .download], [.chipTemperature, .fan]])
        for section in MetricSection.allCases where section != .diskCapacity {
            selection.set(section, enabled: false)
        }
        XCTAssertTrue(DashboardPresentation(selection: selection).cardRows.isEmpty,
                      "Disk-only home must not reserve a blank card row")
    }

    func testDashboardNavigationStateReturnsHomeAfterSettings() {
        let navigation = DashboardNavigation()
        XCTAssertFalse(navigation.showingSettings)
        navigation.openSettings()
        XCTAssertTrue(navigation.showingSettings)
        navigation.returnHome()
        XCTAssertFalse(navigation.showingSettings)
    }

    func testSevenSelectionButtonAppearancesFollowPersistedState() throws {
        let name = "SettingsInteractionTests.selection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MonitoringSettings(defaults: defaults)
        for section in MetricSection.allCases {
            var appearance = SectionButtonAppearance(isSelected: settings.selection.contains(section))
            XCTAssertTrue(appearance.isHighlighted, "\(section) defaults to a highlighted button")
            XCTAssertEqual(appearance.accessibilityValue, "显示")
            settings.set(section, enabled: false)
            appearance = .init(isSelected: settings.selection.contains(section))
            XCTAssertFalse(appearance.isHighlighted, "\(section) is still clickable but gray")
            XCTAssertEqual(appearance.accessibilityValue, "不显示")
            let restored = MonitoringSettings(defaults: defaults)
            XCTAssertEqual(SectionButtonAppearance(isSelected: restored.selection.contains(section)).accessibilityValue,
                           "不显示")
            settings.set(section, enabled: true)
        }
    }

    func testSelectionButtonBackgroundsDifferInLightAndDarkAppearances() throws {
        for mode in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: mode))
            var selected: NSColor?
            var unselected: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                selected = NSColor(SectionButtonAppearance(isSelected: true).background).usingColorSpace(.deviceRGB)
                unselected = NSColor(SectionButtonAppearance(isSelected: false).background).usingColorSpace(.deviceRGB)
            }
            let active = try XCTUnwrap(selected)
            let inactive = try XCTUnwrap(unselected)
            XCTAssertNotEqual(active, inactive, "\(mode): selection must be visually distinct")
            XCTAssertEqual(inactive.redComponent, inactive.greenComponent, accuracy: 0.08)
            XCTAssertEqual(inactive.greenComponent, inactive.blueComponent, accuracy: 0.08)
        }
    }

    func testReturnButtonFrameRemainsVisibleAfterScrollAndPressReturnsHome() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Test runner has no macOS Accessibility permission; button frame, scrolling and press cannot be verified")
        }
        let name = "SettingsInteractionTests.ax.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let navigation = DashboardNavigation()
        navigation.openSettings()
        let hosting = NSHostingView(rootView: SettingsView(
            loginItemManager: LoginItemManager(service: SettingsTestLoginService()),
            settings: MonitoringSettings(defaults: defaults),
            onBack: { navigation.returnHome() }
        ))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 380, height: 320),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let elements = accessibilityDescendants(of: app)
        let button = try XCTUnwrap(elements.first {
            (axAttribute($0, kAXIdentifierAttribute) as String?) == "monitoring.settings.returnHome"
        }, "Return button absent from the live accessibility tree")
        let buttonFrame = try XCTUnwrap(axFrame(button))
        let windows: [AXUIElement] = axAttribute(app, kAXWindowsAttribute) ?? []
        let viewport = try XCTUnwrap(windows.compactMap(axFrame).first {
            abs($0.width - 380) < 2 && abs($0.height - 320) < 2 && $0.contains(buttonFrame)
        }, "Button must be fully inside the actual 380x320 window frame")

        XCTAssertGreaterThan(buttonFrame.midY, viewport.midY,
                             "Return button belongs in the bottom half of the settings window")
        XCTAssertLessThan(buttonFrame.midX, viewport.midX,
                          "Return button belongs on the left side of the footer")

        let scrollArea = try XCTUnwrap(elements.first {
            (axAttribute($0, kAXRoleAttribute) as String?) == kAXScrollAreaRole
        }, "Settings content must expose a scroll area")
        let scrollBar: AXUIElement = try XCTUnwrap(axAttribute(scrollArea, kAXVerticalScrollBarAttribute))
        XCTAssertEqual(AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString,
                                                     NSNumber(value: 1)), .success, "Scroll content to bottom")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let scrolled = try XCTUnwrap(accessibilityDescendants(of: app).first {
            (axAttribute($0, kAXIdentifierAttribute) as String?) == "monitoring.settings.returnHome"
        })
        let scrolledFrame = try XCTUnwrap(axFrame(scrolled))
        XCTAssertTrue(viewport.contains(scrolledFrame), "Return button must remain inside the viewport")
        XCTAssertEqual(scrolledFrame.minY, buttonFrame.minY, accuracy: 1,
                       "Scrolling the settings must not move the fixed return footer")
        XCTAssertEqual(AXUIElementPerformAction(scrolled, kAXPressAction as CFString), .success)
        XCTAssertFalse(navigation.showingSettings, "Pressing the actual button must return to home")
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = axAttribute(element, kAXPositionAttribute),
              let size: AXValue = axAttribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func axAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func accessibilityDescendants(of root: AXUIElement) -> [AXUIElement] {
        let children: [AXUIElement] = axAttribute(root, kAXChildrenAttribute) ?? []
        return children.flatMap { [$0] + accessibilityDescendants(of: $0) }
    }
}

@MainActor
private final class SettingsTestLoginService: LoginService {
    var status: SMAppService.Status { .notRegistered }
    func register() throws { XCTFail("Unexpected login registration") }
    func unregister() throws { XCTFail("Unexpected login unregistration") }
}
