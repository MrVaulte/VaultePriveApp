//
//  VoIPAudioEngine.swift
//  Vaulté Privé
//

import AVFoundation
import Security

final class VoIPAudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var onCapturedFrame: ((Data) -> Void)?
    private var isMuted = false
    private var comfortNoiseTimer: Timer?
    private var didFailToStart = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 1,
        interleaved: true
    )!

    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private var inputConverter: AVAudioConverter?
    private var wireToPlayConverter: AVAudioConverter?

    // Jitter buffer: accumulate a few frames before starting playback
    private var jitterBuffer: [Data] = []
    private var jitterReady = false
    private let jitterThreshold = 3

    func start(onFrame: @escaping (Data) -> Void) {
        onCapturedFrame = onFrame
        jitterBuffer.removeAll()
        jitterReady = false
        didFailToStart = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(16000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            didFailToStart = true
            return
        }

        engine.attach(playerNode)

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)

        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)

        inputConverter = AVAudioConverter(from: hwFormat, to: wireFormat)
        wireToPlayConverter = AVAudioConverter(from: wireFormat, to: outputFormat)

        let bufferSize = AVAudioFrameCount(hwFormat.sampleRate * 0.06)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if !self.isMuted {
                self.processCapture(buffer: buffer)
            }
        }

        do {
            try engine.start()
            playerNode.play()
        } catch {
            didFailToStart = true
            return
        }

        startComfortNoiseTimer()
    }

    func stop() {
        comfortNoiseTimer?.invalidate()
        comfortNoiseTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        jitterBuffer.removeAll()
        jitterReady = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var failedToStart: Bool {
        didFailToStart
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    func setSpeaker(_ speaker: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.overrideOutputAudioPort(speaker ? .speaker : .none)
        } catch {}
    }

    func playReceived(_ pcmData: Data) {
        guard !pcmData.isEmpty else { return }

        if !jitterReady {
            jitterBuffer.append(pcmData)
            if jitterBuffer.count >= jitterThreshold {
                jitterReady = true
                for buffered in jitterBuffer {
                    schedulePlayback(buffered)
                }
                jitterBuffer.removeAll()
            }
            return
        }

        schedulePlayback(pcmData)
    }

    private func schedulePlayback(_ pcmData: Data) {
        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { return }
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        srcBuffer.frameLength = AVAudioFrameCount(sampleCount)

        pcmData.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            if let dst = srcBuffer.int16ChannelData?[0] {
                memcpy(dst, src, pcmData.count)
            }
        }

        guard let converter = wireToPlayConverter else {
            playerNode.scheduleBuffer(srcBuffer, completionHandler: nil)
            return
        }

        let outputFormat = converter.outputFormat
        let ratio = outputFormat.sampleRate / wireFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(sampleCount) * ratio)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrames) else {
            playerNode.scheduleBuffer(srcBuffer, completionHandler: nil)
            return
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if error == nil, outBuffer.frameLength > 0 {
            playerNode.scheduleBuffer(outBuffer, completionHandler: nil)
        }
    }

    // MARK: - Comfort noise

    private func startComfortNoiseTimer() {
        comfortNoiseTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self, self.isMuted else { return }
            self.sendComfortNoise()
        }
    }

    private func sendComfortNoise() {
        let byteCount = 1920 // 60ms at 16kHz mono Int16
        var noiseData = Data(count: byteCount)
        noiseData.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            SecRandomCopyBytes(kSecRandomDefault, byteCount, base)
        }
        noiseData.withUnsafeMutableBytes { ptr in
            guard let samples = ptr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<(byteCount / 2) {
                samples[i] = samples[i] / 512
            }
        }
        onCapturedFrame?(noiseData)
    }

    // MARK: - Capture

    private func processCapture(buffer: AVAudioPCMBuffer) {
        guard let converter = inputConverter else { return }

        let ratio = wireFormat.sampleRate / buffer.format.sampleRate
        let outputFrames = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio))
        guard let converted = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: outputFrames) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, converted.frameLength > 0 else { return }

        let byteCount = Int(converted.frameLength) * 2
        var pcmData = Data(count: byteCount)
        pcmData.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress, let src = converted.int16ChannelData?[0] else { return }
            memcpy(dstBase, src, byteCount)
        }

        onCapturedFrame?(pcmData)
    }
}
