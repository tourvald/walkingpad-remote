// Compile after the production TargetSegment and TrainingZoneScale declarations
// extracted unchanged from ContentView.swift into the same temporary source file.
// Simulator-only ImageRenderer regression; no manager, transport or persisted state.
import SwiftUI
import UIKit

@main struct ActiveScalePreview {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bounds = [60...134, 135...146, 147...158, 159...170, 171...220]
        let segments = bounds.enumerated().map { index, range in
            TrainingHubPresentation.TargetSegment(
                id: index, title: "Z\(index + 1)", rangeText: "\(range.lowerBound)–\(range.upperBound)",
                lowerBound: range.lowerBound, upperBound: range.upperBound,
                tint: [Color.blue, .green, .yellow, .orange, .red][index]
            )
        }
        var pixels: [String: Data] = [:]
        for (name, bpm, threshold, reserve, expected) in [
            ("main-available", 152 as Int?, nil as Int?, true, 80.0),
            ("main-unavailable", nil, nil, true, 80.0),
            ("main-restored", 152, nil, true, 80.0),
            ("cooldown-available", 124, 115, true, 80.0),
            ("cooldown-unavailable", nil, 115, true, 80.0),
            ("hub", nil, nil, false, 60.0)
        ] {
            let scale = TrainingZoneScale(
                segments: segments, selectedSegmentID: nil,
                liveMarkerBPM: bpm, targetThresholdBPM: threshold,
                interactive: false, reservesMarkerSpace: reserve, onSegmentTap: { _ in }
            )
            let view = VStack(spacing: 0) {
                scale
                Color.purple.frame(height: 16)
            }
            .frame(width: 320)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            var bitmap: CGImage?
            renderer.render { size, draw in
                precondition(size == CGSize(width: 320, height: expected), "\(name): \(size)")
                let context = CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                draw(context)
                bitmap = context.makeImage()
            }
            pixels[name] = bitmap!.dataProvider!.data! as Data
            let image = UIImage(cgImage: bitmap!)
            try image.pngData()!.write(to: directory.appendingPathComponent("\(name).png"))
        }
        precondition(pixels["main-available"] == pixels["main-restored"])
        let rowBytes = 320 * 4
        precondition(pixels["main-unavailable"]!.prefix(20 * rowBytes).allSatisfy { $0 == 255 })
        precondition(pixels["main-available"]!.dropFirst(25 * rowBytes)
            == pixels["main-unavailable"]!.dropFirst(25 * rowBytes))
        precondition(pixels["cooldown-available"]!.dropFirst(25 * rowBytes)
            == pixels["cooldown-unavailable"]!.dropFirst(25 * rowBytes))
        print("6 SwiftUI footprint + 4 pixel invariants passed (320 pt; main/cooldown/Hub)")
    }
}
