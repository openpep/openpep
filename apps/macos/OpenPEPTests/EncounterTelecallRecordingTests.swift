// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Foundation
import Testing
@testable import OpenPEP

@Suite("TELECALL-AUDIO-001 bounded WAV writer")
struct EncounterTelecallRecordingTests {
    private let origin = CMTime(seconds: 100, preferredTimescale: 48_000)

    @Test("mixes two sources by timestamp with overlap and silence gaps")
    func offsetsOverlapAndGaps() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try EncounterTelecallWAVWriter(url: url, maximumDuration: 1)

        try writer.write(
            buffer(rate: 16_000, frames: 160, value: 1),
            timestamp: origin,
            origin: origin,
            source: .application
        )
        try writer.write(
            buffer(rate: 16_000, frames: 160, value: 1),
            timestamp: CMTimeAdd(origin, CMTime(seconds: 0.005, preferredTimescale: 16_000)),
            origin: origin,
            source: .microphone
        )
        try writer.write(
            buffer(rate: 16_000, frames: 80, value: 0.5),
            timestamp: CMTimeAdd(origin, CMTime(seconds: 0.02, preferredTimescale: 16_000)),
            origin: origin,
            source: .application
        )
        try writer.finish()

        let samples = try read(url)
        #expect(samples.count == 400)
        #expect(samples[0] == 16_384)
        #expect(samples[79] == 16_384)
        #expect(samples[80] == 32_767)
        #expect(samples[159] == 32_767)
        #expect(samples[160] == 16_384)
        #expect(samples[239] == 16_384)
        #expect(samples[240] == 0)
        #expect(samples[319] == 0)
        #expect(abs(Int(samples[320]) - 8_192) <= 1)
    }

    @Test("converts native 48 kHz and 44.1 kHz buffers without timeline drift")
    func convertsNativeRates() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try EncounterTelecallWAVWriter(url: url, maximumDuration: 1)

        try writer.write(buffer(rate: 48_000, frames: 480, value: 0.5), timestamp: origin, origin: origin, source: .microphone)
        try writer.write(
            buffer(rate: 48_000, frames: 480, value: 0.5),
            timestamp: CMTimeAdd(origin, CMTime(value: 480, timescale: 48_000)),
            origin: origin,
            source: .microphone
        )
        try writer.write(buffer(rate: 44_100, frames: 441, value: 0.25), timestamp: origin, origin: origin, source: .application)
        try writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 320)
        let samples = try read(url)
        let firstAverage = samples[16..<144].reduce(0) { $0 + Int($1) } / 128
        let secondAverage = samples[176..<304].reduce(0) { $0 + Int($1) } / 128
        #expect(abs(firstAverage - 12_288) <= 32, "first average: \(firstAverage)")
        #expect(abs(secondAverage - 8_192) <= 32, "second average: \(secondAverage)")
    }

    @Test("non-integral native chunks meet exactly at rounded timeline boundaries")
    func nativeChunksHaveNoRoundedBoundaryOverlap() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try EncounterTelecallWAVWriter(url: url, maximumDuration: 1)
        for index in 0..<3 {
            try writer.write(
                buffer(rate: 48_000, frames: 512, value: 0.5),
                timestamp: CMTimeAdd(origin, CMTime(value: Int64(index * 512), timescale: 48_000)),
                origin: origin,
                source: .microphone
            )
        }
        try writer.finish()

        let samples = try read(url)
        #expect(samples.count == 512)
        let middle = samples[160..<352].map { abs(Int($0)) }
        #expect(middle.max()! < 12_000)
        #expect(middle.reduce(0, +) / middle.count > 7_000)
    }

    @Test("rejects timestamp regression within one source")
    func rejectsTimestampRegression() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try EncounterTelecallWAVWriter(url: url, maximumDuration: 1)
        try writer.write(buffer(rate: 16_000, frames: 160, value: 0.1), timestamp: origin, origin: origin, source: .application)

        #expect(throws: EncounterTelecallRecordingIssue.timestampRegression) {
            try writer.write(
                buffer(rate: 16_000, frames: 80, value: 0.1),
                timestamp: CMTimeAdd(origin, CMTime(seconds: 0.005, preferredTimescale: 16_000)),
                origin: origin,
                source: .application
            )
        }
        try writer.finish()
    }

    @Test("enforces duration and byte bounds before extending the file")
    func enforcesLimit() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try EncounterTelecallWAVWriter(url: url, maximumDuration: 0.01)

        #expect(throws: EncounterTelecallRecordingIssue.durationExceeded) {
            try writer.write(
                buffer(rate: 16_000, frames: 160, value: 0.1),
                timestamp: CMTimeAdd(origin, CMTime(seconds: 0.001, preferredTimescale: 16_000)),
                origin: origin,
                source: .application
            )
        }
        try writer.finish()
        #expect(try AVAudioFile(forReading: url).length == 160)
        #expect(EncounterTelecallWAVWriter.headerByteCount + UInt64(3_600 * 16_000 * 2) < 116_000_000)
    }

    @Test("an invalid timestamp leaves a standard reopenable WAV")
    func invalidTimestampLeavesReopenableWAV() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try EncounterTelecallWAVWriter(url: url, maximumDuration: 1)
        try writer.write(buffer(rate: 16_000, frames: 160, value: 0.25), timestamp: origin, origin: origin, source: .application)

        #expect(throws: EncounterTelecallRecordingIssue.invalidTimestamp) {
            try writer.write(
                buffer(rate: 16_000, frames: 10, value: 0.2),
                timestamp: .invalid,
                origin: origin,
                source: .microphone
            )
        }
        try writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 160)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test("a file write failure preserves the completed WAV prefix")
    func fileWriteFailurePreservesPrefix() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forUpdating: url)
        let writer = try EncounterTelecallWAVWriter(file: handle, maximumDuration: 1)
        try writer.write(buffer(rate: 16_000, frames: 16, value: 0.2), timestamp: origin, origin: origin, source: .application)
        try handle.close()

        #expect(throws: EncounterTelecallRecordingIssue.fileWriteFailed) {
            try writer.write(
                buffer(rate: 16_000, frames: 16, value: 0.2),
                timestamp: CMTimeAdd(origin, CMTime(value: 16, timescale: 16_000)),
                origin: origin,
                source: .application
            )
        }

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 16)
        #expect(file.fileFormat.sampleRate == 16_000)
    }

    @Test("refuses existing files and symbolic links atomically")
    func refusesExistingDestination() throws {
        let existing = destination()
        let link = destination()
        try Data("conteúdo sintético".utf8).write(to: existing, options: .withoutOverwriting)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: existing)
        }

        #expect(throws: EncounterTelecallRecordingIssue.destinationExists) {
            _ = try EncounterTelecallWAVWriter(url: existing, maximumDuration: 1)
        }
        #expect(throws: EncounterTelecallRecordingIssue.destinationExists) {
            _ = try EncounterTelecallWAVWriter(url: link, maximumDuration: 1)
        }
        #expect(try Data(contentsOf: existing) == Data("conteúdo sintético".utf8))
    }

    @Test("rejects non-finite samples without corrupting the valid prefix")
    func rejectsNonFiniteSamples() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try EncounterTelecallWAVWriter(url: url, maximumDuration: 1)
        try writer.write(buffer(rate: 16_000, frames: 16, value: 0.1), timestamp: origin, origin: origin, source: .application)

        #expect(throws: EncounterTelecallRecordingIssue.invalidAudio) {
            try writer.write(
                buffer(rate: 16_000, frames: 16, value: .nan),
                timestamp: CMTimeAdd(origin, CMTime(value: 16, timescale: 16_000)),
                origin: origin,
                source: .application
            )
        }
        try writer.finish()
        #expect(try AVAudioFile(forReading: url).length == 16)
    }

    @Test("finishing without any source reports failure after closing the WAV")
    func requiresSomeAudio() async throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try EncounterTelecallWAVWriter(url: url, maximumDuration: 1)
        let output = EncounterTelecallStreamOutput(writer: writer, maximumDuration: 1) { _ in }

        let event = await output.finish(event: .finished, notify: false)

        #expect(event == .failed)
        #expect(try AVAudioFile(forReading: url).length == 0)
    }

    @Test("a single active source finishes successfully while the other source is silent", arguments: [false, true])
    func acceptsOneSource(microphone: Bool) async throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try EncounterTelecallWAVWriter(url: url, maximumDuration: 1)
        let output = EncounterTelecallStreamOutput(writer: writer, maximumDuration: 1) { _ in }
        output.setOrigin(origin)
        let pcm = buffer(rate: 16_000, frames: 160, value: 0.25)
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000), presentationTimeStamp: origin, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 160,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr)
        let captured = try #require(sample)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(captured, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        output.queue.sync { output.receive(captured, of: microphone ? .microphone : .audio) }
        let event = await output.finish(event: .finished, notify: false)
        #expect(event == .finished)
        #expect(try AVAudioFile(forReading: url).length == 160)
    }

    private func buffer(rate: Double, frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = value }
        return buffer
    }

    private func read(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url).dropFirst(Int(EncounterTelecallWAVWriter.headerByteCount))
        return stride(from: 0, to: data.count, by: 2).map { offset in
            let low = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            let high = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
            return Int16(bitPattern: low | high << 8)
        }
    }

    private func destination() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "openpep-telecall-synthetic-\(UUID().uuidString.lowercased()).wav"
        )
    }
}
