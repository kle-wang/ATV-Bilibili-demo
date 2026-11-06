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

    /// 沉浸式模式下提前缓冲用的播放器：静音、暂停，持有本资源的 AVPlayerItem。
    /// AVPlayerItem 不能在两个 AVPlayer 之间转移，所以直接把整个播放器交给正式播放使用。
    @MainActor private var prewarmedPlayer: AVPlayer?

    init(asset: AVURLAsset, delegate: BilibiliVideoResourceLoaderDelegate) {
        self.asset = asset
        self.delegate = delegate
    }

    /// 创建（如尚未创建）暂停的静音播放器，等待缓冲到 seconds 秒或超时。
    /// 取消只会停止等待，已建立的播放器保留，后台会继续缓冲到 preferredForwardBufferDuration。
    @MainActor
    func prebuffer(seconds: Double, timeout: TimeInterval, label: String) async {
        let player: AVPlayer
        if let existing = prewarmedPlayer {
            player = existing
        } else {
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = seconds
            player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = true
            prewarmedPlayer = player
        }
        guard let item = player.currentItem else { return }
        let start = ProcessInfo.processInfo.systemUptime
        var buffered = 0.0
        while !Task.isCancelled {
            buffered = Self.bufferedSeconds(of: item)
            if buffered >= seconds || item.status == .failed { break }
            if ProcessInfo.processInfo.systemUptime - start >= timeout { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        Logger.info("[prebuffer] \(label) 缓冲 \(String(format: "%.1f", buffered))s 用时 \(String(format: "%.1f", elapsed))s status \(item.status.rawValue)\(Task.isCancelled ? " (已取消)" : "")")
    }

    /// 取走预缓冲播放器（只能取一次）。
    @MainActor
    func takePrewarmedPlayer() -> AVPlayer? {
        defer { prewarmedPlayer = nil }
        return prewarmedPlayer
    }

    /// 丢弃预缓冲播放器，停止其后台下载。
    @MainActor
    func discardPrewarmedPlayer() {
        prewarmedPlayer?.pause()
        prewarmedPlayer?.replaceCurrentItem(with: nil)
        prewarmedPlayer = nil
    }

    private static func bufferedSeconds(of item: AVPlayerItem) -> Double {
        guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return 0 }
        let end = range.start.seconds + range.duration.seconds
        let current = item.currentTime().seconds
        guard end.isFinite, current.isFinite else { return 0 }
        return max(0, end - current)
    }
}

enum PlayerMediaFactory {
    static func prepare(aid: Int,
                        urlInfo: VideoPlayURLInfo,
                        playerInfo: PlayerInfo?,
                        maxQuality: Int? = nil,
                        streamIndex: Int? = nil,
                        preferredHost: String? = nil,
                        transportMode: MediaTransportMode = .direct) async throws -> PreparedPlayerMedia
    {
        let playURL = URL(string: BilibiliVideoResourceLoaderDelegate.URLs.play)!
        let headers: [String: String] = [
            "User-Agent": Keys.userAgent,
            "Referer": Keys.referer(for: aid),
        ]
        let asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let delegate = BilibiliVideoResourceLoaderDelegate()
        delegate.setBilibili(info: urlInfo,
                             subtitles: playerInfo?.subtitle?.subtitles ?? [],
                             aid: aid,
                             maxQuality: maxQuality,
                             streamIndex: streamIndex,
                             preferredHost: preferredHost,
                             transportMode: transportMode)
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue(label: "loader.\(aid).\(UUID().uuidString)"))
        try Task.checkCancellation()
        let playable = try await asset.load(.isPlayable)
        try Task.checkCancellation()
        guard playable else {
            throw "加载资源失败"
        }
        try await withTaskCancellationHandler {
            await delegate.prewarmPrimaryVideoIndex()
            try Task.checkCancellation()
        } onCancel: {
            delegate.cancelPendingIndexLoads()
        }
        return PreparedPlayerMedia(asset: asset, delegate: delegate)
    }
}

