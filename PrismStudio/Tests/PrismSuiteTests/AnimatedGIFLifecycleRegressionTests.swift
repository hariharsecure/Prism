import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import PrismCore
@testable import PrismSources
import UniformTypeIdentifiers
import XCTest

/// Regression coverage for the callback-originated lifecycle interleavings
/// that ordinary start/stop tests do not exercise.
final class AnimatedGIFLifecycleRegressionTests: XCTestCase {
    func testConcurrentExternalAndCallbackStopsDoNotDeadlockOrEmitAfterReturn() throws {
        if ProcessInfo.processInfo.environment[Self.deadlockProbeEnvironmentKey] == "1" {
            try runConcurrentStopProbe()
            return
        }

        // A genuine Dispatch lock cycle keeps an xctest process alive even
        // after an expectation times out. Run the reproducer in a filtered
        // child xctest so this parent can enforce a real wall-clock timeout and
        // turn a regression into a normal failure instead of wedging the suite.
        let child = Process()
        child.executableURL = URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"
        )
        child.arguments = [
            "-XCTest",
            "PrismSuiteTests.AnimatedGIFLifecycleRegressionTests/"
                + "testConcurrentExternalAndCallbackStopsDoNotDeadlockOrEmitAfterReturn",
            Bundle(for: Self.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.deadlockProbeEnvironmentKey] = "1"
        child.environment = environment

        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        let terminated = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in terminated.signal() }
        try child.run()

        guard terminated.wait(timeout: .now() + 4) == .success else {
            child.terminate()
            if terminated.wait(timeout: .now() + 1) != .success {
                kill(child.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
            XCTFail("external stop deadlocked with callback-originated stop")
            return
        }

        let childOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(child.terminationStatus, 0, childOutput)
    }

    private func runConcurrentStopProbe() throws {
        let url = try Self.makeGIF()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try AnimatedGIFSource(
            id: SourceID("gif.lifecycle.concurrent-stop"),
            fileURL: url,
            canvasSize: CanvasSize(width: 16, height: 16),
            contentMode: .stretch,
            background: .black,
            loop: true
        )
        let callbacks = GIFLifecycleCallbackLog()
        let callbackEntered = DispatchSemaphore(value: 0)
        let nestedStopReturned = DispatchSemaphore(value: 0)
        let externalStopReturned = DispatchSemaphore(value: 0)

        source.onFrame = { frame in
            let callbackNumber = callbacks.append(Self.pixelSignature(frame.pixelBuffer))
            guard callbackNumber == 1 else { return }

            callbackEntered.signal()

            // The external stop publishes `.stopping` before it attempts its
            // playback-queue drain. Waiting for that exact state deterministically
            // constructs the former lock cycle rather than relying on a sleep.
            let deadline = Date().addingTimeInterval(2)
            while source.state != .stopping, Date() < deadline {
                usleep(100)
            }
            guard source.state == .stopping else { return }

            source.stop()
            nestedStopReturned.signal()
        }

        try source.start()
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success,
                       "the first GIF callback never arrived")

        DispatchQueue.global(qos: .userInitiated).async {
            source.stop()
            externalStopReturned.signal()
        }

        let externalResult = externalStopReturned.wait(timeout: .now() + 2)
        guard externalResult == .success else {
            XCTFail("external stop deadlocked with callback-originated stop")
            return
        }
        XCTAssertEqual(nestedStopReturned.wait(timeout: .now() + 1), .success,
                       "callback-originated repeat stop did not return")
        XCTAssertEqual(source.state, .idle)

        let countWhenStopReturned = callbacks.count
        usleep(200_000)
        XCTAssertEqual(callbacks.count, countWhenStopReturned,
                       "a GIF callback was delivered after external stop returned")
        source.onFrame = nil
    }

    func testCallbackStopThenStartRetiresOldGenerationBeforeNewRunEmits() throws {
        let url = try Self.makeGIF()
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try AnimatedGIFSource(
            id: SourceID("gif.lifecycle.restart"),
            fileURL: url,
            canvasSize: CanvasSize(width: 16, height: 16),
            contentMode: .stretch,
            background: .black,
            loop: true
        )
        defer {
            source.stop()
            source.onFrame = nil
        }
        let callbacks = GIFLifecycleCallbackLog()
        let secondCallbackReturned = DispatchSemaphore(value: 0)

        source.onFrame = { frame in
            let callbackNumber = callbacks.append(Self.pixelSignature(frame.pixelBuffer))
            switch callbackNumber {
            case 1:
                source.stop()
                do {
                    try source.start()
                } catch {
                    callbacks.recordRestartError(error)
                }
            case 2:
                source.stop()
                secondCallbackReturned.signal()
            default:
                break
            }
        }

        try source.start()
        XCTAssertEqual(secondCallbackReturned.wait(timeout: .now() + 2), .success,
                       "the restarted GIF generation never emitted")

        let snapshot = callbacks.snapshot
        XCTAssertNil(snapshot.restartError)
        XCTAssertEqual(snapshot.signatures.count, 2)
        if snapshot.signatures.count == 2 {
            XCTAssertNotEqual(snapshot.signatures[0], 0,
                              "pixel readback failed, so generation identity is unproven")
            XCTAssertEqual(snapshot.signatures[1], snapshot.signatures[0],
                           "the old loop emitted frame 1 instead of retiring; "
                               + "the new generation must restart at frame 0")
        }
        XCTAssertEqual(source.state, .idle)

        usleep(200_000)
        XCTAssertEqual(callbacks.count, 2,
                       "the retired GIF generation continued after callback stop")
    }

    private static func makeGIF() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prism_gif_lifecycle_\(UUID().uuidString).gif")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 3, nil
        ) else {
            throw GIFLifecycleTestError.cannotCreateDestination
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 0),
            (0, 1, 0),
            (0, 0, 1),
        ]
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        for color in colors {
            guard let context = CGContext(
                data: nil,
                width: 16,
                height: 16,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw GIFLifecycleTestError.cannotCreateFrame
            }
            context.setFillColor(CGColor(
                srgbRed: color.0,
                green: color.1,
                blue: color.2,
                alpha: 1
            ))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            guard let image = context.makeImage() else {
                throw GIFLifecycleTestError.cannotCreateFrame
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: 0.05
                ]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw GIFLifecycleTestError.cannotFinalize
        }
        return url
    }

    private static func pixelSignature(_ buffer: CVPixelBuffer) -> UInt32 {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return 0
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }
        let x = CVPixelBufferGetWidth(buffer) / 2
        let y = CVPixelBufferGetHeight(buffer) / 2
        let pixel = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4)
        return UInt32(pixel[0]) << 24
            | UInt32(pixel[1]) << 16
            | UInt32(pixel[2]) << 8
            | UInt32(pixel[3])
    }

    private static let deadlockProbeEnvironmentKey =
        "PRISM_ANIMATED_GIF_LIFECYCLE_DEADLOCK_CHILD"
}

private enum GIFLifecycleTestError: Error {
    case cannotCreateDestination
    case cannotCreateFrame
    case cannotFinalize
}

private final class GIFLifecycleCallbackLog: @unchecked Sendable {
    struct Snapshot {
        let signatures: [UInt32]
        let restartError: Error?
    }

    private let lock = NSLock()
    private var signatures: [UInt32] = []
    private var restartError: Error?

    @discardableResult
    func append(_ signature: UInt32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        signatures.append(signature)
        return signatures.count
    }

    func recordRestartError(_ error: Error) {
        lock.lock()
        restartError = error
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return signatures.count
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(signatures: signatures, restartError: restartError)
    }
}
