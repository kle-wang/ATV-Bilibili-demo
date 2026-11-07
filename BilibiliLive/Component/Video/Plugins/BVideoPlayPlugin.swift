//
//  BVideoPlayPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/24.
//

import AVKit
import UIKit

@MainActor
class BVideoPlayPlugin: NSObject, @preconcurrency CommonPlayerPlugin {
    var onLoadFailure: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?

    private struct LoadOptions {
        var position: Double?
        var resume: Bool?
        var refresh = false
        var preferredHost: String?
        var transport: MediaTransportMode?
        var startLower = false
    }

    private struct RouteRetry: Error {
        let host: String
    }

    private weak var playerVC: AVPlayerViewController?
    private weak var committedPlayer: AVPlayer?
    private var playerDelegate: BilibiliVideoResourceLoaderDelegate?
    private let playInfo: PlayInfo
    private let playData: PlayerDetailData
    private let reportWatchHistory: Bool
    private let minimizeStalling: Bool
    private let isMuted: Bool
    private let mediaWarmupManager: PlayerMediaWarmupManager?
    private let refreshSource: (UUID) async throws -> PlaybackSource
    private var source: PlaybackSource
    private var quality: Int?
    private var streamIndex: Int?

    private var loadTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var loadGeneration = 0
    private var retriedRoute = false
    private var refreshedSource = false
    private var terminalFailure = false
    private var wantsPlayback = true
    private var suspendedIntent: Bool?
    private var lastStartTime: Double = 0
    private var loadStartedAt: TimeInterval = 0
    private var reportedFirstFrame = false

    private var statusObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private var networkLogTimer: Timer?
    private var lastStalls = 0
    private var lastDroppedFrames = 0
    private var cdnProbeReport = ""
    private var cdnProbeTask: Task<Void, Never>?

    init(playInfo: PlayInfo,
         detailData: PlayerDetailData,
         reportWatchHistory: Bool = true,
         minimizeStalling: Bool = true,
         isMuted: Bool = false,
         mediaWarmupManager: PlayerMediaWarmupManager? = nil,
         refreshSource: @escaping (UUID) async throws -> PlaybackSource)
    {
        self.playInfo = playInfo
        playData = detailData
        self.reportWatchHistory = reportWatchHistory
        self.minimizeStalling = minimizeStalling
        self.isMuted = isMuted
        self.mediaWarmupManager = mediaWarmupManager
        self.refreshSource = refreshSource
        source = detailData.source
    }

    deinit {
        loadTask?.cancel()
        watchdog?.cancel()
        cdnProbeTask?.cancel()
        networkLogTimer?.invalidate()
    }

    var networkDebugInfo: String {
        var lines = [String]()
        if let mode = playerDelegate?.effectiveTransportMode, mode != .direct {
            lines.append("transport: \(mode == .accelerated ? "accel" : "proxy")")
        }
        if let host = playerDelegate?.currentSegmentHost {
            lines.append("segment host: \(host)")
        }
        if let acceleration = playerDelegate?.accelerationDebugInfo, !acceleration.isEmpty {
            lines.append(acceleration)
        }
        if !cdnProbeReport.isEmpty {
            lines.append(cdnProbeReport)
        }
        return lines.joined(separator: "\n")
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
        // The VOD plugin owns the first play and any seeks needed before resuming.
        (playerVC.parent as? CommonPlayerViewController)?.autoPlayWhenReady = false
        playerVC.player = nil
        startLoad()
    }

    func playerDidDismiss(playerVC: AVPlayerViewController) {
        guard reportWatchHistory,
              let time = playerVC.player?.currentTime().seconds, time.isFinite
        else { return }
        WebRequest.reportWatchHistory(aid: playData.aid, cid: playData.cid, currentTime: Int(time), epid: playData.epid, seasonId: playData.seasonId, subType: playData.subType)
    }

    func playerWillCleanUp(playerVC: AVPlayerViewController) {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        watchdog?.cancel()
        watchdog = nil
        cdnProbeTask?.cancel()
        statusObservation = nil
        displayObservation = nil
        networkLogTimer?.invalidate()
        networkLogTimer = nil
        playerDelegate?.cancelPendingIndexLoads()
        playerDelegate = nil
        committedPlayer = nil
        self.playerVC = nil
        (playerVC.parent as? CommonPlayerViewController)?.autoPlayWhenReady = true
    }

