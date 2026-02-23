import CoreGraphics
import Testing
@testable import VoidDisplay

@MainActor
struct VirtualDisplayControllerTests {
    @Test func loadPersistedConfigsAndRestoreDesiredVirtualDisplaysSyncsState() {
        let service = MockVirtualDisplayService()
        let config = VirtualDisplayConfig(
            name: "Fixture",
            serialNum: 42,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        service.currentDisplayConfigs = [config]
        service.currentRunningConfigIds = [config.id]

        let sut = VirtualDisplayController(
            virtualDisplayService: service,
            appliedBadgeDisplayDurationNanoseconds: 1,
            stopDependentStreamsBeforeRebuild: { _ in }
        )

        sut.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        #expect(service.loadPersistedConfigsCallCount == 1)
        #expect(service.restoreDesiredVirtualDisplaysCallCount == 1)
        #expect(sut.displayConfigs.count == 1)
        #expect(sut.runningConfigIds.contains(config.id))
    }

    @Test func applyUITestPresentationStateSetsExpectedFlags() {
        let service = MockVirtualDisplayService()
        let fixtureConfigs = UITestFixture.virtualDisplayConfigs()
        service.currentDisplayConfigs = fixtureConfigs
        service.currentRunningConfigIds = Set(fixtureConfigs.prefix(1).map(\.id))

        let sut = VirtualDisplayController(
            virtualDisplayService: service,
            appliedBadgeDisplayDurationNanoseconds: 1,
            stopDependentStreamsBeforeRebuild: { _ in }
        )
        sut.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        guard let firstConfigID = fixtureConfigs.first?.id else {
            Issue.record("Missing fixture config")
            return
        }

        sut.applyUITestPresentationState(scenario: .virtualDisplayRebuilding)
        #expect(sut.isRebuilding(configId: firstConfigID))

        sut.applyUITestPresentationState(scenario: .virtualDisplayRebuildFailed)
        #expect(!sut.isRebuilding(configId: firstConfigID))
        #expect(sut.rebuildFailureMessage(configId: firstConfigID) != nil)
    }

    @Test func updateConfigAndApplyModesDelegateToService() {
        let service = MockVirtualDisplayService()
        let config = VirtualDisplayConfig(
            name: "Config",
            serialNum: 9,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1680, height: 1050, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        service.currentDisplayConfigs = [config]

        let sut = VirtualDisplayController(
            virtualDisplayService: service,
            appliedBadgeDisplayDurationNanoseconds: 1,
            stopDependentStreamsBeforeRebuild: { _ in }
        )
        sut.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        var updated = config
        updated.name = "Updated Config"
        sut.updateConfig(updated)

        let newModes: [ResolutionSelection] = [
            .init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: true)
        ]
        sut.applyModes(configId: config.id, modes: newModes)

        #expect(service.currentDisplayConfigs.first?.name == "Updated Config")
        #expect(service.applyModesCallCount == 1)
        #expect(service.applyModesConfigIds == [config.id])
    }
}
