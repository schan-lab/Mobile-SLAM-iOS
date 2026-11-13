import Foundation

/// User settings, stored in UserDefaults.
enum AppSettings {
    /// Values match the colour modes of the point shader.
    static let colorHeight: Int32 = 0
    static let colorIntensity: Int32 = 2

    static let defaultBlind: Float = 1.5
    static let maxBlind: Float = 5.0

    private static let keyBlind = "blind_m"
    private static let keyColor = "color_mode"

    /// Points closer than this (m) are ignored by SLAM / localisation.
    static var blind: Float {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: keyBlind) != nil else { return defaultBlind }
            return min(max(d.float(forKey: keyBlind), 0), maxBlind)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0), maxBlind), forKey: keyBlind) }
    }

    static var colorMode: Int32 {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: keyColor) != nil else { return colorIntensity }
            return Int32(d.integer(forKey: keyColor)) == colorHeight ? colorHeight : colorIntensity
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: keyColor) }
    }
}
