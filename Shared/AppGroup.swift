import Foundation

/// App 与表盘小组件共享的数据位置
enum AppGroup {
    static let identifier = "group.com.watchai.client"

    /// 旧版本的数据目录（App 自身容器的 Application Support）
    static var legacyStoreRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchAI", isDirectory: true)
    }

    /// App Group 中的数据目录；签名未配置 App Group 时为 nil
    static var sharedStoreRoot: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent("WatchAI", isDirectory: true)
    }
}
