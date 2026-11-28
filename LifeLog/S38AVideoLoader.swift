import AVFoundation
import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

// s38 の 手7: 画面を下へ送りながら撮った動画 1 本から、コマを選ぶ（決まりは S38ARules.swift の S38AVideo）。
// 動画は端末の一時フォルダに写して読み、選び終えたらすぐ消す（端末にも家の PC にも動画は残さない。送るのは今と同じ縮めた JPEG だけ）。

/// 写真アプリで選んだ動画（一時フォルダへ写す）
struct S38AMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("S38Video", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = dir.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return S38AMovie(url: dest)
        }
    }
}

enum S38AFrames {
    /// 選んだコマ（縮めた JPEG のまま・メモリを使いすぎないため）と、飛ばした数
    struct Picked: Equatable, Sendable {
        var jpegs: [Data]
        var skipped: Int
    }

    /// 動画から cap 枚までのコマを選ぶ。取れなければ空
    nonisolated static func pick(url: URL, cap: Int) async -> Picked {
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds else { return Picked(jpegs: [], skipped: 0) }
        let times = S38AVideo.sampleTimes(duration: duration, cap: cap)
        guard !times.isEmpty else { return Picked(jpegs: [], skipped: 0) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2000, height: 2000)
        let tolerance = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var kept: [Data] = []
        var previous: [UInt8]?
        var skipped = 0
        for t in times {
            if Task.isCancelled { break }
            guard let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
            let cg = result.image
            guard let thumb = gray(cg, side: S38AVideo.side) else { continue }
            guard S38AVideo.keep(previous: previous, current: thumb) else {
                skipped += 1
                continue
            }
            previous = thumb
            if let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) { kept.append(data) }
        }
        let thinned = S38AVideo.thin(kept, cap: cap)
        return Picked(jpegs: thinned, skipped: skipped + (kept.count - thinned.count))
    }

    /// side × side の白黒に縮める
    nonisolated private static func gray(_ image: CGImage, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? pixels : nil
    }
}
