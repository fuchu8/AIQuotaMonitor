import Foundation
import Combine

/// 菜单栏详情 NSPopover 的视口尺寸。
///
/// 必须与 `NSPopover.contentSize` 一致：先前把 hosting frame 先撑到 900 再读
/// `fittingSize`，会得到近全屏高度，内容与气泡错位（「画面错位」）。
@MainActor
final class PanelChrome: ObservableObject {
    static let shared = PanelChrome()

    static let width: CGFloat = 342
    /// 主详情目标高度；小屏由 StatusBarController 按可见区域下调。
    /// 顶栏/底栏在 ScrollView 外；高度需够用，且 hosting 必须钉满内容区。
    static let preferredHeight: CGFloat = 620

    @Published var viewportHeight: CGFloat = PanelChrome.preferredHeight
}