    func playerDidCleanUp(player: AVPlayer) {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func playerDidFail(player: AVPlayer) {
        // Let the current load finish handling its own error.
        guard loadTask == nil else { return }
        recover(player)
    }

    func playerDidStall(player: AVPlayer) {
        guard wantsPlayback, !terminalFailure else { return }
        armWatchdog(for: player, seconds: 5)
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        let action = UIAction(title: cdnProbeTask != nil ? "CDN 测速中…" : "CDN 测速", image: UIImage(systemName: "speedometer")) { [weak self] _ in
            self?.probeCDN()
        }
        if let index = current.firstIndex(where: { ($0 as? UIMenu)?.identifier == UIMenu.Identifier(rawValue: "setting") }),
           let setting = current[index] as? UIMenu
        {
            current[index] = setting.replacingChildren(setting.children + [action])
        }
        return []
    }

    private func probeCDN() {
        guard cdnProbeTask == nil, let delegate = playerDelegate, !delegate.cdnCandidates.isEmpty else { return }
        let candidates = delegate.cdnCandidates.filter { source.isUsable($0, allowNearExpiry: true) }
        let referer = Keys.referer(for: playData.aid)
        cdnProbeReport = "CDN 测速中…"
        cdnProbeTask = Task { [weak self] in
            let report = await CDNDiagnostics.run(urls: candidates, currentHost: delegate.currentSegmentHost, referer: referer)
            self?.cdnProbeReport = report
            self?.cdnProbeTask = nil
        }
    }

    func suspendRecovery() {
        suspendedIntent = playbackIntent
        watchdog?.cancel()
        watchdog = nil
    }

    func resumeAfterSuspension() {
        guard let intent = suspendedIntent else { return }
        suspendedIntent = nil
        wantsPlayback = intent
        guard let player = committedPlayer, loadTask == nil, !terminalFailure else { return }
        if player.currentItem?.status == .failed {
            recover(player)
        } else if !reloadIfRoutesExpired(position: nil, resume: intent), intent {
            player.play()
        }
    }

    /// For an expired route, seek on the replacement asset.
    func renewBeforeSeek(to position: Double) -> Bool {
        reloadIfRoutesExpired(position: position)
    }

    func retry() {
        retriedRoute = false
        refreshedSource = false
        terminalFailure = false
        startLoad(LoadOptions(refresh: true))
    }

    func switchQuality(to qualityId: Int, streamIndex: Int?) async {
        guard playerVC?.player != nil else { return }
        quality = qualityId
        self.streamIndex = streamIndex
        retriedRoute = false
        refreshedSource = false
        terminalFailure = false
        startLoad()
    }

    private var playbackIntent: Bool {
        if let suspendedIntent { return suspendedIntent }
        guard let player = committedPlayer, player.currentItem?.status == .readyToPlay else { return wantsPlayback }
        return player.timeControlStatus != .paused
    }

    private func reloadIfRoutesExpired(position: Double?, resume: Bool? = nil) -> Bool {
        guard let playerDelegate, !playerDelegate.canKeepCurrentRoutes() else { return false }
        if loadTask != nil, position == nil { return true }
        guard !terminalFailure else { return false }
        startLoad(LoadOptions(position: position, resume: resume))
        return true
    }

    private func startLoad(_ options: LoadOptions = LoadOptions()) {
        guard playerVC != nil else { return }
        loadTask?.cancel()
        watchdog?.cancel()
        watchdog = nil
        loadGeneration += 1
        let generation = loadGeneration
        loadStartedAt = ProcessInfo.processInfo.systemUptime
        let oldPlayer = committedPlayer
        let mode = options.transport ?? (Settings.multiCDNEnabled ? .accelerated : .direct)
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if loadGeneration == generation { loadTask = nil }
            }
            do {
                try await load(options, replacing: oldPlayer, mode: mode, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard loadGeneration == generation, !Task.isCancelled else { return }
                logFailure(error)
                // A failed quality or URL replacement can leave the current player usable.
                if let oldPlayer, self.playerVC?.player === oldPlayer,
                   oldPlayer.currentItem?.status == .readyToPlay,
                   oldPlayer.timeControlStatus == .playing
                { return }
                finishFailure(error)
            }
        }
    }

