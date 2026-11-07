//
//  PlayContextCache.swift
//  BilibiliLive
//
//  Created by OpenAI on 2026/4/4.
//

import Foundation

struct PlayContextKey: Hashable {
    let aid: Int
    let cid: Int
    let epid: Int
    let seasonId: Int
}

struct PlayContextSnapshot {
    let cid: Int
    let playerInfo: PlayerInfo?
    let source: PlaybackSource
    let detail: VideoDetail?
}

enum PlayContextMode: String, Hashable {
    case preview
    case regular

    var includeDetail: Bool {
        switch self {
        case .preview:
            return false
        case .regular:
            return true
        }
    }

    var requestOptions: PlayURLRequestOptions {
        switch self {
        case .preview:
            return .featuredPreview
        case .regular:
            return .regular
        }
    }
}

private struct PlayContextEntryKey: Hashable {
    let contextKey: PlayContextKey
    let mode: PlayContextMode
}

actor PlayContextCache {
    private struct InFlightEntry {
        let token: UUID
        let task: Task<PlayContextSnapshot, Error>
    }

    private let maxEntries = 12
    private let recentEntriesToKeep = 4
    private var entries = [PlayContextEntryKey: PlayContextSnapshot]()
    private var inFlightTasks = [PlayContextEntryKey: InFlightEntry]()
    private var accessOrder = [PlayContextEntryKey]()

    func preload(playInfo: PlayInfo, mode: PlayContextMode) async {
        _ = try? await context(for: playInfo, mode: mode)
    }

    func context(for playInfo: PlayInfo, mode: PlayContextMode, replacing sourceID: UUID? = nil) async throws -> PlayContextSnapshot {
        let resolvedPlayInfo = try await PlayInfoResolver.resolve(playInfo)
        try Task.checkCancellation()
        let entryKey = PlayContextEntryKey(contextKey: resolvedPlayInfo.contextKey, mode: mode)

        if let entry = inFlightTasks[entryKey] {
            return try await resolve(entry, for: entryKey)
        }
        let previous = entries[entryKey]
        if let cached = previous, cached.source.id != sourceID, cached.source.hasUsableMedia() {
            touch(entryKey)
            return cached
        }

        let token = UUID()
        let task = Task<PlayContextSnapshot, Error> {
            let aid = resolvedPlayInfo.aid
            let cid = resolvedPlayInfo.cid ?? 0
            async let playerInfoReq = previous == nil ? (try? WebRequest.requestPlayerInfo(aid: aid, cid: cid)) : previous?.playerInfo
            async let detailReq = previous == nil && mode.includeDetail ? (try? WebRequest.requestDetailVideo(aid: aid)) : previous?.detail

            let started = ProcessInfo.processInfo.systemUptime
            let info = try await WebRequest.requestPlayUrl(aid: aid, cid: cid, options: mode.requestOptions)
            let source = PlaybackSource(info: info)
            try Task.checkCancellation()
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            Logger.info("[playurl] av\(aid) \(mode.rawValue) 取流 \(elapsed)ms\(previous == nil ? "" : "（刷新）")")

            return PlayContextSnapshot(cid: cid,
                                       playerInfo: await playerInfoReq,
                                       source: source,
                                       detail: await detailReq)
        }

        let entry = InFlightEntry(token: token, task: task)
        inFlightTasks[entryKey] = entry
        return try await resolve(entry, for: entryKey)
    }

    func trim(keeping playInfos: [PlayInfo]) {
        let baseKeysToKeep = Set(playInfos.compactMap { info -> PlayContextKey? in
            guard let cid = info.cid, cid > 0 else { return nil }
            return PlayContextKey(aid: info.aid,
                                  cid: cid,
                                  epid: info.epid ?? 0,
                                  seasonId: info.seasonId ?? 0)
        })
        let recentKeys = Array(accessOrder.reversed().prefix(recentEntriesToKeep))
        let entryKeysToKeep = Set((Array(entries.keys) + Array(inFlightTasks.keys)).filter {
            baseKeysToKeep.contains($0.contextKey)
        } + recentKeys)
        for key in inFlightTasks.keys.filter({ !entryKeysToKeep.contains($0) }) {
            inFlightTasks[key]?.task.cancel()
            inFlightTasks[key] = nil
        }
        entries = entries.filter { entryKeysToKeep.contains($0.key) }
        accessOrder.removeAll { !entryKeysToKeep.contains($0) }
    }

    private func resolve(_ entry: InFlightEntry, for key: PlayContextEntryKey) async throws -> PlayContextSnapshot {
        do {
            let snapshot = try await entry.task.value
            if inFlightTasks[key]?.token == entry.token {
                inFlightTasks[key] = nil
                entries[key] = snapshot
                touch(key)
                trimToMaxEntryCount()
            } else if entries[key]?.source.id != snapshot.source.id {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return snapshot
        } catch {
            if inFlightTasks[key]?.token == entry.token {
                inFlightTasks[key] = nil
            }
            throw error
        }
    }

    private func touch(_ key: PlayContextEntryKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimToMaxEntryCount() {
        guard entries.count > maxEntries else { return }
        var removableKeys = accessOrder
        while entries.count > maxEntries, let key = removableKeys.first {
            removableKeys.removeFirst()
            accessOrder.removeAll { $0 == key }
            entries[key] = nil
        }
    }

    /// Discard cached and pending responses before a manual retry.
    func invalidate(playInfo: PlayInfo) {
        let keys = Set(entries.keys).union(inFlightTasks.keys).filter {
            $0.contextKey.aid == playInfo.aid && (playInfo.cid ?? 0 == 0 || $0.contextKey.cid == playInfo.cid)
        }
        for key in keys {
            inFlightTasks.removeValue(forKey: key)?.task.cancel()
            entries[key] = nil
            accessOrder.removeAll { $0 == key }
        }
    }
}
