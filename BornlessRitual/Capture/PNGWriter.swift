//
//  PNGWriter.swift
//  Bornless Ritual — PNG encoding for the capture harness (ARCHITECTURE §7 `stills` /
//  `clip` outputs; RENDER_CONTRACT §2 row 14 "Readback | blit | Output → shared
//  MTLBuffer → CGImage → PNG (background queue)", §7 "PNG encoding on a background queue
//  with backpressure (clip mode uses a bounded queue)").
//
//  Role: turns the `CGImage` delivered by `Renderer.requestReadback` (bgra8, sRGB-tagged,
//  see Renderer.makeImage) into a PNG file through ImageIO
//  (`CGImageDestinationCreateWithURL` with `UTType.png`). `PNGWriter` is the synchronous
//  primitive; `PNGWriteQueue` wraps it in a serial background queue with a bounded number
//  of outstanding jobs so a 60 fps clip capture cannot outrun the disk (the caller —
//  the capture harness, another job — blocks in `enqueue` once the bound is reached,
//  which throttles the render loop instead of growing memory without limit).
//
//  Files are written atomically: the PNG is finalised into a temporary sibling file and
//  then moved over the destination, so `Tools/capture/critic_capture.sh` never pulls a
//  half-written frame.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Errors raised while writing PNG files.
enum PNGWriterError: Error, CustomStringConvertible {
    /// The destination directory could not be created.
    case directoryCreationFailed(URL, underlying: Error)
    /// `CGImageDestinationCreateWithURL` / `…WithData` returned nil.
    case destinationCreationFailed(URL?)
    /// `CGImageDestinationFinalize` reported failure.
    case encodingFailed(URL?)
    /// Moving the finished temporary file over the destination failed.
    case replaceFailed(URL, underlying: Error)

    var description: String {
        switch self {
        case .directoryCreationFailed(let url, let underlying):
            return "Could not create directory \(url.path): \(underlying)"
        case .destinationCreationFailed(let url):
            return "Could not create the PNG destination\(url.map { " for \($0.path)" } ?? "")"
        case .encodingFailed(let url):
            return "PNG encoding failed\(url.map { " for \($0.path)" } ?? "")"
        case .replaceFailed(let url, let underlying):
            return "Could not move the finished PNG into place at \(url.path): \(underlying)"
        }
    }
}

/// Synchronous PNG encoding of `CGImage`s via ImageIO.
enum PNGWriter {

    /// Writes `image` as a PNG at `url` (atomically, via a temporary sibling file).
    ///
    /// - Parameters:
    ///   - image: The image to encode (any CGImage; the readback images are bgra8 sRGB).
    ///   - url: Destination file URL; an existing file is replaced.
    ///   - createDirectories: Create the destination's parent directories when missing.
    /// - Throws: `PNGWriterError` when the directory, destination or encoding fails.
    static func write(_ image: CGImage, to url: URL, createDirectories: Bool = true) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if createDirectories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                throw PNGWriterError.directoryCreationFailed(directory, underlying: error)
            }
        }

        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try encode(image, toFile: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: temporaryURL, to: url)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw PNGWriterError.replaceFailed(url, underlying: error)
        }
    }

    /// Encodes `image` as PNG bytes in memory (for manifests, tests or network upload).
    ///
    /// - Parameter image: The image to encode.
    /// - Returns: The PNG file contents.
    /// - Throws: `PNGWriterError` when ImageIO cannot create or finalise the destination.
    static func pngData(for image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.png.identifier as CFString,
                                                                 1, nil) else {
            throw PNGWriterError.destinationCreationFailed(nil)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PNGWriterError.encodingFailed(nil)
        }
        return data as Data
    }

    /// Encodes straight into `fileURL` (no atomicity; used by `write` on the temporary file).
    private static func encode(_ image: CGImage, toFile fileURL: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw PNGWriterError.destinationCreationFailed(fileURL)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PNGWriterError.encodingFailed(fileURL)
        }
    }
}

/// Bounded background queue of PNG writes (RENDER_CONTRACT §7 clip-mode backpressure).
///
/// `enqueue` returns immediately while fewer than `maxPending` writes are outstanding
/// and blocks the caller otherwise; the capture harness calls it from the readback
/// completion (a background queue), so a slow disk throttles capture rather than the
/// memory footprint. `drain()` waits for every queued write to finish (call it before
/// writing `manifest.json` / `frametime.json` at the end of a run).
final class PNGWriteQueue {

    /// Maximum number of writes in flight before `enqueue` blocks.
    let maxPending: Int

    private let queue: DispatchQueue
    private let slots: DispatchSemaphore
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var failures: [(URL, Error)] = []
    private var writtenCount = 0

    /// Creates a queue.
    ///
    /// - Parameters:
    ///   - maxPending: Outstanding-write bound (default 8 ≈ 130 ms of 60 fps frames).
    ///   - qos: Quality of service of the encoding queue.
    init(maxPending: Int = 8, qos: DispatchQoS = .utility) {
        let bound = max(maxPending, 1)
        self.maxPending = bound
        self.queue = DispatchQueue(label: "BornlessRitual.pngWriter", qos: qos)
        self.slots = DispatchSemaphore(value: bound)
    }

    /// Number of PNGs written successfully so far.
    var successCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writtenCount
    }

    /// Writes that failed, in order (URL and error).
    var failedWrites: [(url: URL, error: Error)] {
        lock.lock()
        defer { lock.unlock() }
        return failures.map { (url: $0.0, error: $0.1) }
    }

    /// Schedules `image` to be written at `url`; blocks while `maxPending` writes are outstanding.
    ///
    /// - Parameters:
    ///   - image: The image to encode.
    ///   - url: Destination file URL.
    ///   - completion: Called on the writer queue with `nil` on success or the error.
    func enqueue(_ image: CGImage, to url: URL, completion: ((Error?) -> Void)? = nil) {
        slots.wait()
        group.enter()
        queue.async { [self] in
            defer {
                self.group.leave()
                self.slots.signal()
            }
            do {
                try PNGWriter.write(image, to: url)
                self.lock.lock()
                self.writtenCount += 1
                self.lock.unlock()
                completion?(nil)
            } catch {
                self.lock.lock()
                self.failures.append((url, error))
                self.lock.unlock()
                completion?(error)
            }
        }
    }

    /// Blocks until every enqueued write has finished.
    func drain() {
        group.wait()
    }

    /// Waits up to `timeout` for the queue to empty; returns false on timeout.
    ///
    /// - Parameter timeout: Maximum time to wait.
    func drain(timeout: DispatchTime) -> Bool {
        group.wait(timeout: timeout) == .success
    }
}