    private func load(_ options: LoadOptions, replacing oldPlayer: AVPlayer?, mode: MediaTransportMode, generation: Int) async throws {
        var attempt = options
        var mode = mode
        if attempt.refresh { try await replaceSource(generation: generation) }
        while true {
            do {
                try await install(attempt, replacing: oldPlayer, mode: mode, generation: generation)
                return
            } catch {
                try checkLoad(generation)
                logFailure(error)
                switch error as? PlaybackSourceError {
                case .expired, .cdnRejected:
                    guard !refreshedSource else { throw error }
                    try await replaceSource(generation: generation)
                    attempt.preferredHost = nil
                case .noPlayableStreams:
                    throw error
                case nil:
                    guard !retriedRoute else { throw error }
                    retriedRoute = true
                    attempt.preferredHost = (error as? RouteRetry)?.host ?? playerDelegate?.backupHost()
                    attempt.startLower = quality == nil
                    mode = .direct
                }
            }
        }
    }

    private func replaceSource(generation: Int) async throws {
        try checkLoad(generation)
        refreshedSource = true
        let fresh = try await refreshSource(source.id)
        try checkLoad(generation)
        source = fresh
    }

    private func install(_ options: LoadOptions, replacing oldPlayer: AVPlayer?, mode: MediaTransportMode, generation: Int) async throws {
        try checkLoad(generation)
        let lastPosition = oldPlayer?.currentTime().seconds ?? .nan
        var position = options.position ?? (lastPosition.isFinite ? lastPosition : Double(playData.playerStartPos ?? 0))
        var warmedPlayer: AVPlayer?
        var media: PreparedPlayerMedia
        if oldPlayer == nil, quality == nil, !options.refresh,
           let warmup = await mediaWarmupManager?.takePreparedMedia(for: playInfo.contextKey, sourceID: source.id, transport: mode),
           let player = warmup.takePrewarmedPlayer(at: position)
        {
            warmedPlayer = player
            media = warmup
            Logger.info("[prebuffer] 接手下一条，起播点已缓冲 \(String(format: "%.1f", player.currentItem?.forwardBufferedSeconds(at: position) ?? 0))s")
        } else {
            media = try await PlayerMediaFactory.prepare(aid: playData.aid,
                                                         source: source,
                                                         playerInfo: playData.playerInfo,
                                                         maxQuality: quality,
                                                         streamIndex: resolvedStreamIndex(),
                                                         preferredHost: options.preferredHost,
                                                         transportMode: mode,
                                                         startLower: options.startLower)
        }
        let player = warmedPlayer ?? AVPlayer(playerItem: AVPlayerItem(asset: media.asset))
        guard let item = player.currentItem else { throw PlaybackSourceError.noPlayableStreams }
        var keepPlayer = false
        defer {
            if !keepPlayer {
                player.pause()
                player.replaceCurrentItem(with: nil)
                media.delegate.cancelPendingIndexLoads()
            }
        }
        try checkLoad(generation)
        item.preferredForwardBufferDuration = 3
        player.automaticallyWaitsToMinimizeStalling = minimizeStalling
        player.isMuted = isMuted

        // Keep the old image available while preparing a replacement.
        if oldPlayer == nil {
            attach(player, media: media, setDisplayCriteria: true)
        }
        do {
            try await waitUntilReady(item, generation: generation)
        } catch {
            try checkLoad(generation)
            if let error = sourceFailure(item: item, delegate: media.delegate) {
                if case .cdnRejected = error, media.delegate.rejectedStatus == nil, !retriedRoute,
                   let backup = media.delegate.backupHost(failingURI: item.errorLog()?.events.last?.uri)
                {
                    // Preserve the failed track's alternate when the new player is still off screen.
                    throw RouteRetry(host: backup)
                }
                throw error
            }
            throw error
        }
        if let oldPlayer, let oldItem = oldPlayer.currentItem {
            try await copyMediaSelections(from: oldItem, to: item, generation: generation)
            let latest = oldPlayer.currentTime().seconds
            if options.position == nil, latest.isFinite, latest >= position { position = latest }
            player.defaultRate = oldPlayer.defaultRate
        }
        if position > 0 {
            try await seek(player, to: position)
        }
        try checkLoad(generation)
        let resume = suspendedIntent ?? options.resume ?? playbackIntent
        if oldPlayer != nil {
            attach(player, media: media, setDisplayCriteria: false)
        }
        keepPlayer = true
        committedPlayer = player
        lastStartTime = position
        wantsPlayback = resume
        terminalFailure = false
        if resume, suspendedIntent == nil {
            player.play()
            armWatchdog(for: player, seconds: 12)
        } else {
            player.pause()
        }
    }

