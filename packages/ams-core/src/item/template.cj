// ============================================================
// ams.core.item.template · 条目模板的「模板 → 条目」派生规则
//
// FR-ARCH-012（方案 C：骨架 + 字段默认值）中真正有逻辑的只有两件事：
//   ① 标题序号展开（含 `{n}` 占位 / 无占位时的 ` (i)` 后缀）
//   ② 有效期偏移换算（模板存「偏移天数」，套用时才算绝对日期）
//
// 为什么单独抽成纯函数放在 core：
//   · 这两条规则是**业务语义**（不属于 HTTP 层），后续 CSV / 导出包回导
//     若也要按同一口径造标题，必须是同一份实现，而不是复制一遍；
//   · 纯函数可单测 —— 路由层的方法依赖 ApiRequest / 仓储，测不动；
//   · 有效期换算一旦「套用当天」算错，会静默产生一批日期错误的档案，
//     这类缺陷在 UI 上很难肉眼发现。
// ============================================================
package ams.core.item

import std.collection.*

import ams.kernel.time.*

/**
 * 条目模板派生器。
 */
public class TemplatePlan {
    /** 标题里的序号占位符 */
    public static let PLACEHOLDER: String = "{n}"

    /** 有效期偏移的上限（10 年）—— 再长基本等于「不设有效期」 */
    public static let MAX_OFFSET_DAYS: Int64 = 3650

    /**
     * 展开单条标题。
     *
     * 规则：
     *   · 含 `{n}` → 替换为序号（1-based）；
     *   · 不含占位且 total > 1 → 追加 ` (i)`。
     *     为什么必须加：同名同分类的条目在列表里无法区分，
     *     用户套用 3 条「身份证」后会得到 3 行完全一样的记录。
     *   · total == 1 且不含占位 → 原样返回（单个条目不需要序号）。
     *
     * @param base  模板标题
     * @param index 序号（1-based）
     * @param total 本次套用总数
     */
    public static func title(base: String, index: Int64, total: Int64): String {
        if (base.contains(PLACEHOLDER)) {
            return base.replace(PLACEHOLDER, "${index}")
        }
        if (total > 1) {
            return "${base} (${index})"
        }
        return base
    }

    /**
     * 批量展开标题。
     *
     * @param base  模板标题
     * @param count 套用条数（< 1 视为 1；> MAX_COUNT 由调用方先钳制）
     */
    public static func titles(base: String, count: Int64): ArrayList<String> {
        let n = if (count < 1) { 1 } else { count }
        let out = ArrayList<String>()
        for (i in 1..(n + 1)) {
            out.add(title(base, i, n))
        }
        return out
    }

    /**
     * 有效期偏移换算：以「套用当天 + N 天」的日期（yyyy-MM-dd）。
     *
     * 为什么模板存偏移而不是绝对日期：模板会长期复用，绝对日期一过期
     * 就会批量产出「已过期」的档案。
     *
     * @param nowMs      基准时刻（毫秒）
     * @param offsetDays 偏移天数；<= 0 表示不设有效期，返回空串
     */
    public static func expiryDate(nowMs: Int64, offsetDays: Int64): String {
        if (offsetDays <= 0) {
            return ""
        }
        let days = if (offsetDays > MAX_OFFSET_DAYS) { MAX_OFFSET_DAYS } else { offsetDays }
        let ms = nowMs + days * 24 * 3600 * 1000
        let iso = Times.toIso8601(ms)
        if (iso.size >= 10) {
            return iso[0..10]
        }
        return iso
    }
}
