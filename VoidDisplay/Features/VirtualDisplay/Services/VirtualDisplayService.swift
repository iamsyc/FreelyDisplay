import Foundation
import CoreGraphics
import OSLog

@MainActor
final class VirtualDisplayService {
    private static let managedVendorID: UInt32 = 0x3456
    private static let managedProductID: UInt32 = 0x1234
    private static let rollbackOfflineWaitTimeout: TimeInterval = 1.2
    private static let rebuildTerminationTimeout: TimeInterval = 2.0
    private static let rebuildOfflineTimeout: TimeInterval = 4.0
    private static let rebuildFinalOfflineConfirmationTimeout: TimeInterval = 0.8
    private static let rebuildFleetCreationCooldown: TimeInterval = 0.6
    private static let rebuildFleetCreationCooldownFastTeardown: TimeInterval = 0.15
    private static let deferredTopologyRecheckMinimumDelay: TimeInterval = 0.03
    private static let deferredTopologyRecheckMultiplier: TimeInterval = 1.5
    private static let aggressiveEnableUnsettledTeardownCooldown: TimeInterval = 0.35
    private static let adaptiveCooldownPollIntervalFloor: TimeInterval = 0.01
    private static let adaptiveCooldownPollIntervalCeiling: TimeInterval = 0.05
    private static let adaptiveCooldownStableSamplesRequired = 2
    private static let topologyStabilityAdaptiveProbeDivisor: TimeInterval = 6
    private static let topologyStabilityAdaptiveBackoffMultiplier: TimeInterval = 1.5

    enum TopologyRecoveryMode {
        case fast
        case aggressive
    }

    enum ReorderDirection {
        case up
        case down
    }

    private struct AdaptiveCooldownResult {
        let waitedSeconds: TimeInterval
        let completedEarly: Bool
    }

    enum VirtualDisplayError: LocalizedError {
        case duplicateSerialNumber(UInt32)
        case invalidConfiguration(String)
        case creationFailed
        case configNotFound
        case teardownTimedOut
        case topologyRepairFailed
        case topologyUnstableAfterEnable

        var errorDescription: String? {
            switch self {
            case .duplicateSerialNumber(let num):
                return String(localized: "Serial number \(num) is already in use.")
            case .invalidConfiguration(let reason):
                return String(localized: "Invalid configuration: \(reason)")
            case .creationFailed:
                return String(localized: "Virtual display creation failed.")
            case .configNotFound:
                return String(localized: "Display configuration not found.")
            case .teardownTimedOut:
                return String(localized: "Display teardown timed out. Wait a moment and try rebuilding again.")
            case .topologyRepairFailed:
                return String(localized: "Display topology repair failed. Open System Display Settings and recheck arrangement.")
            case .topologyUnstableAfterEnable:
                return String(localized: "Display topology did not stabilize after enabling. Please try again.")
            }
        }
    }