    private func attach(_ player: AVPlayer, media: PreparedPlayerMedia, setDisplayCriteria: Bool) {
        guard let playerVC else { return }
        let previousDelegate = playerDelegate
        playerDelegate = media.delegate
        if setDisplayCriteria {
            playerVC.appliesPreferredDisplayCriteriaAutomatically = Settings.contentMatch && (!Settings.contentMatchOnlyInHDR || media.delegate.isHDR)
        }
        statusObservation = nil
        displayObservation = nil
        reportedFirstFrame = false
        lastStalls = 0
        lastDroppedFrames = 0
        playerVC.player = player
        previousDelegate?.cancelPendingIndexLoads()
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in self?.playbackStateChanged(observed) }
        }
        displayObservation = playerVC.observe(\.isReadyForDisplay, options: [.new]) { [weak self, weak player] _, _ in
            Task { @MainActor [weak self] in
                guard let player else { return }
                self?.recordFirstFrame(for: player)
            }
        }
        if networkLogTimer == nil {
            networkLogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.logNetworkStatus() }
            }
        }
    }

    private func waitUntilReady(_ item: AVPlayerItem, generation: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while item.status == .unknown, ProcessInfo.processInfo.systemUptime < deadline {
            try checkLoad(generation)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try checkLoad(generation)
        guard item.status == .readyToPlay else { throw item.error ?? URLError(.timedOut) }
    }

    private func seek(_ player: AVPlayer, to position: Double) async throws {
        guard let item = player.currentItem else { throw CancellationError() }
        let time = CMTime(seconds: position, preferredTimescale: 600)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                } onCancel: {
                    item.cancelPendingSeeks()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard try await group.next() == true else { throw URLError(.cancelled) }
        }
    }

    private func copyMediaSelections(from oldItem: AVPlayerItem, to item: AVPlayerItem, generation: Int) async throws {
        for characteristic in [AVMediaCharacteristic.audible, .legible] {
            guard let oldGroup = try? await oldItem.asset.loadMediaSelectionGroup(for: characteristic),
                  let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic)
            else { continue }
            try checkLoad(generation)
            if let selected = oldItem.currentMediaSelection.selectedMediaOption(in: oldGroup) {
                if let match = group.options.first(where: { $0.displayName == selected.displayName && $0.extendedLanguageTag == selected.extendedLanguageTag }) {
                    item.select(match, in: group)
                }
            } else if group.allowsEmptySelection {
                item.select(nil, in: group)
            }
        }
    }

    private func resolvedStreamIndex() -> Int? {
        guard let streamIndex, playData.videoPlayURLInfo.dash.video.indices.contains(streamIndex) else { return nil }
        let old = playData.videoPlayURLInfo.dash.video[streamIndex]
        let variants = source.info.dash.video
        return variants.firstIndex { $0.id == old.id && $0.codecs == old.codecs && $0.bandwidth == old.bandwidth } ??
            variants.firstIndex { $0.id == old.id && $0.codecs == old.codecs }
    }

    private func checkLoad(_ generation: Int) throws {
        guard generation == loadGeneration, playerVC != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func playbackStateChanged(_ player: AVPlayer) {
        guard committedPlayer === player, suspendedIntent == nil else { return }
        switch player.timeControlStatus {
        case .playing:
            wantsPlayback = true
            watchdog?.cancel()
            watchdog = nil
            player.currentItem?.preferredForwardBufferDuration = 15
            recordFirstFrame(for: player)
        case .waitingToPlayAtSpecifiedRate:
            guard player.reasonForWaitingToPlay != .noItemToPlay else { return }
            wantsPlayback = true
            guard loadTask == nil else { return }
            if !reloadIfRoutesExpired(position: nil) {
                armWatchdog(for: player, seconds: reportedFirstFrame ? 5 : 12)
            }
        case .paused:
            guard player.currentItem?.status == .readyToPlay else { return }
            wantsPlayback = false
            watchdog?.cancel()
            watchdog = nil
        @unknown default:
            break
        }
    }

    private func recordFirstFrame(for player: AVPlayer) {
        guard !reportedFirstFrame, committedPlayer === player, playerVC?.isReadyForDisplay == true,
              player.timeControlStatus == .playing
        else { return }
        reportedFirstFrame = true
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - loadStartedAt) * 1000)
        Logger.info("[startup] av\(playData.aid) 首帧 \(elapsed)ms")
        onFirstFrame?()
    }

    private func armWatchdog(for player: AVPlayer, seconds: UInt64) {
        guard watchdog == nil, loadTask == nil || !reportedFirstFrame, suspendedIntent == nil else { return }
        watchdog = Task { [weak self, weak player] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, let player, !Task.isCancelled else { return }
            watchdog = nil
            guard playerVC?.player === player, player.currentItem?.status == .failed ||
                (player.timeControlStatus == .waitingToPlayAtSpecifiedRate && wantsPlayback)
            else { return }
            recover(player)
        }
    }

    private func recover(_ player: AVPlayer) {
        guard playerVC?.player === player, loadTask == nil, !terminalFailure, suspendedIntent == nil,
              let item = player.currentItem
        else { return }
        let failure = sourceFailure(item: item, delegate: playerDelegate)
        let alternative = playerDelegate?.backupHost(failingURI: item.errorLog()?.events.last?.uri)
        if case .expired = failure, !refreshedSource {
            startLoad()
            return
        }
        if case .cdnRejected = failure, alternative == nil || retriedRoute || playerDelegate?.rejectedStatus != nil, !refreshedSource {
            startLoad(LoadOptions(refresh: true))
            return
        }
        guard !retriedRoute else {
            finishFailure(failure ?? item.error ?? URLError(.timedOut))
            return
        }
        retriedRoute = true
        Logger.info("[stall] av\(playData.aid) 原位恢复，备选 \(alternative ?? "-")")
        startLoad(LoadOptions(preferredHost: alternative, transport: .direct, startLower: quality == nil))
    }

    private func sourceFailure(item: AVPlayerItem, delegate: BilibiliVideoResourceLoaderDelegate?) -> PlaybackSourceError? {
        if let delegate, !delegate.canKeepCurrentRoutes(allowNearExpiry: true) { return .expired }
        if let status = delegate?.rejectedStatus { return .cdnRejected(status: status) }
        if let status = item.errorLog()?.events.last?.errorStatusCode, PlaybackSourceError.rejectionStatus(status) {
            return .cdnRejected(status: status)
        }
        return nil
    }

    private func logFailure(_ error: Error) {
        let cause = (error as? PlaybackSourceError)?.errorDescription ?? CDNDiagnostics.errorLabel(error)
        let failure = error as NSError
        Logger.warn("[player] av\(playData.aid) \(cause) (\(failure.domain) \(failure.code))")
    }

    private func finishFailure(_ error: Error) {
        guard !terminalFailure else { return }
        terminalFailure = true
        watchdog?.cancel()
        watchdog = nil
        let message = (error as? PlaybackSourceError)?.errorDescription ?? "视频加载失败，请检查网络后重试"
        onLoadFailure?(message)
    }

    private func logNetworkStatus() {
        guard let player = playerVC?.player, let item = player.currentItem else { return }
        recordFirstFrame(for: player)
        if loadTask == nil, player.timeControlStatus == .playing, item.currentTime().seconds - lastStartTime >= 3 {
            retriedRoute = false
            refreshedSource = false
        }
        guard let event = item.accessLog()?.events.last else { return }
        let host = playerDelegate?.currentSegmentHost ?? "-"
        let observed = event.observedBitrate / 1_000_000
        let indicated = event.indicatedBitrate / 1_000_000
        let buffered = item.forwardBufferedSeconds()
        let stalls = event.numberOfStalls
        let dropped = event.numberOfDroppedVideoFrames
        let waiting = player.reasonForWaitingToPlay?.rawValue ?? "-"
        Logger.info("playback host \(host) observed \(String(format: "%.1f", observed))Mbps indicated \(String(format: "%.1f", indicated))Mbps stalls \(stalls)(+\(stalls - lastStalls)) dropped \(dropped)(+\(dropped - lastDroppedFrames)) tcs \(player.timeControlStatus.rawValue) wait \(waiting) buffered \(String(format: "%.1f", buffered))s")
        lastStalls = stalls
        lastDroppedFrames = dropped
        if playerDelegate?.effectiveTransportMode == .direct {
            PlaybackThroughputEstimator.record(observedBps: event.observedBitrate)
        }
    }
}
