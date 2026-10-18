import SwiftUI
import UserNotifications
import WatchKit

final class AppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
    }

    // 前台时也显示通知横幅（计时结束、待办提醒）
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier.hasPrefix("reply-") {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound, .list])
        }
    }
}

@main
struct WatchAIApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(\.openURL, OpenURLAction { url in app.router.handle(url) })
                .onOpenURL { url in app.router.handleDeepLink(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                app.flush()
            case .active:
                app.agent.checkTimers()
            @unknown default:
                break
            }
        }
    }
}
