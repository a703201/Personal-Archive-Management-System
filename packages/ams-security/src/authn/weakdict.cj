// ============================================================
// ams.security.authn · 弱口令字典
//
// 用途（FR-AUTH-004）：提供常见弱口令清单，供 PasswordValidator 拒绝。
//
// 【为什么需要它】
//   PasswordValidator 的「弱口令字典」检查此前**没有任何数据源** ——
//   传入的 weakPasswords 数组在生产中不存在，校验形同虚设。
//   本文件提供一份内置的常用弱口令表，使该检查真正生效。
//
// 【安全说明】
//   ① 这些口令本身是**公开的**（泄露字典的一大半），列出它们不构成风险；
//   ② 字典只用于**拒绝**，不用于生成建议；
//   ③ PasswordValidator 构造时会把字典转成 SM3 摘要，内存里不留明文。
//
// 【可扩展】
//   生产环境建议从配置中心/文件加载更大的字典（如 SecLists top-10000），
//   本内置表作为兜底，保证「开箱即用」。
// ============================================================
package ams.security.authn

/**
 * 常见弱口令表。
 */
public class WeakPasswords {
    /**
     * 内置弱口令列表（常见泄露口令 + 中文系统常见弱口令）。
     */
    public static func common(): Array<String> {
        return [
            // ---- 纯数字 ----
            "123456", "1234567", "12345678", "123456789", "1234567890",
            "111111", "000000", "666666", "888888", "123123",
            // ---- 常见词 + 数字 ----
            "password", "password1", "password123", "passw0rd", "p@ssword",
            "admin", "admin123", "admin888", "administrator", "root",
            "root123", "test", "test123", "test1234", "guest",
            "guest123", "user", "user123", "login", "welcome",
            "qwerty", "qwerty123", "abc123", "abc123456", "a123456",
            "letmein", "changeme", "master", "dragon", "monkey",
            "shadow", "sunshine", "princess", "football", "baseball",
            "trustno1", "iloveyou", "whatever", "hello", "secret",
            "asdfgh", "asdfghjkl", "zxcvbnm", "1q2w3e4r", "qazwsx",
            // ---- 常见键盘序 ----
            "1qaz2wsx", "qazwsxedc", "zaq12wsx",
            // ---- 信息类 ----
            "company", "company123", "cisco", "cisco123", "huawei",
            "huawei123", "aliyun", "aliyun123", "1234qwer", "qwer1234",
            // ---- 中文拼音/常见组合 ----
            "woaini", "woaini1314", "nihao", "nihao123", "mima",
            "mima123", "admin123456", "88888888", "a123456789",
            // ---- 长度与字符类别均达标、但仍属常见弱口令 ----
            // （弱口令字典要在通过「长度 + 字符类别」两道规则后才生效，
            //   故字典里必须包含足够长、足够复杂的常见口令）
            "Password123!", "Admin@12345", "Test@123456", "Woaini@1234",
            "Qwer@123456", "Hello@12345", "Abc@1234567", "P@ssword1234",
            "Welcome@123", "Changeme@12", "Letmein@123", "Master@1234",
            "Root@1234567", "Admin@2024", "Qwer1234@56", "Abcd@123456",
            // ---- 键盘与年份 ----
            "qwe123", "qwe456", "1qazxsw2", "147258369", "258369147",
            "963258741", "passw0rd123", "P@ssw0rd", "Admin@123",
            "Test@1234", "Changeme1", "Password1!"
        ]
    }

    /**
     * 字典条目数（供测试与运维确认）。
     */
    public static func size(): Int64 {
        return WeakPasswords.common().size
    }
}
