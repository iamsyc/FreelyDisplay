//
//  VoidDisplayApp.swift
//  VoidDisplay
//
//

import SwiftUI
import ScreenCaptureKit
import CoreGraphics
import Observation

@main
struct VoidDisplayApp: App {
    @State private var appHelper = AppBootstrap.makeAppHelper()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(appHelper)
        }

        WindowGroup(for: UUID.self) { $sessionId in
            CaptureDisplayWindowRoot(sessionId: sessionId)
                .environment(appHelper)
        }

        Settings {
            AppSettingsView()
                .environment(appHelper)
        }
    }
}

@MainActor
private enum AppBootstrap {
    static func makeAppHelper() -> AppHelper {
        guard UITestRuntime.isEnabled else {
            return AppHelper()
        }

        let scenario = UITestRuntime.scenario
        return AppHelper(
            virtualDisplayService: UITestVirtualDisplayService(scenario: scenario),
            startupPlan: .init(
                shouldRestoreVirtualDisplays: true,
                shouldStartWebService: false,
                postRestoreConfiguration: { controller in
                    controller.applyUITestPresentationState(scenario: scenario)
                }
            )
        )
    }
}

@MainActor
@Observable
final class AppHelper {
    private static let xCTestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    struct StartupPlan {
        var shouldRestoreVirtualDisplays: Bool
        var shouldStartWebService: Bool
        var postRestoreConfiguration: (@MainActor (VirtualDisplayController) -> Void)?

        static let standard = StartupPlan(
            shouldRestoreVirtualDisplays: true,
            shouldStartWebService: true,
            postRestoreConfiguration: nil
        )

        static let skipAll = StartupPlan(
            shouldRestoreVirtualDisplays: false,
            shouldStartWebService: false,
            postRestoreConfiguration: nil
        )
    }

    struct ScreenMonitoringSession: Identifiable {
        enum State {
            case starting
            case active
        }

        let id: UUID
        let displayID: CGDirectDisplayID
        let displayName: String
        let resolutionText: String
        let isVirtualDisplay: Bool
        let stream: SCStream
        let delegate: StreamDelegate
        var state: State
    }

    typealias VirtualDisplayError = VirtualDisplayService.VirtualDisplayError
    typealias SharePageURLFailure = SharingController.SharePageURLFailure

    let capture: CaptureController
    let sharing: SharingController
    let virtualDisplay: VirtualDisplayController

    init(
        preview: Bool = false,
        captureMonitoringService: (any CaptureMonitoringServiceProtocol)? = nil,
        sharingService: (any SharingServiceProtocol)? = nil,
        virtualDisplayService: (any VirtualDisplayServiceProtocol)? = nil,
        appliedBadgeDisplayDurationNanoseconds: UInt64 = 2_500_000_000,
        startupPlan: StartupPlan? = nil,
        isRunningUnderXCTestOverride: Bool? = nil
    ) {
        let isRunningUnderXCTest = isRunningUnderXCTestOverride
            ?? (ProcessInfo.processInfo.environment[Self.xCTestConfigurationEnvironmentKey] != nil)
        let resolvedStartupPlan = startupPlan ?? (isRunningUnderXCTest ? .skipAll : .standard)
        let resolvedCaptureMonitoringService = captureMonitoringService ?? CaptureMonitoringService()
        let resolvedSharingService = sharingService ?? SharingService()
        let resolvedVirtualDisplayService = virtualDisplayService ?? VirtualDisplayService()

        let capture = CaptureController(captureMonitoringService: resolvedCaptureMonitoringService)
        let sharing = SharingController(sharingService: resolvedSharingService)
        self.capture = capture
        self.sharing = sharing
        self.virtualDisplay = VirtualDisplayController(
            virtualDisplayService: resolvedVirtualDisplayService,
            appliedBadgeDisplayDurationNanoseconds: appliedBadgeDisplayDurationNanoseconds,
            stopDependentStreamsBeforeRebuild: { displayID in
                capture.stopDependentStreamsBeforeRebuild(
                    displayID: displayID,
                    sharingController: sharing
                )
            }
        )

        guard !preview else { return }

        if resolvedStartupPlan.shouldStartWebService {
            Task { [weak self] in
                _ = await self?.sharing.startWebService()
            }
        }

        if resolvedStartupPlan.shouldRestoreVirtualDisplays {
            virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()
            resolvedStartupPlan.postRestoreConfiguration?(virtualDisplay)
        }
    }

    func registerShareableDisplays(_ displays: [SCDisplay]) {
        sharing.registerShareableDisplays(displays) { [weak self] displayID in
            self?.virtualSerialForManagedDisplay(displayID)
        }
    }

    func isManagedVirtualDisplay(displayID: CGDirectDisplayID) -> Bool {
        virtualDisplay.displays.contains(where: { $0.displayID == displayID })
    }

    private func virtualSerialForManagedDisplay(_ displayID: CGDirectDisplayID) -> UInt32? {
        virtualDisplay.displays.first(where: { $0.displayID == displayID })?.serialNum
    }
}
