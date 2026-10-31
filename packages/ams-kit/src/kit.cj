// ============================================================
// ams.kit · 通用开发框架对外稳定 API 层（Phase 1：functional facade）
//
// 设计目标（见 docs/18 4.1）：把与业务无关的密码学能力收敛到一个入口，
// 使其它项目以最小认知成本使用 AMS 的密码学实现。
//
// 实现说明（Cangjie 1.2.0 约束）：
//   本语言不支持跨包 `public import` 整包，也不支持 `public type = 其他包类型`
//   的跨包类型别名（编译器报 "undeclared type name"）。因此 ams.kit 采用
//   **functional facade**：提供工厂函数与版本常量，底层类型（CryptoProvider /
//   KeyManager / BlindIndex 等）仍由 ams.crypto 暴露——ams.crypto 本身即
//   是那个「可独立发布的框架库」。ams.kit 负责统一入口与后续扩展点。
//
// 约束：框架层严禁 import 任何 AMS 业务包（ams.app / ams.data / ams.api）。
// ============================================================
package ams.kit

import ams.crypto.provider.*
import ams.crypto.impl.*
import ams.crypto.key.*
import ams.crypto.blindindex.*

// 框架版本（与 CHANGELOG 对齐；独立发版后由 cjpm 版本号接管）
public let KIT_VERSION: String = "0.1.0-alpha"

// 构造密码学提供者（SM3 / HMAC-SM3 / SM4-CBC·CTR / PBKDF2-HMAC-SM3）。
// 返回接口类型，调用方以 ams.crypto 的 CryptoProvider 形态使用。
public func newCryptoProvider(): CryptoProvider {
    return StdxCryptoProvider()
}

// 构造密钥管理器。kek 为密钥加密密钥（字节数组），对任意 keyId 均返回同一 kek
// （与 ams-server main.cj 的构造方式一致：单一 KEK 派生盲索引 / 包裹密钥）。
public func newKeyManager(provider: CryptoProvider, kek: Array<Byte>): KeyManager {
    return KeyManager(provider, { keyId: String => kek })
}

// 构造盲索引服务（基于 HMAC-SM3 的可检索加密）。
public func newBlindIndex(provider: CryptoProvider): BlindIndex {
    return BlindIndex(provider)
}
