//
//  PlayerMediaWarmup.swift
//  BilibiliLive
//
//  Created by OpenAI on 2026/4/4.
//

import AVFoundation
import Foundation

final class PreparedPlayerMedia: @unchecked Sendable {
    let asset: AVURLAsset
    let delegate: BilibiliVideoResourceLoaderDelegate
    let sourceID: UUID

    /// 沉浸式模式下提前缓冲用的播放器：静音、暂停，持有本资源的 AVPlayerItem。
    /// AVPlayerItem 不能在两个 AVPlayer 之间转移，所以直接把整个播放器交给正式播放使用。
    @MainActor private var prewarmedPlayer: AVPlayer?

    init(asset: AVURLAsset, delegate: BilibiliVideoResourceLoaderDelegate, sourceID: UUID) {
        self.asset = asset
        self.delegate = delegate
        self.sourceID = sourceID
    }

    @MainActor
    func prebuffer(seconds: Double, timeout: TimeInterval, shouldContinue: @MainActor () -> Bool) async -> Bool {
        guard shouldContinue(), !Task.isCancelled else { return false }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = seconds
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        prewarmedPlayer = player
        let start = ProcessInfo.processInfo.systemUptime
        var startedPreroll = false
        defer { player.cancelPendingPrerolls() }
        while !Task.isCancelled, shouldContinue(), item.status != .failed {
            let buffered = item.forwardBufferedSeconds(at: 0)
            if item.status == .readyToPlay, buffered >= max(0.5, seconds - 0.1) {
                Logger.info("[prebuffer] 下一条已缓冲 \(String(format: "%.1f", buffered))s")
                return true
            }
            if !startedPreroll, player.status == .readyToPlay {
                startedPreroll = true
                player.preroll(atRate: 1, completionHandler: nil)
            }
            if ProcessInfo.processInfo.systemUptime - start >= timeout { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        discardPrewarmedPlayer()
        return false
    }

    /// 取走预缓冲播放器（只能取一次）。
    @MainActor
    func takePrewarmedPlayer(at position: Double) -> AVPlayer? {
        guard let player = prewarmedPlayer, let item = player.currentItem,
              item.status == .readyToPlay, item.forwardBufferedSeconds(at: position) > 0.5
        else {
            discardPrewarmedPlayer()
            return nil
        }
        defer { prewarmedPlayer = nil }
        return player
    }

    /// 丢弃预缓冲播放器，停止其后台下载。
    @MainActor
    func discardPrewarmedPlayer() {
        prewarmedPlayer?.pause()
        prewarmedPlayer?.replaceCurrentItem(with: nil)
        prewarmedPlayer = nil
        delegate.cancelPendingIndexLoads()
    }
}

extension AVPlayerItem {
    func forwardBufferedSeconds(at position: Double? = nil) -> Double {
        let time = position ?? currentTime().seconds
        guard time.isFinite else { return 0 }
        return loadedTimeRanges.map(\.timeRangeValue).reduce(0) { buffered, range in
            let start = range.start.seconds
            let end = start + range.duration.seconds
            guard start <= time, end.isFinite, end > time else { return buffered }
            return max(buffered, end - time)
        }
    }
}

enum PlayerMediaFactory {
    static func prepare(aid: Int,
                        source: PlaybackSource,
                        playerInfo: PlayerInfo?,
                        maxQuality: Int? = nil,
                        streamIndex: Int? = nil,
                        preferredHost: String? = nil,
                        transportMode: MediaTransportMode = .direct,
                        startLower: Bool = false) async throws -> PreparedPlayerMedia
    {
        let playURL = URL(string: BilibiliVideoResourceLoaderDelegate.URLs.play)!
        let headers: [String: String] = [
            "User-Agent": Keys.userAgent,
            "Referer": Keys.referer(for: aid),
        ]
        let asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let delegate = BilibiliVideoResourceLoaderDelegate()
        try delegate.setBilibili(source: source,
                                 subtitles: playerInfo?.subtitle?.subtitles ?? [],
                                 aid: aid,
                                 maxQuality: maxQuality,
                                 streamIndex: streamIndex,
                                 preferredHost: preferredHost,
                                 transportMode: transportMode,
                                 startLower: startLower)
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue(label: "loader.\(aid).\(UUID().uuidString)"))
        try Task.checkCancellation()
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let playable = try await asset.load(.isPlayable)
            try Task.checkCancellation()
            guard playable else { throw "加载资源失败" }
        } catch {
            delegate.cancelPendingIndexLoads()
            try Task.checkCancellation()
            if let status = delegate.rejectedStatus {
                throw PlaybackSourceError.cdnRejected(status: status)
            }
            throw error
        }
        Logger.info("[startup] av\(aid) 播放清单 \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))ms")
        return PreparedPlayerMedia(asset: asset, delegate: delegate, sourceID: source.id)
    }
}

actor PlayerMediaWarmupManager {
    private let playContextCache: PlayContextCache
    private var prepared: (key: PlayContextKey, media: PreparedPlayerMedia)?
    private var generation = 0

    init(playContextCache: PlayContextCache) {
        self.playContextCache = playContextCache
    }

    func prebuffer(playInfo: PlayInfo, shouldContinue: @escaping @MainActor @Sendable () -> Bool) async {
        generation += 1
        let request = generation
        guard !playInfo.isBangumi,
              let resolved = try? await PlayInfoResolver.resolve(playInfo), !Task.isCancelled,
              let snapshot = try? await playContextCache.context(for: resolved, mode: .regular),
              !Task.isCancelled, request == generation, await shouldContinue()
        else { return }
        if let prepared, prepared.key == resolved.contextKey, prepared.media.sourceID == snapshot.source.id,
           prepared.media.delegate.canKeepCurrentRoutes()
        { return }

        let transport: MediaTransportMode = Settings.multiCDNEnabled ? .accelerated : .direct
        guard let media = try? await PlayerMediaFactory.prepare(aid: resolved.aid,
                                                                source: snapshot.source,
                                                                playerInfo: snapshot.playerInfo,
                                                                transportMode: transport)
        else { return }
        let seconds = min(3, Double(snapshot.source.info.dash.duration))
        guard !Task.isCancelled, generation == request, seconds > 0,
              await media.prebuffer(seconds: seconds, timeout: 6, shouldContinue: shouldContinue),
              !Task.isCancelled, generation == request, media.delegate.canKeepCurrentRoutes()
        else {
            await media.discardPrewarmedPlayer()
            return
        }

        let previous = prepared?.media
        prepared = (resolved.contextKey, media)
        await previous?.discardPrewarmedPlayer()
    }

    /// A warmed AVURLAsset is handed off once. Foreground loads never wait for an in-flight warmup.
    func takePreparedMedia(for key: PlayContextKey, sourceID: UUID, transport: MediaTransportMode) async -> PreparedPlayerMedia? {
        guard let prepared, prepared.key == key else { return nil }
        self.prepared = nil
        let media = prepared.media
        guard media.sourceID == sourceID, media.delegate.transportMode == transport, media.delegate.canKeepCurrentRoutes() else {
            await media.discardPrewarmedPlayer()
            return nil
        }
        return media
    }

    func cancelAll() async {
        generation += 1
        let previous = prepared?.media
        prepared = nil
        await previous?.discardPrewarmedPlayer()
    }
}
