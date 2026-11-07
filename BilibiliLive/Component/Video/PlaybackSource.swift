import Foundation

/// A single playurl response. Assets prepared from it share its validity and identity.
struct PlaybackSource {
    static let unknownURLLifetime: TimeInterval = 30 * 60
    private static let refreshLeadTime: TimeInterval = 60

    let id = UUID()
    let info: VideoPlayURLInfo
    let fetchedAt: Date

    init(info: VideoPlayURLInfo, fetchedAt: Date = Date()) {
        self.info = info
        self.fetchedAt = fetchedAt
    }

    static func deadline(for url: String) -> Date? {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased(),
              host == "bilivideo.com" || host.hasSuffix(".bilivideo.com") ||
              host == "bilivideo.cn" || host.hasSuffix(".bilivideo.cn")
        else { return nil }

        let deadlines = components.queryItems?.compactMap { item -> Int64? in
            guard item.name == "deadline", let value = item.value,
                  let seconds = MediaRangeParsing.parseNonNegativeInt64(value), seconds > 0
            else { return nil }
            return seconds
        }
        return deadlines?.min().map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    func isUsable(_ url: String, at date: Date = Date(), allowNearExpiry: Bool = false) -> Bool {
        if let deadline = Self.deadline(for: url) {
            return deadline.timeIntervalSince(date) > (allowNearExpiry ? 0 : Self.refreshLeadTime)
        }
        return date.timeIntervalSince(fetchedAt) < Self.unknownURLLifetime
    }

    func urls(for media: VideoPlayURLInfo.DashInfo.DashMediaInfo, at date: Date = Date()) -> [String] {
        media.playableURLs.filter { isUsable($0, at: date) }
    }

    func hasUsableMedia(at date: Date = Date()) -> Bool {
        let dash = info.dash
        guard dash.video.contains(where: { !urls(for: $0, at: date).isEmpty }) else { return false }
        guard let audio = dash.audio, !audio.isEmpty else { return true }
        return audio.contains { !urls(for: $0, at: date).isEmpty }
    }
}

enum PlaybackSourceError: LocalizedError {
    case expired
    case noPlayableStreams
    case cdnRejected(status: Int)

    static func rejectionStatus(_ status: Int) -> Bool {
        status == 403 || status == 404 || status == 410
    }

    var errorDescription: String? {
        switch self {
        case .expired: return "播放地址已过期"
        case .noPlayableStreams: return "当前画质没有可用的音视频流"
        case let .cdnRejected(status): return "CDN 拒绝播放请求（HTTP \(status)）"
        }
    }
}