    private let persistenceService: VirtualDisplayPersistenceService
    private var displays: [CGVirtualDisplay] = []
    private var displayConfigs: [VirtualDisplayConfig] = []
    private var runningConfigIds: Set<UUID> = []
    private var restoreFailures: [VirtualDisplayRestoreFailure] = []
    private var activeDisplaysByConfigId: [UUID: CGVirtualDisplay] = [:]
    private var runtimeDisplayIDHintsByConfigId: [UUID: CGDirectDisplayID] = [:]
    private var runtimeGenerationByConfigId: [UUID: UInt64] = [:]
    private var aggressiveRecoveryPendingEnableConfigIDs: Set<UUID> = []
    private var nextRuntimeGeneration: UInt64 = 1
    private let displayReconfigurationMonitor: any DisplayReconfigurationMonitoring
    private let topologyInspector: any DisplayTopologyInspecting
    private let topologyRepairer: any DisplayTopologyRepairing
    private let teardownCoordinator: DisplayTeardownCoordinator
    private let topologyStabilityTimeout: TimeInterval
    private let topologyStabilityPollInterval: TimeInterval
    private let rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)?

    convenience init(persistenceService: VirtualDisplayPersistenceService? = nil) {
        self.init(
            persistenceService: persistenceService,
            displayReconfigurationMonitor: VirtualDisplayReconfigurationMonitor(),
            managedDisplayOnlineChecker: makeSystemManagedDisplayOnlineChecker(
                managedVendorID: Self.managedVendorID,
                managedProductID: Self.managedProductID
            ),
            topologyStabilityTimeout: 3.0,
            topologyStabilityPollInterval: 0.3
        )
    }

    convenience init(
        persistenceService: VirtualDisplayPersistenceService? = nil,
        displayReconfigurationMonitor: any DisplayReconfigurationMonitoring,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        topologyStabilityTimeout: TimeInterval = 3.0,
        topologyStabilityPollInterval: TimeInterval = 0.3
    ) {
        self.init(
            persistenceService: persistenceService,
            displayReconfigurationMonitor: displayReconfigurationMonitor,
            topologyInspector: SystemDisplayTopologyInspector(),
            topologyRepairer: SystemDisplayTopologyRepairer(),
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            topologyStabilityTimeout: topologyStabilityTimeout,
            topologyStabilityPollInterval: topologyStabilityPollInterval,
            rebuildRuntimeDisplayHook: nil
        )
    }

    init(
        persistenceService: VirtualDisplayPersistenceService? = nil,
        displayReconfigurationMonitor: any DisplayReconfigurationMonitoring,
        topologyInspector: any DisplayTopologyInspecting,
        topologyRepairer: any DisplayTopologyRepairing,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool,
        topologyStabilityTimeout: TimeInterval,
        topologyStabilityPollInterval: TimeInterval,
        rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)? = nil
    ) {
        self.persistenceService = persistenceService ?? VirtualDisplayPersistenceService()
        self.displayReconfigurationMonitor = displayReconfigurationMonitor
        self.topologyInspector = topologyInspector
        self.topologyRepairer = topologyRepairer
        self.teardownCoordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            isReconfigurationMonitorAvailable: false
        )
        self.topologyStabilityTimeout = topologyStabilityTimeout
        self.topologyStabilityPollInterval = topologyStabilityPollInterval
        self.rebuildRuntimeDisplayHook = rebuildRuntimeDisplayHook
        teardownCoordinator.setRuntimeGenerationProvider { [weak self] configId in
            self?.runtimeGenerationByConfigId[configId]
        }

        let monitorAvailable = displayReconfigurationMonitor.start { [weak self] in
            self?.teardownCoordinator.completeOfflineWaitersIfPossible()
        }
        teardownCoordinator.setReconfigurationMonitorAvailable(monitorAvailable)
        if !monitorAvailable {
            AppLog.virtualDisplay.error(
                "Failed to register display reconfiguration callback. Offline wait will use polling fallback."
            )
        }
    }

    var currentDisplays: [CGVirtualDisplay] {
        displays
    }

    var currentDisplayConfigs: [VirtualDisplayConfig] {
        displayConfigs
    }

    var currentRunningConfigIds: Set<UUID> {
        runningConfigIds
    }

    var currentRestoreFailures: [VirtualDisplayRestoreFailure] {
        restoreFailures
    }

    func loadPersistedConfigs() {
        displayConfigs = persistenceService.loadConfigs()
    }

    func restoreDesiredVirtualDisplays() {
        restoreFailures = persistenceService.restoreDesiredVirtualDisplays(from: displayConfigs) { [weak self] config in
            guard let self else { return }
            _ = try self.createRuntimeDisplay(from: config)
        }
    }

    func clearRestoreFailures() {
        restoreFailures = []
    }

    @discardableResult
    func resetAllVirtualDisplayData() -> Int {
        let removedConfigCount = displayConfigs.count

        teardownCoordinator.cancelAllTerminationWaiters()
        teardownCoordinator.cancelAllOfflineWaiters()
        activeDisplaysByConfigId.removeAll()
        runtimeDisplayIDHintsByConfigId.removeAll()
        runtimeGenerationByConfigId.removeAll()
        aggressiveRecoveryPendingEnableConfigIDs.removeAll()
        runningConfigIds.removeAll()
        displays.removeAll()
        restoreFailures.removeAll()
        displayConfigs.removeAll()
        persistenceService.resetConfigs()

        return removedConfigCount
    }

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay? {
        activeDisplaysByConfigId[configId]
    }

    func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID? {
        if let runtime = activeDisplaysByConfigId[configId] {
            return runtime.displayID
        }
        return runtimeDisplayIDHintsByConfigId[configId]
    }

    func isVirtualDisplayRunning(configId: UUID) -> Bool {
        runningConfigIds.contains(configId)
    }

    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> CGVirtualDisplay {
        if displays.contains(where: { $0.serialNum == serialNum }) ||
            displayConfigs.contains(where: { $0.serialNum == serialNum }) {
            throw VirtualDisplayError.duplicateSerialNumber(serialNum)
        }

        guard !modes.isEmpty else {
            throw VirtualDisplayError.invalidConfiguration(String(localized: "At least one resolution mode is required."))
        }

        let config = VirtualDisplayConfig(
            name: name,
            serialNum: serialNum,
            physicalWidth: Int(physicalSize.width),
            physicalHeight: Int(physicalSize.height),
            modes: modes.map {
                VirtualDisplayConfig.ModeConfig(
                    width: $0.width,
                    height: $0.height,
                    refreshRate: $0.refreshRate,
                    enableHiDPI: $0.enableHiDPI
                )
            },
            desiredEnabled: true
        )

        displayConfigs.append(config)
        persistConfigs()

        do {
            let display = try createRuntimeDisplay(from: config, maxPixels: maxPixels)
            return display
        } catch {
            displayConfigs.removeAll { $0.id == config.id }
            persistConfigs()
            AppLog.virtualDisplay.error(
                "Create display failed (name: \(name, privacy: .public), serial: \(serialNum, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    @discardableResult
    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay {
        try createRuntimeDisplay(from: config)
    }

    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        if let index = displayConfigs.firstIndex(where: { $0.serialNum == display.serialNum }) {
            var updated = displayConfigs[index]
            updated.desiredEnabled = false
            displayConfigs[index] = updated
        } else {
            var config = VirtualDisplayConfig(from: display, modes: modes)
            config.desiredEnabled = false
            displayConfigs.append(config)
        }

        let disablingMainDisplay = runtimeDisplayIDForSerial(display.serialNum) == CGMainDisplayID() ||
            display.displayID == CGMainDisplayID()
        AppLog.virtualDisplay.notice(
            "Disable display requested (serial: \(display.serialNum, privacy: .public), displayID: \(display.displayID, privacy: .public), disablingMain: \(disablingMainDisplay, privacy: .public))."
        )
        logTopologySnapshot("disableDisplay:pre-clear", snapshot: currentTopologySnapshot())
        if disablingMainDisplay {
            markAggressiveRecoveryPendingForSerial(display.serialNum)
        }
        clearRuntimeTrackingForSerialNum(display.serialNum, keepGeneration: true)
        persistConfigs()
    }

    func disableDisplayByConfig(_ configId: UUID) throws {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else { return }

        var updated = displayConfigs[index]
        updated.desiredEnabled = false
        displayConfigs[index] = updated

        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? displayConfigs[index].serialNum
        let runtimeDisplayID = runtimeDisplayID(for: configId)
        let disablingMain = runtimeDisplayID == CGMainDisplayID()
        AppLog.virtualDisplay.notice(
            "Disable-by-config requested (config: \(configId.uuidString, privacy: .public), serial: \(runtimeSerialNum, privacy: .public), runtimeDisplayID: \(String(describing: runtimeDisplayID), privacy: .public), disablingMain: \(disablingMain, privacy: .public))."
        )
        logTopologySnapshot("disableDisplayByConfig:pre-clear", snapshot: currentTopologySnapshot())
        if disablingMain {
            aggressiveRecoveryPendingEnableConfigIDs.insert(configId)
        }
        clearRuntimeTracking(configId: configId, serialNum: runtimeSerialNum, keepGeneration: true)
        persistConfigs()
    }

    func enableDisplay(_ configId: UUID) async throws {
        guard let index = displayConfigs.firstIndex(where: { $0.id == configId }) else {
            throw VirtualDisplayError.configNotFound
        }

        var updated = displayConfigs[index]
        updated.desiredEnabled = true
        displayConfigs[index] = updated
        persistConfigs()

        let config = displayConfigs[index]
        let enableStart = DispatchTime.now().uptimeNanoseconds
        let topologyBeforeEnable = currentTopologySnapshot()
        let preferredMainDisplayID = TopologyHealthEvaluator.preferredManagedMainDisplayID(
            snapshot: topologyBeforeEnable
        )
        let recoveryMode: TopologyRecoveryMode = aggressiveRecoveryPendingEnableConfigIDs.contains(configId)
            ? .aggressive
            : .fast
        AppLog.virtualDisplay.notice(
            "Enable display requested (config: \(configId.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), recoveryMode: \(recoveryMode.logDescription, privacy: .public), preferredMain: \(String(describing: preferredMainDisplayID), privacy: .public), pendingGeneration: \(String(describing: self.runtimeGenerationByConfigId[configId]), privacy: .public), isRunning: \(self.runningConfigIds.contains(configId), privacy: .public))."
        )
        logTopologySnapshot("enableDisplay:pre-enable", snapshot: topologyBeforeEnable)

        var terminationConfirmed = true
        var offlineVerified = false
        if activeDisplaysByConfigId[configId] == nil,
           let pendingGeneration = runtimeGenerationByConfigId[configId] {
            let displayStillOnline = isManagedDisplayOnline(serialNum: config.serialNum)
            let shouldForceSettlement = recoveryMode == .aggressive
            if displayStillOnline || shouldForceSettlement {
                let settlement = await teardownCoordinator.waitForTeardownSettlement(
                    configId: configId,
                    expectedGeneration: pendingGeneration,
                    serialNum: config.serialNum,
                    terminationTimeout: 0.3,
                    offlineTimeout: 2.5
                )

                if shouldForceSettlement && !displayStillOnline {
                    AppLog.virtualDisplay.debug(
                        "Aggressive enable forced teardown settlement despite offline precheck (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(pendingGeneration, privacy: .public))."
                    )
                }
                if !settlement.terminationObserved {
                    AppLog.virtualDisplay.debug(
                        "Enable did not observe termination callback before settling on offline confirmation (config: \(config.id.uuidString, privacy: .public))."
                    )
                }
                AppLog.virtualDisplay.debug(
                    "Enable teardown settlement (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), terminationObserved: \(settlement.terminationObserved, privacy: .public), offlineConfirmed: \(settlement.offlineConfirmed, privacy: .public))."
                )
                if !settlement.offlineConfirmed {
                    AppLog.virtualDisplay.error(
                        "Enable aborted because previous display with same serial is still online after teardown settlement (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public), generation: \(pendingGeneration, privacy: .public))."
                    )
                    throw VirtualDisplayError.teardownTimedOut
                }
                terminationConfirmed = settlement.terminationObserved
            }
            offlineVerified = true
        }
        if activeDisplaysByConfigId[configId] == nil, !offlineVerified {
            let offlineConfirmed = await waitForManagedDisplayOffline(serialNum: config.serialNum)
            if !offlineConfirmed {
                AppLog.virtualDisplay.error(
                    "Enable aborted because previous display with same serial is still online (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public))."
                )
                throw VirtualDisplayError.teardownTimedOut
            }
            // Explicit offline confirmation is sufficient even if termination callback was missed.
            offlineVerified = true
        }

        do {
            let desiredManagedEnabledCount = displayConfigs.filter(\.desiredEnabled).count
            let shouldPreemptivelyUseFleetRebuild = recoveryMode == .aggressive &&
                !terminationConfirmed &&
                runningConfigIds.count >= 1 &&
                desiredManagedEnabledCount >= 2
            if shouldPreemptivelyUseFleetRebuild {
                AppLog.virtualDisplay.notice(
                    "Aggressive enable preemptively using coordinated fleet rebuild before creating target (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), runningManagedCount: \(self.runningConfigIds.count, privacy: .public), desiredManagedEnabledCount: \(desiredManagedEnabledCount, privacy: .public))."
                )
                try await rebuildManagedDisplayFleet(
                    prioritizing: configId,
                    fallbackPreferredMainDisplayID: preferredMainDisplayID,
                    teardownStrategy: .fleetOfflineOnly,
                    includePrioritizedConfigIfNotRunning: true
                )
                aggressiveRecoveryPendingEnableConfigIDs.remove(configId)
                return
            }
            if recoveryMode == .aggressive && !terminationConfirmed {
                let cooldown = await waitForAdaptiveManagedDisplayCooldown(
                    serialNumbers: [config.serialNum],
                    maxCooldown: Self.aggressiveEnableUnsettledTeardownCooldown
                )
                AppLog.virtualDisplay.notice(
                    "Aggressive enable teardown settle cooldown completed (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), maxCooldownSec: \(Self.aggressiveEnableUnsettledTeardownCooldown, privacy: .public), waitedMs: \(UInt64(cooldown.waitedSeconds * 1000), privacy: .public), earlyExit: \(cooldown.completedEarly, privacy: .public))."
                )
                logTopologySnapshot("enableDisplay:pre-create-post-cooldown", snapshot: currentTopologySnapshot())
            }
            var createdDisplay: CGVirtualDisplay? = try await createRuntimeDisplayWithRetries(
                from: config,
                terminationConfirmed: terminationConfirmed
            )
            guard createdDisplay != nil else {
                throw VirtualDisplayError.creationFailed
            }
            let createdDisplaySerialNum = createdDisplay?.serialNum ?? config.serialNum
            let createdDisplayID = createdDisplay?.displayID ?? 0
            AppLog.virtualDisplay.notice(
                "Enable created runtime display (config: \(config.id.uuidString, privacy: .public), serial: \(createdDisplaySerialNum, privacy: .public), displayID: \(createdDisplayID, privacy: .public), recoveryMode: \(recoveryMode.logDescription, privacy: .public))."
            )
            logTopologySnapshot("enableDisplay:post-create-pre-recovery", snapshot: currentTopologySnapshot())
            // Release local strong reference before recovery/rebuild teardown logic.
            createdDisplay = nil
            do {
                let shouldEscalateToFleetRebuild = recoveryMode == .aggressive &&
                    !terminationConfirmed &&
                    runningConfigIds.count >= 2
                if shouldEscalateToFleetRebuild {
                    AppLog.virtualDisplay.notice(
                        "Aggressive enable escalating to coordinated fleet rebuild because prior termination callback was not observed (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), runningManagedCount: \(self.runningConfigIds.count, privacy: .public))."
                    )
                    try await rebuildManagedDisplayFleet(
                        prioritizing: configId,
                        fallbackPreferredMainDisplayID: preferredMainDisplayID,
                        teardownStrategy: .fleetOfflineOnly
                    )
                } else {
                    try await ensureHealthyTopologyAfterEnable(
                        preferredMainDisplayID: preferredMainDisplayID,
                        recoveryMode: recoveryMode
                    )
                }
                aggressiveRecoveryPendingEnableConfigIDs.remove(configId)
            } catch {
                rollbackEnableRuntimeState(configId: configId, serialNum: createdDisplaySerialNum)
                let offlineConfirmed = await waitForManagedDisplayOffline(
                    serialNum: config.serialNum,
                    timeout: Self.rollbackOfflineWaitTimeout
                )
                if !offlineConfirmed {
                    AppLog.virtualDisplay.warning(
                        "Enable rollback did not observe offline state before timeout (serial: \(config.serialNum, privacy: .public), config: \(config.id.uuidString, privacy: .public), timeoutSec: \(Self.rollbackOfflineWaitTimeout, privacy: .public))."
                    )
                }
                throw error
            }
        } catch {
            AppLog.virtualDisplay.error(
                "Enable display failed (name: \(config.name, privacy: .public), serial: \(config.serialNum, privacy: .public), totalElapsedMs: \(self.elapsedMilliseconds(since: enableStart), privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    func destroyDisplay(_ configId: UUID) {
        guard let config = displayConfigs.first(where: { $0.id == configId }) else { return }

        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? config.serialNum
        aggressiveRecoveryPendingEnableConfigIDs.remove(configId)
        clearRuntimeTracking(configId: configId, serialNum: runtimeSerialNum, keepGeneration: false)

        displayConfigs.removeAll { $0.id == configId }
        persistConfigs()
    }

    func destroyDisplay(_ display: CGVirtualDisplay) {
        let serialNum = display.serialNum

        clearAggressiveRecoveryPendingForSerial(serialNum)
        clearRuntimeTrackingForSerialNum(serialNum, keepGeneration: false)

        displayConfigs.removeAll { $0.serialNum == serialNum }
        persistConfigs()
    }

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        displayConfigs.first { $0.id == configId }
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        guard let index = displayConfigs.firstIndex(where: { $0.id == updated.id }) else { return }
        displayConfigs[index] = updated
        persistConfigs()
    }

    @discardableResult
    func moveConfig(_ configId: UUID, direction: ReorderDirection) -> Bool {
        guard let sourceIndex = displayConfigs.firstIndex(where: { $0.id == configId }) else { return false }

        let destinationIndex: Int
        switch direction {
        case .up:
            destinationIndex = sourceIndex - 1
        case .down:
            destinationIndex = sourceIndex + 1
        }

        guard displayConfigs.indices.contains(destinationIndex) else { return false }

        displayConfigs.swapAt(sourceIndex, destinationIndex)
        persistConfigs()
        return true
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        guard let display = activeDisplaysByConfigId[configId] else { return }
        let settings = CGVirtualDisplaySettings()

        let anyHiDPI = modes.contains { $0.enableHiDPI }
        settings.hiDPI = anyHiDPI ? 1 : 0

        var displayModes: [CGVirtualDisplayMode] = []
        for mode in modes {
            if mode.enableHiDPI {
                displayModes.append(mode.hiDPIVersion().toVirtualDisplayMode())
            }
            displayModes.append(mode.toVirtualDisplayMode())
        }
        settings.modes = displayModes
        let applied = display.apply(settings)
        if !applied {
            AppLog.virtualDisplay.error("Apply virtual display modes failed (serial: \(display.serialNum, privacy: .public)).")
        }
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        guard let config = displayConfigs.first(where: { $0.id == configId }) else {
            throw VirtualDisplayError.configNotFound
        }
        let snapshotBeforeRebuild = currentTopologySnapshot()
        let preferredMainDisplayID = TopologyHealthEvaluator.preferredManagedMainDisplayID(
            snapshot: currentTopologySnapshot()
        )
        let targetRuntimeDisplayID = runtimeDisplayID(for: configId)
        let targetWasManagedMain = TopologyHealthEvaluator.managedDisplayID(
            for: config.serialNum,
            snapshot: snapshotBeforeRebuild
        ) == snapshotBeforeRebuild?.mainDisplayID || targetRuntimeDisplayID == CGMainDisplayID()
        let useCoordinatedRebuild = shouldUseCoordinatedRebuild(
            configId: configId,
            config: config,
            snapshot: snapshotBeforeRebuild
        )
        let coordinatedRebuildTeardownStrategy: FleetRebuildTeardownStrategy =
            (targetWasManagedMain || targetRuntimeDisplayID == CGMainDisplayID())
            ? .fleetOfflineOnly
            : .perDisplaySettlement
        AppLog.virtualDisplay.debug(
            "Rebuild strategy resolved (config: \(configId.uuidString, privacy: .public), coordinated: \(useCoordinatedRebuild, privacy: .public), runtimeMainMatch: \(targetRuntimeDisplayID == CGMainDisplayID(), privacy: .public), snapshotAvailable: \(snapshotBeforeRebuild != nil, privacy: .public), teardownStrategy: \(coordinatedRebuildTeardownStrategy.logDescription, privacy: .public))."
        )
        if useCoordinatedRebuild {
            try await rebuildManagedDisplayFleet(
                prioritizing: configId,
                fallbackPreferredMainDisplayID: preferredMainDisplayID,
                teardownStrategy: coordinatedRebuildTeardownStrategy
            )
            return
        }

        let runtimeSerialNum = activeDisplaysByConfigId[configId]?.serialNum ?? config.serialNum
        let generationToWaitFor = runningConfigIds.contains(configId)
            ? runtimeGenerationByConfigId[configId]
            : nil
        if runningConfigIds.contains(configId) {
            activeDisplaysByConfigId[configId] = nil
            runtimeDisplayIDHintsByConfigId[configId] = nil
            runningConfigIds.remove(configId)
            displays.removeAll { $0.serialNum == runtimeSerialNum }
        }

        let terminationConfirmed = try await teardownCoordinator.settleRebuildTeardown(
            configId: config.id,
            serialNum: config.serialNum,
            generationToWaitFor: generationToWaitFor,
            rebuildTerminationTimeout: Self.rebuildTerminationTimeout,
            rebuildOfflineTimeout: Self.rebuildOfflineTimeout,
            rebuildFinalOfflineConfirmationTimeout: Self.rebuildFinalOfflineConfirmationTimeout
        )

        let recreatedTargetDisplayID = try await recreateRuntimeDisplayForRebuild(
            config: config,
            terminationConfirmed: terminationConfirmed
        )
        let preferredMainAfterRebuild: CGDirectDisplayID?
        if targetWasManagedMain {
            preferredMainAfterRebuild = recreatedTargetDisplayID ?? preferredMainDisplayID
        } else {
            preferredMainAfterRebuild = preferredMainDisplayID
        }
        try await ensureHealthyTopologyAfterEnable(preferredMainDisplayID: preferredMainAfterRebuild)
    }

    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        displayConfigs.first { $0.serialNum == display.serialNum }
    }

    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        guard let index = displayConfigs.firstIndex(where: { $0.serialNum == display.serialNum }) else { return }
        var updated = displayConfigs[index]
        updated.modes = modes.map {
            VirtualDisplayConfig.ModeConfig(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        }
        displayConfigs[index] = updated
        persistConfigs()
    }

    func nextAvailableSerialNumber() -> UInt32 {
        let activeNumbers = Set(displays.map { $0.serialNum })
        let configNumbers = Set(displayConfigs.map { $0.serialNum })
        let usedNumbers = activeNumbers.union(configNumbers)

        var next: UInt32 = 1
        while usedNumbers.contains(next) {
            next += 1
        }
        return next
    }

    private func shouldUseCoordinatedRebuild(
        configId: UUID,
        config: VirtualDisplayConfig,
        snapshot: DisplayTopologySnapshot?
    ) -> Bool {
        guard runningConfigIds.contains(configId),
              runningConfigIds.count >= 2 else {
            return false
        }
        if let runtimeDisplayID = runtimeDisplayID(for: configId),
           runtimeDisplayID == CGMainDisplayID() {
            return true
        }
        guard let snapshot else {
            return false
        }
        let managedOnlineCount = snapshot.displays.filter(\.isManagedVirtualDisplay).count
        guard managedOnlineCount >= 2,
              let targetDisplayID = TopologyHealthEvaluator.managedDisplayID(
                for: config.serialNum,
                snapshot: snapshot
              ) else {
            return false
        }
        return snapshot.mainDisplayID == targetDisplayID
    }

    private func orderedRunningConfigIDs(prioritizing configId: UUID) -> [UUID] {
        var ordered = displayConfigs
            .map(\.id)
            .filter { runningConfigIds.contains($0) }
        if let index = ordered.firstIndex(of: configId) {
            ordered.remove(at: index)
            ordered.insert(configId, at: 0)
        } else if runningConfigIds.contains(configId) {
            ordered.insert(configId, at: 0)
        }
        return ordered
    }

    private func rebuildManagedDisplayFleet(
        prioritizing prioritizedConfigID: UUID,
        fallbackPreferredMainDisplayID: CGDirectDisplayID?,
        teardownStrategy: FleetRebuildTeardownStrategy = .perDisplaySettlement,
        includePrioritizedConfigIfNotRunning: Bool = false
    ) async throws {
        var orderedConfigIDs = orderedRunningConfigIDs(prioritizing: prioritizedConfigID)
        if includePrioritizedConfigIfNotRunning,
           !orderedConfigIDs.contains(prioritizedConfigID),
           displayConfigs.contains(where: { $0.id == prioritizedConfigID }) {
            orderedConfigIDs.insert(prioritizedConfigID, at: 0)
        }
        guard !orderedConfigIDs.isEmpty else {
            throw VirtualDisplayError.configNotFound
        }

        var terminationConfirmedByConfigID: [UUID: Bool] = [:]
        var rebuiltSerials: [UInt32] = []
        for runningConfigID in orderedConfigIDs {
            guard let runningConfig = displayConfigs.first(where: { $0.id == runningConfigID }) else { continue }
            rebuiltSerials.append(runningConfig.serialNum)

            let runtimeSerialNum = activeDisplaysByConfigId[runningConfigID]?.serialNum ?? runningConfig.serialNum
            let generationToWaitFor = runtimeGenerationByConfigId[runningConfigID]

            activeDisplaysByConfigId[runningConfigID] = nil
            runtimeDisplayIDHintsByConfigId[runningConfigID] = nil
            runningConfigIds.remove(runningConfigID)
            displays.removeAll { $0.serialNum == runtimeSerialNum }

            let terminationConfirmed: Bool
            switch teardownStrategy {
            case .perDisplaySettlement:
                terminationConfirmed = try await teardownCoordinator.settleRebuildTeardown(
                    configId: runningConfigID,
                    serialNum: runningConfig.serialNum,
                    generationToWaitFor: generationToWaitFor,
                    rebuildTerminationTimeout: Self.rebuildTerminationTimeout,
                    rebuildOfflineTimeout: Self.rebuildOfflineTimeout,
                    rebuildFinalOfflineConfirmationTimeout: Self.rebuildFinalOfflineConfirmationTimeout
                )
            case .fleetOfflineOnly:
                terminationConfirmed = false
                AppLog.virtualDisplay.debug(
                    "Fleet rebuild skipping per-display teardown settlement; relying on fleet offline confirmation (config: \(runningConfigID.uuidString, privacy: .public), serial: \(runningConfig.serialNum, privacy: .public), generation: \(String(describing: generationToWaitFor), privacy: .public))."
                )
            }
            terminationConfirmedByConfigID[runningConfigID] = terminationConfirmed
        }
        let fleetOfflineConfirmed = await teardownCoordinator.waitForManagedDisplaysOffline(
            serialNumbers: rebuiltSerials,
            timeout: Self.rebuildFinalOfflineConfirmationTimeout
        )
        if !fleetOfflineConfirmed {
            AppLog.virtualDisplay.error(
                "Coordinated rebuild aborted because at least one managed display remained online after fleet teardown (configs: \(orderedConfigIDs.map(\.uuidString).joined(separator: ","), privacy: .public))."
            )
            throw VirtualDisplayError.teardownTimedOut
        }
        let fleetCreationCooldown: TimeInterval
        switch teardownStrategy {
        case .perDisplaySettlement:
            fleetCreationCooldown = Self.rebuildFleetCreationCooldown
        case .fleetOfflineOnly:
            fleetCreationCooldown = Self.rebuildFleetCreationCooldownFastTeardown
        }
        if fleetCreationCooldown > 0 {
            let cooldown = await waitForAdaptiveManagedDisplayCooldown(
                serialNumbers: rebuiltSerials,
                maxCooldown: fleetCreationCooldown
            )
            AppLog.virtualDisplay.debug(
                "Fleet rebuild creation cooldown (strategy: \(teardownStrategy.logDescription, privacy: .public), maxCooldownSec: \(fleetCreationCooldown, privacy: .public), waitedMs: \(UInt64(cooldown.waitedSeconds * 1000), privacy: .public), earlyExit: \(cooldown.completedEarly, privacy: .public))."
            )
        }

        var recreatedPreferredMainDisplayID: CGDirectDisplayID?
        for runningConfigID in orderedConfigIDs {
            guard let runningConfig = displayConfigs.first(where: { $0.id == runningConfigID }) else { continue }
            let terminationConfirmed = terminationConfirmedByConfigID[runningConfigID] ?? true

            let recreatedDisplayID = try await recreateRuntimeDisplayForRebuild(
                config: runningConfig,
                terminationConfirmed: terminationConfirmed
            )
            if runningConfigID == prioritizedConfigID {
                recreatedPreferredMainDisplayID = recreatedDisplayID
            }
        }

        try await ensureHealthyTopologyAfterEnable(
            preferredMainDisplayID: recreatedPreferredMainDisplayID ?? fallbackPreferredMainDisplayID
        )
    }

    private func recreateRuntimeDisplayForRebuild(
        config: VirtualDisplayConfig,
        terminationConfirmed: Bool
    ) async throws -> CGDirectDisplayID? {
        if let rebuildRuntimeDisplayHook {
            try await rebuildRuntimeDisplayHook(config, terminationConfirmed)
            return runtimeDisplayID(for: config.id)
        }
        let rebuiltDisplay = try await createRuntimeDisplayWithRetries(
            from: config,
            terminationConfirmed: terminationConfirmed
        )
        return rebuiltDisplay.displayID
    }

    private enum FleetRebuildTeardownStrategy {
        case perDisplaySettlement
        case fleetOfflineOnly

        var logDescription: String {
            switch self {
            case .perDisplaySettlement:
                return "perDisplaySettlement"
            case .fleetOfflineOnly:
                return "fleetOfflineOnly"
            }
        }
    }

    func ensureHealthyTopologyAfterEnable(
        preferredMainDisplayID: CGDirectDisplayID? = nil,
        recoveryMode: TopologyRecoveryMode = .aggressive
    ) async throws {
        AppLog.virtualDisplay.debug(
            "Topology recovery start (mode: \(recoveryMode.logDescription, privacy: .public), preferredMain: \(String(describing: preferredMainDisplayID), privacy: .public))."
        )
        let initialRequiredStableSamples = recoveryMode == .fast ? 1 : 3
        let initialMinimumTimeout = recoveryMode == .fast ? 0.0 : 0.35
        guard let stableSnapshot = await waitForStableTopology(
            requiredStableSamples: initialRequiredStableSamples,
            minimumTimeout: initialMinimumTimeout
        ) else {
            AppLog.virtualDisplay.error(
                "Topology recovery failed to obtain initial stable snapshot (mode: \(recoveryMode.logDescription, privacy: .public))."
            )
            throw VirtualDisplayError.topologyUnstableAfterEnable
        }
        logTopologySnapshot("topologyRecovery:initialStable", snapshot: stableSnapshot)

        let desiredManagedSerials = Set(displayConfigs.filter(\.desiredEnabled).map(\.serialNum))
        let initialVisibleDesiredManagedCount = stableSnapshot.displays.filter {
            $0.isManagedVirtualDisplay && desiredManagedSerials.contains($0.serialNumber)
        }.count
        let repairedOnInitialPass = try await repairTopologyIfNeeded(
            snapshot: stableSnapshot,
            desiredManagedSerials: desiredManagedSerials,
            preferredMainDisplayID: preferredMainDisplayID,
            allowForceNormalization: recoveryMode == .aggressive
        )

        // macOS may apply an additional topology transition shortly after enable.
        // Run a delayed verification pass to catch late mirror collapse regressions.
        let initialSnapshotIncompleteForDesiredManagedSet =
            initialVisibleDesiredManagedCount < desiredManagedSerials.count
        let shouldRunDeferredVerification =
            recoveryMode == .aggressive ||
            repairedOnInitialPass ||
            initialSnapshotIncompleteForDesiredManagedSet
        guard shouldRunDeferredVerification, desiredManagedSerials.count >= 2 else {
            AppLog.virtualDisplay.debug(
                "Topology recovery deferred verification skipped (mode: \(recoveryMode.logDescription, privacy: .public), repairedInitial: \(repairedOnInitialPass, privacy: .public), initialVisibleDesiredManagedCount: \(initialVisibleDesiredManagedCount, privacy: .public), desiredCount: \(desiredManagedSerials.count, privacy: .public))."
            )
            return
        }
        let deferredDelay = max(
            Self.deferredTopologyRecheckMinimumDelay,
            topologyStabilityPollInterval * Self.deferredTopologyRecheckMultiplier
        )
        await sleepForRetry(seconds: deferredDelay)

        guard let deferredSnapshot = await waitForStableTopology() else {
            AppLog.virtualDisplay.warning(
                "Topology recovery deferred verification skipped due to unstable snapshot (mode: \(recoveryMode.logDescription, privacy: .public))."
            )
            return
        }
        logTopologySnapshot("topologyRecovery:deferredStable", snapshot: deferredSnapshot)
        _ = try await repairTopologyIfNeeded(
            snapshot: deferredSnapshot,
            desiredManagedSerials: desiredManagedSerials,
            preferredMainDisplayID: preferredMainDisplayID,
            allowForceNormalization: false
        )
    }

    private func repairTopologyIfNeeded(
        snapshot: DisplayTopologySnapshot,
        desiredManagedSerials: Set<UInt32>,
        preferredMainDisplayID: CGDirectDisplayID?,
        allowForceNormalization: Bool
    ) async throws -> Bool {
        let evaluation = TopologyHealthEvaluator.evaluate(
            snapshot: snapshot,
            desiredManagedSerials: desiredManagedSerials
        )
        AppLog.virtualDisplay.debug(
            "Topology evaluation (allowForceNormalization: \(allowForceNormalization, privacy: .public), issue: \(self.describe(issue: evaluation.issue), privacy: .public), needsRepair: \(evaluation.needsRepair, privacy: .public), forceNormalization: \(evaluation.forceNormalization, privacy: .public), managedIDs: \(evaluation.managedDisplayIDs.map(String.init).joined(separator: ","), privacy: .public))."
        )
        logTopologySnapshot("topologyRecovery:evaluationSnapshot", snapshot: snapshot)
        let continuityAnchorDisplayID = preferredMainDisplayID.flatMap { preferredMain in
            TopologyHealthEvaluator.shouldEnforceMainContinuity(
                preferredMainDisplayID: preferredMain,
                snapshot: snapshot,
                managedDisplayIDs: evaluation.managedDisplayIDs
            ) ? preferredMain : nil
        }
        let shouldRepairForForceNormalization = allowForceNormalization &&
            evaluation.forceNormalization &&
            evaluation.issue != nil
        let shouldRepair = evaluation.needsRepair || shouldRepairForForceNormalization
        let shouldRepairForContinuity = continuityAnchorDisplayID != nil
        if allowForceNormalization,
           evaluation.forceNormalization,
           evaluation.issue == nil,
           continuityAnchorDisplayID == nil {
            AppLog.virtualDisplay.debug(
                "Topology force normalization skipped because topology is already stable and no continuity repair is needed."
            )
        }
        guard shouldRepair || shouldRepairForContinuity else {
            AppLog.virtualDisplay.debug("Topology evaluation decided no repair.")
            return false
        }
        if !shouldRepair, let continuityAnchorDisplayID {
            AppLog.virtualDisplay.notice(
                "Topology continuity repair requested (anchor: \(continuityAnchorDisplayID, privacy: .public), preferredMain: \(String(describing: preferredMainDisplayID), privacy: .public))."
            )
            let continuityRepaired = topologyRepairer.repair(
                snapshot: snapshot,
                managedDisplayIDs: evaluation.managedDisplayIDs,
                anchorDisplayID: continuityAnchorDisplayID
            )
            guard continuityRepaired else {
                throw VirtualDisplayError.topologyRepairFailed
            }
            guard let stabilizedAfterContinuity = await waitForStableTopology() else {
                throw VirtualDisplayError.topologyUnstableAfterEnable
            }
            logTopologySnapshot("topologyRecovery:postContinuityStable", snapshot: stabilizedAfterContinuity)
            return true
        }
        let repairAnchorDisplayID = TopologyHealthEvaluator.selectRepairAnchorDisplayID(
            snapshot: snapshot,
            managedDisplayIDs: evaluation.managedDisplayIDs,
            preferredMainDisplayID: preferredMainDisplayID
        )
        AppLog.virtualDisplay.notice(
            "Topology repair requested (anchor: \(repairAnchorDisplayID, privacy: .public), preferredMain: \(String(describing: preferredMainDisplayID), privacy: .public), issue: \(self.describe(issue: evaluation.issue), privacy: .public), forceNormalization: \(evaluation.forceNormalization, privacy: .public))."
        )

        let repaired = topologyRepairer.repair(
            snapshot: snapshot,
            managedDisplayIDs: evaluation.managedDisplayIDs,
            anchorDisplayID: repairAnchorDisplayID
        )
        guard repaired else {
            throw VirtualDisplayError.topologyRepairFailed
        }

        guard let stabilizedAfterRepair = await waitForStableTopology() else {
            throw VirtualDisplayError.topologyUnstableAfterEnable
        }
        logTopologySnapshot("topologyRecovery:postRepairStable", snapshot: stabilizedAfterRepair)

        let postRepairEvaluation = TopologyHealthEvaluator.evaluate(
            snapshot: stabilizedAfterRepair,
            desiredManagedSerials: desiredManagedSerials
        )
        guard !postRepairEvaluation.needsRepair else {
            AppLog.virtualDisplay.error(
                "Topology repair did not clear primary issue (issue: \(self.describe(issue: postRepairEvaluation.issue), privacy: .public))."
            )
            throw VirtualDisplayError.topologyRepairFailed
        }

        if allowForceNormalization && evaluation.forceNormalization {
            let normalizationAnchorDisplayID = TopologyHealthEvaluator.selectRepairAnchorDisplayID(
                snapshot: stabilizedAfterRepair,
                managedDisplayIDs: postRepairEvaluation.managedDisplayIDs,
                preferredMainDisplayID: preferredMainDisplayID
            )
            let normalized = topologyRepairer.repair(
                snapshot: stabilizedAfterRepair,
                managedDisplayIDs: postRepairEvaluation.managedDisplayIDs,
                anchorDisplayID: normalizationAnchorDisplayID
            )
            guard normalized else {
                throw VirtualDisplayError.topologyRepairFailed
            }
            guard let stabilizedAfterNormalization = await waitForStableTopology() else {
                throw VirtualDisplayError.topologyUnstableAfterEnable
            }
            logTopologySnapshot("topologyRecovery:postNormalizationStable", snapshot: stabilizedAfterNormalization)
            let postNormalizationEvaluation = TopologyHealthEvaluator.evaluate(
                snapshot: stabilizedAfterNormalization,
                desiredManagedSerials: desiredManagedSerials
            )
            guard !postNormalizationEvaluation.needsRepair else {
                AppLog.virtualDisplay.error(
                    "Topology normalization did not clear issue (issue: \(self.describe(issue: postNormalizationEvaluation.issue), privacy: .public))."
                )
                throw VirtualDisplayError.topologyRepairFailed
            }
            if let continuityMainDisplayID = preferredMainDisplayID,
               TopologyHealthEvaluator.shouldEnforceMainContinuity(
                   preferredMainDisplayID: continuityMainDisplayID,
                   snapshot: stabilizedAfterNormalization,
                   managedDisplayIDs: postNormalizationEvaluation.managedDisplayIDs
               ) {
                let continuityRepaired = topologyRepairer.repair(
                    snapshot: stabilizedAfterNormalization,
                    managedDisplayIDs: postNormalizationEvaluation.managedDisplayIDs,
                    anchorDisplayID: continuityMainDisplayID
                )
                guard continuityRepaired else {
                    throw VirtualDisplayError.topologyRepairFailed
                }
                guard let stabilizedAfterContinuity = await waitForStableTopology() else {
                    throw VirtualDisplayError.topologyUnstableAfterEnable
                }
                logTopologySnapshot("topologyRecovery:postContinuityStable", snapshot: stabilizedAfterContinuity)
            }
            return true
        }
        return true
    }

    private func waitForStableTopology(
        requiredStableSamples: Int = 3,
        minimumTimeout: TimeInterval = 0.35
    ) async -> DisplayTopologySnapshot? {
        let effectiveTimeout = max(topologyStabilityTimeout, minimumTimeout)
        let deadline = Date().addingTimeInterval(effectiveTimeout)
        var previousSnapshot: DisplayTopologySnapshot?
        var stableSampleCount = 0
        let targetStableSamples = max(requiredStableSamples, 1)
        let basePollInterval = max(topologyStabilityPollInterval, 0.001)
        let fastProbeInterval = min(
            basePollInterval,
            max(Self.adaptiveCooldownPollIntervalFloor, basePollInterval / Self.topologyStabilityAdaptiveProbeDivisor)
        )
        var currentPollInterval = fastProbeInterval

        while Date() < deadline {
            guard let currentSnapshot = currentTopologySnapshot() else {
                stableSampleCount = 0
                currentPollInterval = min(basePollInterval, max(fastProbeInterval, currentPollInterval))
                await sleepForRetry(seconds: currentPollInterval)
                continue
            }

            if previousSnapshot == currentSnapshot {
                stableSampleCount += 1
                currentPollInterval = min(
                    basePollInterval,
                    max(
                        fastProbeInterval,
                        currentPollInterval * Self.topologyStabilityAdaptiveBackoffMultiplier
                    )
                )
            } else {
                previousSnapshot = currentSnapshot
                stableSampleCount = 1
                currentPollInterval = fastProbeInterval
            }

            if stableSampleCount >= targetStableSamples {
                return currentSnapshot
            }
            await sleepForRetry(seconds: currentPollInterval)
        }

        return nil
    }

    func rollbackEnableRuntimeState(configId: UUID, serialNum: UInt32) {
        // Keep runtime generation until termination callback/offline check settles.
        clearRuntimeTracking(configId: configId, serialNum: serialNum, keepGeneration: true)
    }

    private func currentTopologySnapshot() -> DisplayTopologySnapshot? {
        topologyInspector.snapshot(
            trackedManagedSerials: trackedManagedSerials(),
            managedVendorID: Self.managedVendorID,
            managedProductID: Self.managedProductID
        )
    }

    private func trackedManagedSerials() -> Set<UInt32> {
        Set(displayConfigs.map(\.serialNum))
            .union(Set(activeDisplaysByConfigId.values.map(\.serialNum)))
    }

    private func persistConfigs() {
        persistenceService.saveConfigs(displayConfigs)
    }

    @discardableResult
    private func createRuntimeDisplay(from config: VirtualDisplayConfig, maxPixels: (width: UInt32, height: UInt32)? = nil) throws -> CGVirtualDisplay {
        if let existing = activeDisplaysByConfigId[config.id] {
            AppLog.virtualDisplay.debug(
                "Create runtime display reused existing active instance (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), displayID: \(existing.displayID, privacy: .public), generation: \(String(describing: self.runtimeGenerationByConfigId[config.id]), privacy: .public))."
            )
            runtimeDisplayIDHintsByConfigId[config.id] = existing.displayID
            return existing
        }

        if displays.contains(where: { $0.serialNum == config.serialNum }) {
            throw VirtualDisplayError.duplicateSerialNumber(config.serialNum)
        }

        let modes = config.resolutionModes
        guard !modes.isEmpty else {
            throw VirtualDisplayError.invalidConfiguration(String(localized: "At least one resolution mode is required."))
        }

        let generation = allocateRuntimeGeneration()
        AppLog.virtualDisplay.debug(
            "Create runtime display begin (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), pendingGenerationBeforeCreate: \(String(describing: self.runtimeGenerationByConfigId[config.id]), privacy: .public))."
        )
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleVirtualDisplayTermination(
                    configId: config.id,
                    serialNum: config.serialNum,
                    generation: generation
                )
            }
        }
        desc.name = config.name
        let max = maxPixels ?? config.maxPixelDimensions
        desc.maxPixelsWide = max.width
        desc.maxPixelsHigh = max.height
        desc.sizeInMillimeters = config.physicalSize
        desc.productID = Self.managedProductID
        desc.vendorID = Self.managedVendorID
        desc.serialNum = config.serialNum

        let display = CGVirtualDisplay(descriptor: desc)
        AppLog.virtualDisplay.debug(
            "Create runtime display descriptor instantiated (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), provisionalDisplayID: \(display.displayID, privacy: .public))."
        )

        let settings = CGVirtualDisplaySettings()
        let anyHiDPI = modes.contains { $0.enableHiDPI }
        settings.hiDPI = anyHiDPI ? 1 : 0

        var displayModes: [CGVirtualDisplayMode] = []
        for mode in modes {
            if mode.enableHiDPI {
                displayModes.append(mode.hiDPIVersion().toVirtualDisplayMode())
            }
            displayModes.append(mode.toVirtualDisplayMode())
        }

        settings.modes = displayModes
        let applied = display.apply(settings)
        guard applied else {
            AppLog.virtualDisplay.error(
                "Create virtual display apply settings failed (name: \(config.name, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), provisionalDisplayID: \(display.displayID, privacy: .public))."
            )
            throw VirtualDisplayError.creationFailed
        }

        activeDisplaysByConfigId[config.id] = display
        runtimeDisplayIDHintsByConfigId[config.id] = display.displayID
        runtimeGenerationByConfigId[config.id] = generation
        runningConfigIds.insert(config.id)
        displays.removeAll { $0.serialNum == config.serialNum }
        displays.append(display)
        AppLog.virtualDisplay.notice(
            "Create runtime display committed (config: \(config.id.uuidString, privacy: .public), serial: \(config.serialNum, privacy: .public), generation: \(generation, privacy: .public), displayID: \(display.displayID, privacy: .public))."
        )
        return display
    }

    private func handleVirtualDisplayTermination(configId: UUID, serialNum: UInt32, generation: UInt64) {
        let currentGeneration = runtimeGenerationByConfigId[configId]
        let currentDisplayID = activeDisplaysByConfigId[configId]?.displayID
        AppLog.virtualDisplay.debug(
            "Virtual display termination callback received (config: \(configId.uuidString, privacy: .public), serial: \(serialNum, privacy: .public), callbackGeneration: \(generation, privacy: .public), currentGeneration: \(String(describing: currentGeneration), privacy: .public), currentDisplayID: \(String(describing: currentDisplayID), privacy: .public))."
        )
        guard currentGeneration == generation else {
            AppLog.virtualDisplay.debug(
                "Ignore stale virtual display termination (config: \(configId.uuidString, privacy: .public), serial: \(serialNum, privacy: .public), callbackGeneration: \(generation, privacy: .public), currentGeneration: \(String(describing: currentGeneration), privacy: .public))."
            )
            return
        }
        AppLog.virtualDisplay.notice(
            "Virtual display terminated (config: \(configId.uuidString, privacy: .public), serial: \(serialNum, privacy: .public), generation: \(generation, privacy: .public), displayID: \(String(describing: currentDisplayID), privacy: .public))."
        )
        activeDisplaysByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        runtimeGenerationByConfigId[configId] = nil
        runningConfigIds.remove(configId)
        displays.removeAll { $0.serialNum == serialNum }
        teardownCoordinator.observeTermination(configId: configId, generation: generation)
    }

    private func allocateRuntimeGeneration() -> UInt64 {
        defer { nextRuntimeGeneration &+= 1 }
        return nextRuntimeGeneration
    }

    func waitForManagedDisplayOffline(
        serialNum: UInt32,
        timeout: TimeInterval = 2.5
    ) async -> Bool {
        await teardownCoordinator.waitForManagedDisplayOffline(
            serialNum: serialNum,
            timeout: timeout
        )
    }

    @discardableResult
    private func createRuntimeDisplayWithRetries(
        from config: VirtualDisplayConfig,
        terminationConfirmed: Bool
    ) async throws -> CGVirtualDisplay {
        let maxAttempts = terminationConfirmed ? 3 : 10
        for attempt in 1...maxAttempts {
            do {
                return try createRuntimeDisplay(from: config)
            } catch {
                let shouldRetry: Bool
                if let virtualDisplayError = error as? VirtualDisplayError,
                   case .creationFailed = virtualDisplayError {
                    shouldRetry = true
                } else {
                    shouldRetry = false
                }

                if shouldRetry && attempt < maxAttempts {
                    let delay: TimeInterval
                    if terminationConfirmed {
                        delay = 0.15
                    } else {
                        delay = min(0.2 * Double(attempt), 1.0)
                    }
                    await sleepForRetry(seconds: delay)
                    continue
                }
                if shouldRetry && !terminationConfirmed {
                    throw VirtualDisplayError.teardownTimedOut
                }
                throw error
            }
        }

        throw VirtualDisplayError.creationFailed
    }

    private func isManagedDisplayOnline(serialNum: UInt32) -> Bool {
        teardownCoordinator.isManagedDisplayOnline(serialNum: serialNum)
    }

    private func sleepForRetry(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            // Ignore cancellation and let retry loop exit on next check.
        }
    }

    private func waitForAdaptiveManagedDisplayCooldown(
        serialNumbers: [UInt32],
        maxCooldown: TimeInterval
    ) async -> AdaptiveCooldownResult {
        let targetSerials = Set(serialNumbers)
        guard !targetSerials.isEmpty, maxCooldown > 0 else {
            return AdaptiveCooldownResult(waitedSeconds: 0, completedEarly: true)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = Date().addingTimeInterval(maxCooldown)
        let pollInterval = min(
            Self.adaptiveCooldownPollIntervalCeiling,
            max(Self.adaptiveCooldownPollIntervalFloor, topologyStabilityPollInterval / 4)
        )
        var stableAbsenceSamples = 0

        while Date() < deadline {
            if let snapshot = currentTopologySnapshot() {
                let managedTargetsVisible = snapshot.displays.contains { display in
                    display.isManagedVirtualDisplay && targetSerials.contains(display.serialNumber)
                }
                if managedTargetsVisible {
                    stableAbsenceSamples = 0
                } else {
                    stableAbsenceSamples += 1
                    if stableAbsenceSamples >= Self.adaptiveCooldownStableSamplesRequired {
                        let waitedMs = elapsedMilliseconds(since: start)
                        return AdaptiveCooldownResult(
                            waitedSeconds: Double(waitedMs) / 1000,
                            completedEarly: true
                        )
                    }
                }
            } else {
                stableAbsenceSamples = 0
            }
            await sleepForRetry(seconds: pollInterval)
        }

        let waitedMs = elapsedMilliseconds(since: start)
        return AdaptiveCooldownResult(
            waitedSeconds: Double(waitedMs) / 1000,
            completedEarly: false
        )
    }

    private func elapsedMilliseconds(since startNanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startNanoseconds ? (now - startNanoseconds) / 1_000_000 : 0
    }

    private func runtimeDisplayIDForSerial(_ serialNum: UInt32) -> CGDirectDisplayID? {
        if let runtime = activeDisplaysByConfigId.values.first(where: { $0.serialNum == serialNum }) {
            return runtime.displayID
        }
        if let configID = displayConfigs.first(where: { $0.serialNum == serialNum })?.id {
            return runtimeDisplayID(for: configID)
        }
        return nil
    }

    private func markAggressiveRecoveryPendingForSerial(_ serialNum: UInt32) {
        for config in displayConfigs where config.serialNum == serialNum {
            aggressiveRecoveryPendingEnableConfigIDs.insert(config.id)
        }
    }

    private func clearAggressiveRecoveryPendingForSerial(_ serialNum: UInt32) {
        let ids = displayConfigs
            .filter { $0.serialNum == serialNum }
            .map(\.id)
        aggressiveRecoveryPendingEnableConfigIDs.subtract(ids)
    }

    private func clearRuntimeTrackingForSerialNum(
        _ serialNum: UInt32,
        keepGeneration: Bool
    ) {
        let matchingConfigIDs = activeDisplaysByConfigId.compactMap { configId, activeDisplay in
            activeDisplay.serialNum == serialNum ? configId : nil
        }
        for configID in matchingConfigIDs {
            clearRuntimeTracking(configId: configID, serialNum: serialNum, keepGeneration: keepGeneration)
        }
        displays.removeAll { $0.serialNum == serialNum }
    }

    private func clearRuntimeTracking(
        configId: UUID,
        serialNum: UInt32,
        keepGeneration: Bool
    ) {
        teardownCoordinator.cancelTerminationWaiter(configId: configId)
        activeDisplaysByConfigId[configId] = nil
        runtimeDisplayIDHintsByConfigId[configId] = nil
        if !keepGeneration {
            runtimeGenerationByConfigId[configId] = nil
            aggressiveRecoveryPendingEnableConfigIDs.remove(configId)
        }
        runningConfigIds.remove(configId)
        displays.removeAll { $0.serialNum == serialNum }
    }

    private func logTopologySnapshot(
        _ label: String,
        snapshot: DisplayTopologySnapshot?
    ) {
        guard let snapshot else {
            AppLog.virtualDisplay.debug("\(label, privacy: .public): snapshot=nil")
            return
        }
        AppLog.virtualDisplay.debug(
            "\(label, privacy: .public): \(self.describe(snapshot: snapshot), privacy: .public)"
        )
    }

    private func describe(snapshot: DisplayTopologySnapshot) -> String {
        let displaysDescription = snapshot.displays.map { display in
            let mainMarker = display.id == snapshot.mainDisplayID ? "*" : ""
            let mirrorMaster = display.mirrorMasterDisplayID.map(String.init) ?? "-"
            let bounds = display.bounds
            let roundedBounds = "\(Int(bounds.origin.x.rounded())):\(Int(bounds.origin.y.rounded())):\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded()))"
            return [
                "\(mainMarker)\(display.id)",
                "s\(display.serialNumber)",
                display.isManagedVirtualDisplay ? "M" : "P",
                display.isActive ? "A" : "I",
                display.isInMirrorSet ? "mir" : "nomir",
                "master:\(mirrorMaster)",
                "b:\(roundedBounds)"
            ].joined(separator: "/")
        }
        return "main=\(snapshot.mainDisplayID) displays=[\(displaysDescription.joined(separator: ", "))]"
    }

    private func describe(issue: TopologyHealthEvaluation.Issue?) -> String {
        guard let issue else { return "none" }
        switch issue {
        case .managedDisplaysCollapsedIntoSingleMirrorSet:
            return "mirrorCollapse"
        case .managedDisplaysOverlappingInExtendedSpace:
            return "overlap"
        case .mainDisplayOutsideManagedSetWithoutPhysicalFallback:
            return "mainOutsideManagedNoPhysical"
        }
    }

    isolated deinit {
        teardownCoordinator.cancelAllTerminationWaiters()
        teardownCoordinator.cancelAllOfflineWaiters()
        displayReconfigurationMonitor.stop()
    }

    func replaceDisplayConfigs(_ configs: [VirtualDisplayConfig]) {
        displayConfigs = configs
    }

    func seedRuntimeBookkeeping(
        configId: UUID,
        generation: UInt64 = 1,
        runtimeDisplayID: CGDirectDisplayID? = nil
    ) {
        runtimeGenerationByConfigId[configId] = generation
        runtimeDisplayIDHintsByConfigId[configId] = runtimeDisplayID
        runningConfigIds.insert(configId)
    }

    func runtimeBookkeeping(
        configId: UUID
    ) -> (isRunning: Bool, generation: UInt64?) {
        (
            runningConfigIds.contains(configId),
            runtimeGenerationByConfigId[configId]
        )
    }
}

private extension VirtualDisplayService.TopologyRecoveryMode {
    var logDescription: String {
        switch self {
        case .fast:
            return "fast"
        case .aggressive:
            return "aggressive"
        }
    }
}
