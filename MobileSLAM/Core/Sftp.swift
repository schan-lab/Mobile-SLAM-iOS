import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Security
import UIKit

// ------------------------------------------------------------------ saved destinations

/// One SFTP destination. Passwords live in the Keychain, not here.
struct SftpHost: Codable, Identifiable, Hashable {
    enum Auth: String, Codable {
        case key
        case password
    }

    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var user = ""
    /// Remote directory; relative paths start at the login directory. Empty = login directory.
    var remoteDir = ""
    var auth = Auth.key
    /// Host key accepted on the first connection (OpenSSH format). A different key is refused.
    var hostKey: String?

    var title: String { name.isEmpty ? "\(user)@\(host)" : name }
    var summary: String { "\(user)@\(host):\(port)" + (remoteDir.isEmpty ? "" : "  \(remoteDir)") }
}

/// Saved destinations (UserDefaults) and their passwords (Keychain).
enum SftpHostStore {
    private static let key = "sftp_hosts"

    static func load() -> [SftpHost] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SftpHost].self, from: d)) ?? []
    }

    static func save(_ hosts: [SftpHost]) {
        if let d = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func upsert(_ h: SftpHost) {
        var all = load()
        if let i = all.firstIndex(where: { $0.id == h.id }) {
            all[i] = h
        } else {
            all.append(h)
        }
        save(all)
    }

    static func delete(_ h: SftpHost) {
        save(load().filter { $0.id != h.id })
        Keychain.delete(account: "password.\(h.id.uuidString)")
    }

    static func password(_ h: SftpHost) -> String? {
        Keychain.read(account: "password.\(h.id.uuidString)").flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setPassword(_ h: SftpHost, _ pw: String) {
        if pw.isEmpty {
            Keychain.delete(account: "password.\(h.id.uuidString)")
        } else {
            Keychain.write(account: "password.\(h.id.uuidString)", Data(pw.utf8))
        }
    }
}

/// Generic password items of this app (this device only, available after the first unlock).
enum Keychain {
    private static let service = "MobileSLAM.sftp"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(account: String, _ data: Data) -> Bool {
        delete(account: account)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

// ------------------------------------------------------------------ key pair

/// The app's SSH key pair (Ed25519). The private key never leaves the Keychain.
enum SshKey {
    private static let account = "ed25519"

    static var privateKey: Curve25519.Signing.PrivateKey? {
        Keychain.read(account: account).flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
    }

    /// Creates a new key pair, replacing the old one (servers must be given the new public key).
    @discardableResult
    static func generate() -> Bool {
        Keychain.write(account: account, Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    static func delete() { Keychain.delete(account: account) }

    /// Public key line for ~/.ssh/authorized_keys.
    @MainActor
    static var publicKeyLine: String? {
        guard let blob = publicBlob else { return nil }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        return "ssh-ed25519 \(blob.base64EncodedString()) mobileslam@\(device)"
    }

    /// SHA256 fingerprint as shown by ssh-keygen -l.
    static var fingerprint: String? {
        guard let blob = publicBlob else { return nil }
        let b64 = Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(b64)"
    }

    private static var publicBlob: Data? {
        guard let k = privateKey else { return nil }
        var b = Data()
        func put(_ d: Data) {
            var n = UInt32(d.count).bigEndian
            b.append(Data(bytes: &n, count: 4))
            b.append(d)
        }
        put(Data("ssh-ed25519".utf8))
        put(k.publicKey.rawRepresentation)
        return b
    }
}

// ------------------------------------------------------------------ upload

enum SftpError: LocalizedError {
    case noKey
    case noPassword
    case hostKeyChanged(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return L("キーペアがありません。SFTP 設定で作成してください。")
        case .noPassword: return L("パスワードが設定されていません。")
        case .hostKeyChanged: return L("サーバーのホスト鍵が前回と違います。接続先が正しいか確認し、問題なければ接続先の設定でホスト鍵をリセットしてください。")
        }
    }
}

/// Accepts the pinned host key, or any key on the first connection (remembered by the caller afterwards).
private final class HostKeyPin: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let pinned: String?
    private(set) var seen: String?

    init(pinned: String?) { self.pinned = pinned }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let s = String(openSSHPublicKey: hostKey)
        seen = s
        if let pinned, Self.normalize(pinned) != Self.normalize(s) {
            validationCompletePromise.fail(SftpError.hostKeyChanged(s))
        } else {
            validationCompletePromise.succeed(())
        }
    }

    /// "type base64" (drops a trailing comment).
    static func normalize(_ k: String) -> String { k.split(separator: " ").prefix(2).joined(separator: " ") }
}

enum SftpUploader {
    /// Bytes read from the file per write call (Citadel splits it into 32 kB SFTP requests).
    /// Writes are sequential: Citadel's SFTP client does not support concurrent requests on one session.
    private static let block = 1 << 20

    struct Result {
        let remotePath: String
        /// Set on the first connection: the host key to remember.
        let newHostKey: String?
    }

    /// Uploads the file to host.remoteDir (created if missing), overwriting a file of the same name.
    /// A partly written file is removed when the transfer fails. (No upload-then-rename: Citadel's rename request
    /// carries an SFTP v5 field that strict v3 servers reject.)
    static func upload(_ file: URL, to host: SftpHost, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Result {
        let auth: SSHAuthenticationMethod
        switch host.auth {
        case .key:
            guard let k = SshKey.privateKey else { throw SftpError.noKey }
            auth = .ed25519(username: host.user, privateKey: k)
        case .password:
            guard let pw = SftpHostStore.password(host) else { throw SftpError.noPassword }
            auth = .passwordBased(username: host.user, password: pw)
        }
        let pin = HostKeyPin(pinned: host.hostKey)
        let client = try await SSHClient.connect(host: host.host, port: host.port, authenticationMethod: auth,
                                                 hostKeyValidator: .custom(pin), reconnect: .never,
                                                 connectTimeout: .seconds(15))
        do {
            let sftp = try await client.openSFTP()
            let dir = host.remoteDir.trimmingCharacters(in: .whitespaces)
            try await makeDirs(sftp, dir)
            let name = file.lastPathComponent
            let path = dir.isEmpty ? name : (dir.hasSuffix("/") ? dir + name : dir + "/" + name)
            do {
                try await send(file, sftp: sftp, path: path, progress: progress)
            } catch {
                try? await sftp.remove(at: path)
                throw error
            }
            try? await sftp.close()
            try? await client.close()
            return Result(remotePath: path, newHostKey: host.hostKey == nil ? pin.seen : nil)
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// mkdir -p (errors for existing directories are ignored; a real problem shows up when opening the file).
    private static func makeDirs(_ sftp: SFTPClient, _ dir: String) async throws {
        guard !dir.isEmpty, dir != "/", dir != "~" else { return }
        var cur = dir.hasPrefix("/") ? "" : "."
        for c in dir.split(separator: "/") where !c.isEmpty && c != "." {
            cur += "/" + c
            try? await sftp.createDirectory(atPath: cur)
        }
    }

    private static func send(_ file: URL, sftp: SFTPClient, path: String,
                             progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        let remote = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        do {
            var offset: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let data = try fh.read(upToCount: block), !data.isEmpty else { break }
                try await remote.write(ByteBuffer(bytes: data), at: UInt64(offset))
                offset += Int64(data.count)
                progress(offset, total)
            }
            try await remote.close()
        } catch {
            try? await remote.close()
            throw error
        }
    }
}