actor PlayerMediaWarmupManager {
    private struct InFlightEntry {
        let token: UUID
        let task: Task<PreparedPlayerMedia, Error>
    }

    /// 沉浸式模式：上一条 + 后四条（含预缓冲播放器）+ 余量
    private let maxPreparedEntries = 6
    private let playContextCache: PlayContextCache
    private var prepared = [String: PreparedPlayerMedia]()
    private var inFlight = [String: InFlightEntry]()
    private var accessOrder = [String]()
    private var cancellationGeneration = 0

    init(playContextCache: PlayContextCache) {
        self.playContextCache = playContextCache
    }

    func preload(playInfo: PlayInfo) async {
        _ = try? await preparedMedia(for: playInfo)
    }

    /// 准备资源并用暂停的静音播放器提前缓冲开头 seconds 秒（逐条调用，避免多条同时抢带宽）。
    func prebuffer(playInfo: PlayInfo, seconds: Double, timeout: TimeInterval) async {
        guard let media = try? await preparedMedia(for: playInfo), !Task.isCancelled else { return }
        await media.prebuffer(seconds: seconds, timeout: timeout, label: "av\(playInfo.aid)")
    }

    /// 取出预热好的资源交给播放器，并从缓存移除。
    /// 同一个 AVURLAsset 被第二个 AVPlayerItem 复用时（例如卡顿重试），资源加载器不再收到请求，
    /// 播放器会一直停在 unknown 状态，因此每份预热资源只能被播放器消费一次。
    func takePreparedMedia(for playInfo: PlayInfo) async throws -> PreparedPlayerMedia {
        let (key, media) = try await preparedEntry(for: playInfo)
        if prepared[key] === media {
            prepared[key] = nil
            accessOrder.removeAll { $0 == key }
        }
        return media
    }

    func preparedMedia(for playInfo: PlayInfo) async throws -> PreparedPlayerMedia {
        try await preparedEntry(for: playInfo).1
    }

    private func preparedEntry(for playInfo: PlayInfo) async throws -> (String, PreparedPlayerMedia) {
        let generation = cancellationGeneration
        let resolvedPlayInfo = try await PlayInfoResolver.resolve(playInfo)
        try Task.checkCancellation()
        guard cancellationGeneration == generation else { throw CancellationError() }
        // 传输模式纳入缓存身份：直连与代理资源不得复用。创建任务时固定快照，
        // 开关只影响新建会话，已准备的旧模式资产保持原生命周期。
        let transportSnapshot: MediaTransportMode = Settings.multiCDNEnabled ? .accelerated : .direct
        let key = resolvedPlayInfo.sequenceKey + "#" + transportCacheKey(for: transportSnapshot)
        if let cached = prepared[key] {
            touch(key)
            return (key, cached)
        }
        if let entry = inFlight[key] {
            let media = try await resolve(entry, for: key)
            return (key, media)
        }

        let token = UUID()
        let task = Task<PreparedPlayerMedia, Error> {
            try Task.checkCancellation()
            let snapshot = try await playContextCache.context(for: resolvedPlayInfo, mode: .regular)
            try Task.checkCancellation()
            return try await PlayerMediaFactory.prepare(
                aid: resolvedPlayInfo.aid,
                urlInfo: snapshot.videoPlayURLInfo,
                playerInfo: snapshot.playerInfo,
                transportMode: transportSnapshot
            )
        }

        let entry = InFlightEntry(token: token, task: task)
        inFlight[key] = entry
        let media = try await resolve(entry, for: key)
        return (key, media)
    }

    private func resolve(_ entry: InFlightEntry, for key: String) async throws -> PreparedPlayerMedia {
        do {
            let media = try await entry.task.value
            if let cached = prepared[key] {
                touch(key)
                return cached
            }
            guard inFlight[key]?.token == entry.token else {
                throw CancellationError()
            }
            inFlight[key] = nil
            prepared[key] = media
            touch(key)
            trimToCapacity()
            return media
        } catch {
            if inFlight[key]?.token == entry.token {
                inFlight[key] = nil
            }
            throw error
        }
    }

    func cancelAll() {
        cancellationGeneration += 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        discard(Array(prepared.values))
        prepared.removeAll()
        accessOrder.removeAll()
    }

    private func discard(_ medias: [PreparedPlayerMedia]) {
        guard !medias.isEmpty else { return }
        Task { @MainActor in
            medias.forEach { $0.discardPrewarmedPlayer() }
        }
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func transportCacheKey(for mode: MediaTransportMode) -> String {
        switch mode {
        case .direct: return "direct"
        case .proxy: return "proxy"
        case .accelerated: return "accel"
        }
    }

    private func trimToCapacity() {
        while prepared.count > maxPreparedEntries, let key = accessOrder.first {
            accessOrder.removeFirst()
            if let evicted = prepared.removeValue(forKey: key) {
                discard([evicted])
            }
        }
    }
}
