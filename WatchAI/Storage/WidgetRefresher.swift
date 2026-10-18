import Foundation
import WidgetKit

/// 计时器 / 待办变化后刷新表盘小组件
@MainActor
enum WidgetRefresher {
    private static var generation = 0

    /// 等写盘完成再刷新（小组件直接读 JSON）；连续多次变更只刷新最后一次
    static func reload() {
        generation += 1
        let current = generation
        FileStore.afterPendingWrites {
            guard current == generation else { return }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
