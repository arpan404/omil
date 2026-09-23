import Foundation
import Testing
@testable import OmilCore

private actor ChunkRecorder {
    var values: [UInt8] = []

    func receive(_ chunk: CapturedChunk) async {
        try? await Task.sleep(for: .milliseconds(1))
        values.append(chunk.pcm16[0])
    }
}

@Suite("Audio forwarding")
struct AudioChunkForwarderTests {
    @Test func finishWaitsForEveryChunkInOrder() async {
        let recorder = ChunkRecorder()
        let forwarder = AudioChunkForwarder { chunk in
            await recorder.receive(chunk)
        }
        for value in UInt8(0)..<UInt8(40) {
            forwarder.append(CapturedChunk(
                pcm16: Data([value]), sampleRate: 16_000, timestamp: Double(value) / 40
            ))
        }

        await forwarder.finish()
        #expect(await recorder.values == Array(UInt8(0)..<UInt8(40)))
    }
}
