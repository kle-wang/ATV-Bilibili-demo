//
//  CDNDiagnostics.swift
//  BilibiliLive
//

import Foundation

enum CDNDiagnostics {
    struct RangeSample {
        let data: Data
        let setupTime: TimeInterval
        let transferTime: TimeInterval
    }

    private struct ProbeResult {
        let host: String
        let isPCDN: Bool
        let mbps: Double?
        let setupTime: TimeInterval
        let error: String?
    }

    private static let probeBytes = 2 * 1024 * 1024
    private static let probeSession = session(requestTimeout: 5, resourceTimeout: 8)

    static func session(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: config)
    }

    static func fetchRange(url: String,
                           range: MediaByteRange,
                           referer: String,
                           session: URLSession,
                           allowShortEOF: Bool = false) async throws -> RangeSample
    {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        request.setValue(Keys.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let start = ProcessInfo.processInfo.systemUptime
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let receivedHeaders = ProcessInfo.processInfo.systemUptime
        let actual = try MediaRangeParsing.validatePartialResponse(response, requested: range, allowShortEOF: allowShortEOF).range
        var data = Data()
        data.reserveCapacity(Int(actual.length))
        for try await byte in bytes {
            guard data.count < actual.length else { throw MediaRangeError.mismatch }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard data.count == actual.length else { throw MediaRangeError.truncated }
        return RangeSample(data: data,
                           setupTime: receivedHeaders - start,
                           transferTime: ProcessInfo.processInfo.systemUptime - receivedHeaders)
    }

    static func errorLabel(_ error: Error) -> String {
        if let error = error as? MediaRangeError {
            switch error {
            case let .upstream(status): return "HTTP \(status)"
            case .mismatch, .unsatisfiable: return "Range 不匹配"
            case .truncated: return "响应长度不足"
            default: return "Range 请求失败"
            }
        }
        if let error = error as? URLError {
            return error.code == .timedOut ? "请求超时" : "网络错误 \(error.code.rawValue)"
        }
        return "媒体请求失败"
    }

    /// Only manual diagnostics download full probe samples. Playback starts with the API's candidate order.
    static func run(urls: [String], currentHost: String?, referer: String) async -> String {
        guard !urls.isEmpty else { return "无候选 CDN" }
        let range = try! MediaByteRange(start: 0, end: Int64(probeBytes - 1))
        var results = [ProbeResult]()
        for url in urls {
            if Task.isCancelled { break }
            let host = URLComponents(string: url)?.host ?? "unknown"
            let isPCDN = BVideoUrlUtils.isPCDN(url)
            do {
                let sample = try await fetchRange(url: url, range: range, referer: referer, session: probeSession, allowShortEOF: true)
                let mbps = Double(sample.data.count) * 8 / max(sample.transferTime, 0.001) / 1_000_000
                results.append(ProbeResult(host: host, isPCDN: isPCDN, mbps: mbps, setupTime: sample.setupTime, error: nil))
            } catch {
                results.append(ProbeResult(host: host, isPCDN: isPCDN, mbps: nil, setupTime: 0, error: errorLabel(error)))
            }
        }
        let ranked = results.sorted { ($0.mbps ?? -1) > ($1.mbps ?? -1) }
        var lines = ["CDN 实测（最多 \(probeBytes / 1024) KB/节点）"]
        for (index, result) in ranked.enumerated() {
            let speed = result.mbps.map { String(format: "%.1f Mbps", $0) } ?? "失败"
            let setup = String(format: "%.0fms", result.setupTime * 1000)
            var line = "\(index + 1). \(speed)  setup \(setup)  \(result.host)"
            if result.isPCDN { line += "  PCDN" }
            if result.host == currentHost { line += "  <- 正在使用" }
            if let error = result.error { line += "  (\(error))" }
            lines.append(line)
        }
        let report = lines.joined(separator: "\n")
        Logger.info("\n\(report)")
        return report
    }
}
