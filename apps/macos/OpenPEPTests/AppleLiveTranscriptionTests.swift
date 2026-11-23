// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors <https://github.com/openpep/openpep>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFAudio
import CoreMedia
import Foundation
import Speech
import Testing
@testable import OpenPEP

@Suite("Apple live local transcription")
struct AppleLiveTranscriptionTests {
    @Test("converts copied PCM to Apple's negotiated format and preserves the audio clock")
    func convertsAndPreservesTimeline() throws {
        let source = try EncounterAudioFormat(sampleRate: 48_000, channelCount: 1)
        let chunk = try EncounterAudioChunk(
            pcm16: Data(repeating: 1, count: 9_600),
            samplePosition: 48_000,
            monotonicTime: 1,
            format: source,
            source: .microphone,
            level: 0.1
        )
        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))

        let input = try AppleLiveTranscription.makeInput(from: chunk, targetFormat: target)

        #expect(input.buffer.format.sampleRate == 16_000)
        #expect(input.buffer.frameLength > 0)
        #expect(CMTimeGetSeconds(try #require(input.bufferStartTime)) == 1)
    }

    // On macOS 27, AnalyzerInput(buffer:) traps on Float32 PCM and SpeechAnalyzer negotiates Int16.
    @Test(
        "accepts a floating-point format negotiated by SpeechAnalyzer",
        .enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27)
    )
    func convertsToFloat32() throws {
        let source = try EncounterAudioFormat(sampleRate: 48_000, channelCount: 1)
        let chunk = try EncounterAudioChunk(
            pcm16: Data(repeating: 1, count: 9_600),
            samplePosition: 0,
            monotonicTime: 1,
            format: source,
            source: .microphone,
            level: 0.1
        )
        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))

        let input = try AppleLiveTranscription.makeInput(from: chunk, targetFormat: target)

        #expect(input.buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(input.buffer.frameLength > 0)
    }

    @Test("promotes an earlier provisional result when Apple advances finalization time")
    func promotesProvisionalWithoutReemission() {
        var stabilizer = AppleLiveResultStabilizer()
        let first = AppleLiveResultSnapshot(text: "Paciente relata melhora", startSeconds: 0, endSeconds: 2)
        let later = AppleLiveResultSnapshot(text: "Mantém o tratamento", startSeconds: 2, endSeconds: 4)

        #expect(stabilizer.receive(first, finalizedThrough: 0).isEmpty)
        let stabilized = stabilizer.receive(later, finalizedThrough: 2)

        #expect(stabilized == [first])
        #expect(stabilizer.provisionalText == later.text)
        #expect(stabilizer.finish() == [later])
    }
}
