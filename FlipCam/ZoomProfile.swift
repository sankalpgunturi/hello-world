import CoreGraphics
import Foundation

/// User-facing zoom for the iPhone 17 Pro cameras.
///
/// AVFoundation reports `videoZoomFactor` in device units. Apple's
/// `displayVideoZoomFactorMultiplier` converts that into the 0.5× / 1× / 4×
/// numbers the system camera shows. Video zoom on this phone stops at 15×.
struct ZoomProfile: Equatable {
    var multiplier: CGFloat
    var minimumDisplay: CGFloat
    var maximumDisplay: CGFloat
    var presets: [CGFloat]

    static let identity = ZoomProfile(
        multiplier: 1,
        minimumDisplay: 1,
        maximumDisplay: 1,
        presets: [1]
    )

    static func make(multiplier: CGFloat, deviceMinimum: CGFloat, deviceMaximum: CGFloat) -> ZoomProfile {
        let multiplier = multiplier > 0 ? multiplier : 1
        let minimumDisplay = deviceMinimum * multiplier
        let maximumDisplay = min(max(deviceMaximum * multiplier, minimumDisplay), 15)
        let wanted: [CGFloat] = [0.5, 1, 2, 4, 8]
        let presets = wanted.filter { $0 + 0.001 >= minimumDisplay && $0 <= maximumDisplay + 0.001 }
        return ZoomProfile(
            multiplier: multiplier,
            minimumDisplay: minimumDisplay,
            maximumDisplay: maximumDisplay,
            presets: presets.isEmpty ? [minimumDisplay] : presets
        )
    }

    func displayZoom(forDeviceZoom deviceZoom: CGFloat) -> CGFloat {
        deviceZoom * multiplier
    }

    func deviceZoom(forDisplayZoom display: CGFloat) -> CGFloat {
        let clamped = min(max(display, minimumDisplay), maximumDisplay)
        return clamped / multiplier
    }

    func nearestPreset(to display: CGFloat) -> CGFloat? {
        guard let nearest = presets.min(by: { abs($0 - display) < abs($1 - display) }) else { return nil }
        return abs(nearest - display) < 0.12 ? nearest : nil
    }

    var defaultDisplay: CGFloat {
        presets.contains(where: { abs($0 - 1) < 0.001 }) ? 1 : minimumDisplay
    }
}

enum ZoomFormatting {
    static func readout(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.001 {
            return "\(Int(rounded.rounded()))×"
        }
        return String(format: "%.1f×", rounded)
    }

    static func chip(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.001 {
            return "\(Int(rounded.rounded()))"
        }
        return String(format: "%.1f", rounded)
    }
}
