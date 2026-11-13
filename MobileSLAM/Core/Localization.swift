import Foundation

/// Localized UI string. Keys are the Japanese source text (development language: ja);
/// translations live in Localizable.xcstrings. Use format specifiers (%@, %d, %.1f) for values,
/// then String(format: L("..."), ...), so translations can reorder words.
func L(_ key: String.LocalizationValue) -> String { String(localized: key) }
