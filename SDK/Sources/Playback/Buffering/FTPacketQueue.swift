//
//  FTPacketQueue.swift
//  
//
//  Edited by TP on 2024/7/30.
//

import Foundation
@_implementationOnly import libavcodec
class FTPacketQueue: NSObject {
    private(set) var size: Int = 0
    private(set) var duration: TimeInterval = 0
    private(set) var timebase: TimeInterval
    private var condition = NSCondition()
    private var packets = [UnsafeMutablePointer<AVPacket>]()
    private var destroyToken = false
    // Owned by FTVideoDecoder; queue must never free this shared flush marker.
    var sentinel: UnsafeMutablePointer<AVPacket>?

    var count: Int {
        return packets.count
    }

    init(timebase: TimeInterval) {
        self.timebase = timebase
        super.init()
    }

    static func packetQueue(withTimebase timebase: TimeInterval) -> FTPacketQueue {
        return FTPacketQueue(timebase: timebase)
    }

    func putPacket(_ packet: UnsafeMutablePointer<AVPacket>, duration: TimeInterval) {
        condition.lock()
        if destroyToken {
            condition.unlock()
            if packet != sentinel {
                var p: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&p)
            }
            return
        }
        
        packets.append(packet)
        size += Int(packet.pointee.size)
        if packet.pointee.duration > 0 {
            self.duration += Double(packet.pointee.duration) * self.timebase
        } else if duration > 0 {
            self.duration += duration
        }
        condition.signal()
        condition.unlock()
    }

    func getPacket(timeout: TimeInterval? = nil) -> UnsafeMutablePointer<AVPacket>? {
        condition.lock()
        while packets.isEmpty {
            if destroyToken {
                condition.unlock()
                return nil
            }
            if let timeout {
                let signaled = condition.wait(until: Date().addingTimeInterval(timeout))
                if !signaled && packets.isEmpty { condition.unlock(); return nil }
            } else { condition.wait() }
        }
        let packet = packets.removeFirst()
        size -= Int(packet.pointee.size)
        if size < 0 || count <= 0 {
            size = 0
        }
        duration -= Double(packet.pointee.duration) * timebase
        if duration < 0 || count <= 0 {
            duration = 0
        }
        condition.unlock()
        return packet
    }

    /// Jump only when the replacement random-access packet is already queued.
    /// Keeping that keyframe in the queue avoids dropping an undecodable tail/GOP.
    func discardBeforeKeyframe(notBefore target: TimeInterval, noLaterThan limit: TimeInterval,
                               timestampOffset: TimeInterval) -> (packets: Int, position: TimeInterval)? {
        condition.lock(); defer { condition.unlock() }
        guard !destroyToken else { return nil }
        var candidate: (index: Int, position: TimeInterval)?
        for (index, packet) in packets.enumerated() {
            // A flush marker belongs to another seek epoch; never cross it.
            if packet == sentinel { break }
            // Edit-list preroll may contain duplicate key packets marked DISCARD;
            // they maintain references but cannot start a presentation interval.
            guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                  packet.pointee.flags & AV_PKT_FLAG_DISCARD == 0 else { continue }
            let timestamp = packet.pointee.pts != FT_AV_NOPTS_VALUE ? packet.pointee.pts : packet.pointee.dts
            guard timestamp != FT_AV_NOPTS_VALUE else { continue }
            let position = Double(timestamp) * timebase - timestampOffset
            guard position >= target, position <= limit else { continue }
            if candidate == nil || position > candidate!.position { candidate = (index, position) }
        }
        guard let candidate else { return nil }
        let discarded = Array(packets.prefix(candidate.index))
        packets.removeFirst(candidate.index)
        for pointer in discarded {
            size -= Int(pointer.pointee.size)
            duration -= max(0, Double(pointer.pointee.duration) * timebase)
            var owned: UnsafeMutablePointer<AVPacket>? = pointer
            av_packet_free(&owned)
        }
        size = max(0, size); duration = max(0, duration)
        return (discarded.count, candidate.position)
    }

    func flush(excluding sentinel: UnsafeMutablePointer<AVPacket>? = nil) {
        condition.lock()
        for i in packets.indices {
            guard packets[i] != (sentinel ?? self.sentinel) else { continue }
            var freePkt: UnsafeMutablePointer<AVPacket>? = packets[i]
            av_packet_free(&freePkt)
        }
        packets.removeAll()
        size = 0
        duration = 0
        condition.unlock()
    }

    func destroy() {
        condition.lock()
        destroyToken = true
        for packet in packets where packet != sentinel {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
        }
        packets.removeAll()
        size = 0
        duration = 0
        condition.broadcast()
        condition.unlock()
    }
}
