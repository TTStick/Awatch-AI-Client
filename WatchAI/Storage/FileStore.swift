import Foundation
import Security

/// 基于 JSON 文件的轻量持久化
enum FileStore {
    /// 数据根目录：App Group 容器（表盘小组件可读）；未配置 App Group 或迁移失败时沿用旧路径
    static let root: URL = {
        let legacy = AppGroup.legacyStoreRoot
        let url: URL
        if let shared = AppGroup.sharedStoreRoot, migrateLegacyStore(from: legacy, to: shared) {
            url = shared
        } else {
            url = legacy
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 一次性迁移：把旧版本的数据目录整体移入 App Group（同卷重命名，不会只迁一半）。
    /// 返回 false 时本次继续使用旧目录，下次启动重试。
    private static func migrateLegacyStore(from old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return true }
        let existing = (try? fm.contentsOfDirectory(atPath: new.path)) ?? []
        guard existing.isEmpty else {
            // 两处都有数据（异常情况）：只补入新位置缺少的条目，冲突的以新位置为准，旧文件保留
            for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where !existing.contains(name) {
                try? fm.moveItem(at: old.appendingPathComponent(name), to: new.appendingPathComponent(name))
            }
            return true
        }
        do {
            try? fm.removeItem(at: new)
            try fm.moveItem(at: old, to: new)
            return true
        } catch {
            print("[FileStore] migration failed: \(error)")
            return false
        }
    }

    private static let ioQueue = DispatchQueue(label: "watchai.filestore", qos: .utility)

    static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[FileStore] decode failed \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        load(type, from: url(name))
    }

    /// 在主线程编码、后台写盘，保证写入顺序
    static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            ioQueue.async {
                try? data.write(to: url, options: .atomic)
            }
        } catch {
            print("[FileStore] encode failed \(url.lastPathComponent): \(error)")
        }
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        save(value, to: url(name))
    }

    static func remove(_ url: URL) {
        ioQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// 等待所有排队的写操作完成
    static func flush() {
        ioQueue.sync {}
    }

    /// 当前排队的写操作完成后，在主线程执行
    static func afterPendingWrites(_ work: @escaping @MainActor () -> Void) {
        ioQueue.async { Task { @MainActor in work() } }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

enum Keychain {
    private static let service = "com.watchai.client"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
