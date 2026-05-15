import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// One filter preset = a friendly name, a glyph, and a closure that takes a
/// source `CIImage` + intensity in `0…1` and returns the filtered image.
/// Filter chains are built lazily inside the closure so we never keep
/// stale `CIFilter` instances around between frames.
struct FilterPreset: Identifiable, Sendable {
    let id: String
    let displayName: String
    let symbol: String
    let apply: @Sendable (CIImage, Double) -> CIImage
}

enum FilterCatalog {
    /// Curated, opinionated set — CapCut-style "color treatments" rather than
    /// effects. Each preset peaks at intensity 1.0 and dissolves back into
    /// the original at 0.0 so the slider in the inspector feels continuous.
    static let presets: [FilterPreset] = [
        FilterPreset(id: "vivid", displayName: "Vivid", symbol: "sparkles") { input, intensity in
            let filter = CIFilter.vibrance()
            filter.inputImage = input
            filter.amount = Float(intensity * 0.9)
            let sat = CIFilter.colorControls()
            sat.inputImage = filter.outputImage ?? input
            sat.saturation = Float(1 + 0.4 * intensity)
            sat.contrast = Float(1 + 0.1 * intensity)
            return sat.outputImage ?? input
        },
        FilterPreset(id: "warm", displayName: "Warm", symbol: "sun.max.fill") { input, intensity in
            let f = CIFilter.temperatureAndTint()
            f.inputImage = input
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - 1200 * intensity, y: 250 * intensity)
            return blend(original: input, filtered: f.outputImage ?? input, intensity: intensity)
        },
        FilterPreset(id: "cool", displayName: "Cool", symbol: "snowflake") { input, intensity in
            let f = CIFilter.temperatureAndTint()
            f.inputImage = input
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 + 1200 * intensity, y: -150 * intensity)
            return blend(original: input, filtered: f.outputImage ?? input, intensity: intensity)
        },
        FilterPreset(id: "noir", displayName: "Noir", symbol: "circle.lefthalf.filled") { input, intensity in
            let f = CIFilter.photoEffectNoir()
            f.inputImage = input
            return blend(original: input, filtered: f.outputImage ?? input, intensity: intensity)
        },
        FilterPreset(id: "mono", displayName: "Mono", symbol: "moon.fill") { input, intensity in
            let f = CIFilter.photoEffectMono()
            f.inputImage = input
            return blend(original: input, filtered: f.outputImage ?? input, intensity: intensity)
        },
        FilterPreset(id: "sepia", displayName: "Sepia", symbol: "camera.fill") { input, intensity in
            let f = CIFilter.sepiaTone()
            f.inputImage = input
            f.intensity = Float(intensity)
            return f.outputImage ?? input
        },
        FilterPreset(id: "fade", displayName: "Fade", symbol: "wand.and.stars") { input, intensity in
            let f = CIFilter.photoEffectFade()
            f.inputImage = input
            return blend(original: input, filtered: f.outputImage ?? input, intensity: intensity)
        },
        FilterPreset(id: "chrome", displayName: "Chrome", symbol: "drop.fill") { input, intensity in
            let f = CIFilter.photoEffectChrome()
            f.inputImage = input
            return blend(original: input, filtered: f.outputImage ?? input, intensity: intensity)
        },
        FilterPreset(id: "process", displayName: "Process", symbol: "paintpalette.fill") { input, intensity in
            let f = CIFilter.photoEffectProcess()
            f.inputImage = input
            return blend(original: input, filtered: f.outputImage ?? input, intensity: intensity)
        },
        FilterPreset(id: "transfer", displayName: "Transfer", symbol: "rectangle.on.rectangle") { input, intensity in
            let f = CIFilter.photoEffectTransfer()
            f.inputImage = input
            return blend(original: input, filtered: f.outputImage ?? input, intensity: intensity)
        },
        FilterPreset(id: "dramatic", displayName: "Dramatic", symbol: "bolt.fill") { input, intensity in
            let c = CIFilter.colorControls()
            c.inputImage = input
            c.saturation = Float(1 - 0.25 * intensity)
            c.contrast = Float(1 + 0.55 * intensity)
            c.brightness = Float(-0.04 * intensity)
            return c.outputImage ?? input
        },
        FilterPreset(id: "dreamy", displayName: "Dreamy", symbol: "cloud.fill") { input, intensity in
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = input
            blur.radius = Float(2.5 * intensity)
            let bright = CIFilter.colorControls()
            bright.inputImage = blur.outputImage ?? input
            bright.brightness = Float(0.06 * intensity)
            bright.saturation = Float(1 + 0.2 * intensity)
            // Clamp back to the source extent so the blur halo doesn't grow
            // past the canvas.
            let extent = input.extent
            return (bright.outputImage ?? input).cropped(to: extent)
        }
    ]

    static let none: FilterPreset = FilterPreset(
        id: "none",
        displayName: "Original",
        symbol: "circle"
    ) { input, _ in input }

    static func find(id: String) -> FilterPreset? {
        if id == none.id { return none }
        return presets.first { $0.id == id }
    }

    /// Apply by id; returns input unchanged when id is unknown or "none".
    static func apply(presetID: String?, intensity: Double, to input: CIImage) -> CIImage {
        guard let id = presetID, id != "none", let preset = find(id: id) else { return input }
        return preset.apply(input, max(0, min(1, intensity)))
    }
}

/// Linear blend between the original and a filtered copy via
/// `CIDissolveTransition`. Lets every preset honour the intensity slider
/// uniformly, even when the underlying CIFilter has no amount parameter
/// (the `photoEffect*` family).
private func blend(original: CIImage, filtered: CIImage, intensity: Double) -> CIImage {
    let amount = max(0, min(1, intensity))
    if amount >= 0.999 { return filtered }
    if amount <= 0.001 { return original }
    let dissolve = CIFilter.dissolveTransition()
    dissolve.inputImage = original
    dissolve.targetImage = filtered
    dissolve.time = Float(amount)
    return dissolve.outputImage ?? filtered
}
