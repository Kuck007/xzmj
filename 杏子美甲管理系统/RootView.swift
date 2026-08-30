import SwiftUI
import SwiftData

/// 根视图：根据登录状态切换界面
/// - 无用户 → 初始化界面（创建超管）
/// - 有用户未登录 → 登录界面
/// - 已登录 → 主界面
struct RootView: View {
    @Query private var users: [User]

    var body: some View {
        Group {
            if users.isEmpty {
                InitialSetupView()
            } else if SessionManager.shared.currentUser == nil {
                LoginView()
            } else {
                ContentView()
            }
        }
    }
}
