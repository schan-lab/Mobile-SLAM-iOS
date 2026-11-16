import Foundation

/// Files saved by the app live in Documents (visible in the Files app under "このiPhone内 / Mobile SLAM").
enum MapStore {
    struct Item: Identifiable, Hashable {
        let url: URL
        let size: Int64
        let modified: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Raw packet recordings (large; excluded from iCloud / device backups).
    static var rawDir: URL {
        var d = documents.appendingPathComponent("raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? d.setResourceValues(v)
        return d
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    static func newMapURL() -> URL { documents.appendingPathComponent("map_\(timestamp()).pcd") }

    /// PCD files in Documents, newest first.
    static func list() -> [Item] { files(in: [documents], ext: "pcd") }

    /// ROS 2 bags (MCAP): recordings in raw/ and files imported into Documents, newest first.
    static func listBags() -> [Item] { files(in: [rawDir, documents], ext: "mcap") }

    private static func files(in dirs: [URL], ext: String) -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys)) ?? [] }
        return urls.filter { $0.pathExtension.lowercased() == ext }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Item(url: u, size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }

    /// Copies an external file (from the document picker) into Documents. Returns the new URL.
    static func importFile(_ src: URL) throws -> URL {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        var dst = documents.appendingPathComponent(src.lastPathComponent)
        if dst.standardizedFileURL == src.standardizedFileURL { return dst }
        var k = 1
        let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = documents.appendingPathComponent("\(base)_\(k).\(ext)")
            k += 1
        }
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
}
