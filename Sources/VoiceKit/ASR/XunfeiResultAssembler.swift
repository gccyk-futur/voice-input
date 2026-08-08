import Foundation

/// 讯飞语音听写流式结果的文本组装器。
///
/// 未开启动态修正（wpgs）时，每个 sn 的结果是对前序结果的追加；
/// 开启后，pgs="rpl" 的结果会替换 rg 指定范围内的历史 sn 片段（动态修正）。
/// 组装方式：以 sn 为槽位存放片段，rpl 时先清空被替换槽位，最终按 sn 升序拼接。
struct XunfeiResultAssembler: Equatable {
    private var slots: [Int: String] = [:]

    /// 当前完整文本（最终结果 + 修正后的中间结果）。
    var text: String {
        slots.keys.sorted().reduce(into: "") { $0 += slots[$1] ?? "" }
    }

    var isEmpty: Bool { text.isEmpty }

    /// 应用一片结果。
    /// - Parameters:
    ///   - sn: 结果序号（槽位）
    ///   - fragment: 本片结果文本（ws[].cw[].w 拼接）
    ///   - pgs: "apd" 追加 / "rpl" 替换；nil 表示未开启动态修正（等价 apd）
    ///   - rg: 替换范围 [起, 止]（仅 rpl 有效）
    mutating func apply(sn: Int, fragment: String, pgs: String?, rg: [Int]?) {
        if pgs == "rpl", let rg, rg.count == 2, rg[0] <= rg[1] {
            for i in rg[0]...rg[1] where i != sn {
                slots[i] = ""
            }
        }
        slots[sn] = fragment
    }

    mutating func reset() {
        slots.removeAll()
    }
}
