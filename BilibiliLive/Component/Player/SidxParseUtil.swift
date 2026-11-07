//
//  SidxParseUtil.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/11/13.
//

import Foundation

enum SidxParseUtil {
    struct Sidx {
        let timescale: Int
        let firstOffset: Int
        let earliestPresentationTime: Int
        let segments: [SegmentInfo]

        struct SegmentInfo {
            let type: Int
            let size: Int
            let duration: Int
            let sap: Int
            let sap_type: Int
            let sap_delta: Int
        }

        func maxSegmentDuration() -> Int? {
            if let duration = segments.map({ Double($0.duration) / Double(timescale) }).max() {
                return Int(duration + 1)
            }
            return nil
        }
    }

    static func processIndexData(data: Data) -> Sidx? {
        let end = UInt64(data.endIndex)
        var offset = UInt64(data.startIndex)
        while end - offset >= 8 {
            let boxStart = offset
            var size = UInt64(data.getUint32(offset: &offset))
            let type = data.getUint32(offset: &offset)
            if size == 1 {
                guard end - offset >= 8 else { return nil }
                size = data.getValue(type: UInt64.self, offset: &offset).bigEndian
            } else if size == 0 {
                size = end - boxStart
            }
            guard size >= offset - boxStart, size <= end - boxStart else { return nil }
            let boxEnd = boxStart + size
            if type == 0x7369_6478 { // "sidx"
                return processSIDX(data: Data(data[Int(offset)..<Int(boxEnd)]))
            }
            offset = boxEnd
        }
        return nil
    }

    private static func processSIDX(data: Data) -> Sidx? {
        guard data.count >= 24 else { return nil }
        var offset: UInt64 = 0
        let version = data.getUint8(offset: &offset)
        guard version == 0 || (version == 1 && data.count >= 32) else { return nil }
        _ = data.getUint8(offset: &offset) // none
        _ = data.getUint8(offset: &offset) // none
        _ = data.getUint8(offset: &offset) // none
        _ = data.getUint32(offset: &offset) // refID
        let timescale = data.getUint32(offset: &offset)
        guard timescale > 0 else { return nil }

        // version 0: 32-bit, version 1: 64-bit
        let earliest_presentation_time: UInt64
        let first_offset: UInt64
        if version == 0 {
            earliest_presentation_time = UInt64(data.getUint32(offset: &offset))
            first_offset = UInt64(data.getUint32(offset: &offset))
        } else {
            earliest_presentation_time = data.getValue(type: UInt64.self, offset: &offset).bigEndian
            first_offset = data.getValue(type: UInt64.self, offset: &offset).bigEndian
        }

        _ = data.getValue(type: UInt16.self, offset: &offset).bigEndian // reversed
        let reference_count = data.getValue(type: UInt16.self, offset: &offset).bigEndian
        guard Int(reference_count) <= (data.count - Int(offset)) / 12,
              let firstOffset = Int(exactly: first_offset),
              let earliestPresentationTime = Int(exactly: earliest_presentation_time)
        else { return nil }

        var infos = [Sidx.SegmentInfo]()
        for _ in 0..<reference_count {
            var code = data.getUint32(offset: &offset)
            let reference_type = (code >> 31) & 1
            let referenced_size = (code & 0x7fffffff)
            let duration = data.getUint32(offset: &offset)

            code = data.getUint32(offset: &offset)
            let starts_with_SAP = (code >> 31) & 1
            let sap_type = (code >> 29) & 7
            let sap_delta_time = (code & 0x0fffffff)
            let info = Sidx.SegmentInfo(type: Int(reference_type), size: Int(referenced_size), duration: Int(duration), sap: Int(starts_with_SAP), sap_type: Int(sap_type), sap_delta: Int(sap_delta_time))
            infos.append(info)
        }

        return Sidx(timescale: Int(timescale), firstOffset: firstOffset, earliestPresentationTime: earliestPresentationTime, segments: infos)
    }
}

extension Data {
    func getUint32(offset: inout UInt64) -> UInt32 {
        getValue(type: UInt32.self, offset: &offset).bigEndian
    }

    func getUint8(offset: inout UInt64) -> UInt8 {
        getValue(type: UInt8.self, offset: &offset).bigEndian
    }

    func getValue<T>(type: T.Type, offset: inout UInt64) -> T {
        let size = UInt64(MemoryLayout<T>.size)
        let byteOffset = Int(offset) - startIndex
        defer {
            offset += size
        }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: byteOffset, as: T.self) }
    }
}

protocol UIntToUInt8sConvertable {
    var toUInt8s: [UInt8] { get }
}

extension UIntToUInt8sConvertable {
    func toUInt8Arr<T>(endian: T, count: Int) -> [UInt8] {
        var _endian = endian
        let UInt8Ptr = withUnsafePointer(to: &_endian) {
            $0.withMemoryRebound(to: UInt8.self, capacity: count) {
                UnsafeBufferPointer(start: $0, count: count)
            }
        }
        return [UInt8](UInt8Ptr)
    }
}

extension UInt32: UIntToUInt8sConvertable {
    var toUInt8s: [UInt8] {
        return toUInt8Arr(endian: bigEndian,
                          count: MemoryLayout<UInt32>.size)
    }
}

extension UInt64: UIntToUInt8sConvertable {
    var toUInt8s: [UInt8] {
        return toUInt8Arr(endian: bigEndian,
                          count: MemoryLayout<UInt64>.size)
    }
}
