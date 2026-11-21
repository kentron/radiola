//
//  AirPlayAudio.swift
//  Radiola
//
//  Created by kentron on 20.11.2026.
//
//  Plays the decoded PCM from the ring buffer on an AirPlay 1 receiver.
//  The decoder must produce 44.1 kHz, stereo, interleaved Float32.
//

import FFAudio
import Foundation

final class AirPlayAudio: @unchecked Sendable {
    private let ringBuffer: RingBuffer
    let numBuffers: Int

    var onNeedRestart: (() -> Void)?

    private var client: RAOPClient?
    private var thread: Thread?
    private let running = AtomicBool()
    private let threadDone = DispatchSemaphore(value: 0)
    private var volume: Float = 1.0

    // Volume changes are coalesced: a slider drag would otherwise send dozens of requests per second
    private let volumeQueue = DispatchQueue(label: "AirPlayVolume")
    private var volumeUpdateScheduled = false

    /// The format the decoder has to produce for AirPlay.
    static let sampleRate = Int32(RAOPClient.sampleRate)
    static let channels = Int32(RAOPClient.channels)

    /* ****************************************
     *
     * ****************************************/
    init(ringBuffer: RingBuffer, numBuffers: Int) {
        self.ringBuffer = ringBuffer
        self.numBuffers = numBuffers
    }

    /* ****************************************
     * Connects to the receiver (may ask the user for a password) and starts streaming.
     * ****************************************/
    func start(format: FFDecoder.Format, device: AirPlayDevice) throws {
        guard format.sampleRate == AirPlayAudio.sampleRate, format.channelsNum == AirPlayAudio.channels, format.sampleFormat == AV_SAMPLE_FMT_FLT else {
            throw NSError(code: .formatError, message: internalErrorDescription,
                          debug: "AirPlay needs 44100 Hz stereo Float32, got \(format.sampleRate) Hz, \(format.channelsNum) channels")
        }

        let client = try RAOPClient(device: device)
        client.setVolume(volumeQueue.sync { volume })
        volumeQueue.sync { self.client = client }

        running.value = true
        let thread = Thread { [weak self] in
            self?.streamLoop(client)
            self?.threadDone.signal()
        }
        thread.name = "AirPlayStream"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /* ****************************************
     *
     * ****************************************/
    func stop() {
        if thread != nil {
            running.value = false
            threadDone.wait()
            thread = nil
        }

        let client = volumeQueue.sync { () -> RAOPClient? in
            defer { self.client = nil }
            return self.client
        }
        client?.close()
    }

    /* ****************************************
     *
     * ****************************************/
    func setVolume(_ volume: Float) {
        volumeQueue.async { [self] in
            self.volume = volume
            guard !volumeUpdateScheduled else { return }
            volumeUpdateScheduled = true

            volumeQueue.asyncAfter(deadline: .now() + 0.1) { [self] in
                volumeUpdateScheduled = false
                client?.setVolume(self.volume)
            }
        }
    }

    /* ****************************************
     * AirPlay has its own buffering, a fade in would only delay the volume.
     * ****************************************/
    func fadeInVolume(to targetVolume: Float) {
        setVolume(targetVolume)
    }

    /* ****************************************
     * Sends one 352-frame packet every 8 ms, in real time.
     * When the ring buffer runs dry we send silence, so the receiver's clock keeps running.
     * ****************************************/
    private func streamLoop(_ client: RAOPClient) {
        let samplesPerPacket = RAOPClient.framesPerPacket * RAOPClient.channels
        let packetDuration = Double(RAOPClient.framesPerPacket) / Double(RAOPClient.sampleRate)
        let silence = [Int16](repeating: 0, count: samplesPerPacket)

        var pending = [Int16]()
        pending.reserveCapacity(samplesPerPacket * 8)
        var pendingStart = 0

        let start = ProcessInfo.processInfo.systemUptime
        var n = 0
        var underruns = 0

        while running.value {
            let due = start + Double(n) * packetDuration
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 {
                usleep(useconds_t(wait * 1_000_000))
            } else if wait < -1.0 {
                // We fell more than a second behind (e.g. the Mac slept): the receiver has lost sync
                warning("[AirPlay] Stream fell \(-wait) s behind, restarting")
                onNeedRestart?()
                return
            }

            // Pull decoded audio until we have one packet
            while pending.count - pendingStart < samplesPerPacket, let index = ringBuffer.readIndex() {
                let buffer = ringBuffer.buffers[index]
                let count = buffer.audioDataByteSize / MemoryLayout<Float32>.size
                buffer.audioData.withUnsafeBytes { raw in
                    let floats = raw.bindMemory(to: Float32.self)
                    for i in 0 ..< count {
                        // Round to nearest: Int16(Float) alone truncates toward zero
                        pending.append(Int16((max(-1, min(1, floats[i])) * 32767).rounded()))
                    }
                }
                ringBuffer.incReadIndex()
            }

            if pending.count - pendingStart >= samplesPerPacket {
                client.sendAudio(Array(pending[pendingStart ..< pendingStart + samplesPerPacket]))
                pendingStart += samplesPerPacket
                if pendingStart >= samplesPerPacket * 4 {
                    pending.removeFirst(pendingStart)
                    pendingStart = 0
                }
            } else {
                underruns += 1
                if underruns % 125 == 1 {
                    debug("[AirPlay] Ring buffer is empty, sending silence (\(underruns) packets so far)")
                }
                client.sendAudio(silence)
            }

            n += 1
        }
    }
}
