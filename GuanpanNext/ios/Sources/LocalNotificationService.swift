import Foundation
import UserNotifications

/// Local delivery is useful even while NAS is offline. Remote APNs delivery is
/// intentionally separate because it requires the user's Apple credentials and
/// a server-side signing configuration.
enum NextLocalNotificationService {
    static func authorizationStatus() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "系统通知已允许"
        case .denied: return "系统通知已关闭"
        case .notDetermined: return "尚未请求系统通知权限"
        @unknown default: return "系统通知状态未知"
        }
    }

    static func requestAuthorization() async -> String {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return allowed ? "系统通知已允许" : "系统通知未允许"
        } catch { return "通知权限请求失败：\(error.localizedDescription)" }
    }

    static func deliver(id: UUID, title: String, detail: String) async -> String {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = detail; content.sound = .default
        content.userInfo = ["guanpan-alert-id": id.uuidString]
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
            return "本机通知已投递"
        } catch { return "本机通知投递失败：\(error.localizedDescription)" }
    }
}
