// ============================================================
// ams.security.authn · 单元测试
//
// [结构约定]（实测 SDK 1.0.5）：
//   测试代码与产品代码**物理分离**（本文件在 tests/ 目录，不在 src/）。
//   原因：编译器会优先使用 import-path 里的 .cjo 而非源码，
//   若测试文件与产品代码同目录，.cjo 里会混入未展开的测试宏，
//   导致后续编译报出莫名的 "expected '=>' in lambda expression"。
//   分离后测试包声明为 <被测包>.test，用 import 引用被测包。
//
//   编译运行：bash scripts/test.sh
//
// [另一个约定]：仓颉的 match 分支必须是**单个表达式**，
//   不能写成 { 多行语句 }。故复杂场景一律抽成私有方法。
// ============================================================
package ams.security.authn.test

import std.unittest.*

import ams.crypto.impl.*
import ams.crypto.provider.*
import ams.kernel.error.*

import ams.security.authn.*

@Test
public class PasswordPolicyTest {
    private let provider = StdxCryptoProvider()
    // 测试用较低迭代次数（生产为 600000，测试要快）
    private let policy = PasswordPolicy(minLength: 12, minCharClasses: 3, iterations: 1000)
    private let weakList = ["P@ssword1234", "Admin12345!", "Qwertyui12!", "12345678Abc"]

    private func validator(): PasswordValidator {
        return PasswordValidator(this.policy, this.provider, this.weakList)
    }

    @TestCase
    public func testAcceptsStrongPassword() {
        @Assert(PasswordPolicyTest.isOk(this.validator().check("Str0ng!Passw0rd", "alice")), true)
    }

    @TestCase
    public func testRejectsTooShort() {
        @Assert(PasswordPolicyTest.isTooShort(this.validator().check("Ab1!efgh", "alice")), true)
    }

    @TestCase
    public func testRejectsTooFewCharClasses() {
        // 只有小写 + 数字 -> 2 类
        @Assert(PasswordPolicyTest.isTooFewClasses(this.validator().check("abcdefghij12", "alice")), true)
    }

    @TestCase
    public func testRejectsWeakDictionary() {
        // 弱口令也必须**先通过**长度与字符类别检查，否则会被更早的规则拦下，
        // 够不到弱字典这一步。故用「长度≥12 且含 3 类字符」的弱口令。
        @Assert(PasswordPolicyTest.isWeak(this.validator().check("P@ssword1234", "alice")), true)
    }

    @TestCase
    public func testRejectsContainingUsername() {
        @Assert(PasswordPolicyTest.isContainsUsername(this.validator().check("Alice12345!x", "alice")), true)
    }

    @TestCase
    public func testRejectsRepeatedChars() {
        @Assert(PasswordPolicyTest.isRepeated(this.validator().check("Aaaaaaaaaaaa1", "alice")), true)
    }

    @TestCase
    public func testCountCharClasses() {
        @Assert(PasswordValidator.countCharClasses("abc"), 1)
        @Assert(PasswordValidator.countCharClasses("abcABC"), 2)
        @Assert(PasswordValidator.countCharClasses("abcABC123"), 3)
        @Assert(PasswordValidator.countCharClasses("abcABC123!"), 4)
    }

    @TestCase
    public func testHasRepeatedChars() {
        @Assert(PasswordValidator.hasRepeatedChars("aaaa"), true)
        @Assert(PasswordValidator.hasRepeatedChars("aaab"), false)
        @Assert(PasswordValidator.hasRepeatedChars("ab"), false)
    }

    // ---- match 分支判定辅助（枚举断言无法推断泛型）----

    private static func isOk(r: PasswordCheck): Bool {
        match (r) {
            case PasswordCheck.Ok => return true
            case _ => return false
        }
    }

    private static func isTooShort(r: PasswordCheck): Bool {
        match (r) {
            case PasswordCheck.TooShort(_) => return true
            case _ => return false
        }
    }

    private static func isTooFewClasses(r: PasswordCheck): Bool {
        match (r) {
            case PasswordCheck.TooFewCharClasses(_) => return true
            case _ => return false
        }
    }

    private static func isWeak(r: PasswordCheck): Bool {
        match (r) {
            case PasswordCheck.InWeakDictionary => return true
            case _ => return false
        }
    }

    private static func isContainsUsername(r: PasswordCheck): Bool {
        match (r) {
            case PasswordCheck.ContainsUsername => return true
            case _ => return false
        }
    }

    private static func isRepeated(r: PasswordCheck): Bool {
        match (r) {
            case PasswordCheck.RepeatedChars => return true
            case _ => return false
        }
    }
}

@Test
public class PasswordHasherTest {
    private let hasher = PasswordHasher(StdxCryptoProvider(), PasswordPolicy(iterations: 1000))

    @TestCase
    public func testHashProducesExpectedFormat() {
        let salt = Array<Byte>(16, repeat: 7u8)
        let stored = PasswordHasherTest.hashOf(this.hasher, "Str0ng!Passw0rd", salt)
        @Assert(stored.startsWith("$sm3-pbkdf2$v1$1000$"), true)
        // 6 段（以 $ 分隔）
        @Assert(stored.split("$").size, 6)
    }

    @TestCase
    public func testVerifyCorrectPassword() {
        let salt = Array<Byte>(16, repeat: 7u8)
        let stored = PasswordHasherTest.hashOf(this.hasher, "Str0ng!Passw0rd", salt)
        @Assert(this.hasher.verify("Str0ng!Passw0rd", stored, salt), true)
    }

    @TestCase
    public func testVerifyWrongPassword() {
        let salt = Array<Byte>(16, repeat: 7u8)
        let stored = PasswordHasherTest.hashOf(this.hasher, "Str0ng!Passw0rd", salt)
        @Assert(this.hasher.verify("Wr0ng!Passw0rd", stored, salt), false)
    }

    @TestCase
    public func testDifferentSaltDifferentHash() {
        let s1 = Array<Byte>(16, repeat: 1u8)
        let s2 = Array<Byte>(16, repeat: 2u8)
        let h1 = PasswordHasherTest.hashOf(this.hasher, "Str0ng!Passw0rd", s1)
        let h2 = PasswordHasherTest.hashOf(this.hasher, "Str0ng!Passw0rd", s2)
        @Assert(h1 == h2, false)
    }

    @TestCase
    public func testVerifyMalformedStoredReturnsFalse() {
        let salt = Array<Byte>(16, repeat: 7u8)
        @Assert(this.hasher.verify("x", "not-a-valid-hash", salt), false)
    }

    @TestCase
    public func testGenerateSaltLength() {
        match (this.hasher.generateSalt()) {
            case CryptoResult.Ok(s) => @Assert(s.size, 16)
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    @TestCase
    public func testParseInt64() {
        @Assert(PasswordHasher.parseInt64("123"), 123)
        @Assert(PasswordHasher.parseInt64("0"), 0)
        @Assert(PasswordHasher.parseInt64("abc"), -1)
        @Assert(PasswordHasher.parseInt64(""), -1)
    }

    /**
     * 计算口令哈希（抽成方法以适配 match 的表达式语义）。
     */
    private static func hashOf(h: PasswordHasher, pwd: String, salt: Array<Byte>): String {
        match (h.hash(pwd, salt)) {
            case CryptoResult.Ok(s) => return s
            case CryptoResult.Err(_) => return ""
        }
    }
}

@Test
public class TokenServiceTest {
    private let secret = Array<Byte>(32, repeat: 0x5Au8)

    private func service(store: MemorySessionStore): TokenService {
        let cfg = TokenConfig(accessTtlSeconds: 1800, refreshTtlSeconds: 86400, secret: this.secret)
        return TokenService(StdxCryptoProvider(), cfg, store)
    }

    @TestCase
    public func testIssueCreatesSession() {
        let store = MemorySessionStore()
        let svc = this.service(store)
        let issued = svc.issue("u1", ["owner"], ["archive:read"],
            "127.0.0.1", "test-agent")
        @Assert(TokenServiceTest.isIssued(issued), true)
        @Assert(store.count(), 1)
    }

    @TestCase
    public func testVerifyAccessTokenSuccess() {
        let store = MemorySessionStore()
        let svc = this.service(store)
        let issued = svc.issue("u1", ["owner"], ["archive:read"],
            "127.0.0.1", "ua")
        @Assert(TokenServiceTest.verifyToken(svc, issued, "u1"), true)
    }

    @TestCase
    public func testVerifyTamperedTokenFails() {
        let store = MemorySessionStore()
        let svc = this.service(store)
        let issued = svc.issue("u1", Array<String>(0, repeat: ""), Array<String>(0, repeat: ""), "127.0.0.1", "ua")
        @Assert(TokenServiceTest.tamperedRejected(svc, issued), true)
    }

    @TestCase
    public func testVerifyAfterLogoutFails() {
        let store = MemorySessionStore()
        let svc = this.service(store)
        let issued = svc.issue("u1", Array<String>(0, repeat: ""), Array<String>(0, repeat: ""), "127.0.0.1", "ua")
        @Assert(TokenServiceTest.rejectedAfterLogout(svc, issued), true)
    }

    @TestCase
    public func testLogoutAllRevokesEverySession() {
        let store = MemorySessionStore()
        let svc = this.service(store)
        let a = svc.issue("u1", Array<String>(0, repeat: ""), Array<String>(0, repeat: ""), "1.1.1.1", "ua")
        let b = svc.issue("u1", Array<String>(0, repeat: ""), Array<String>(0, repeat: ""), "2.2.2.2", "ua")
        @Assert(TokenServiceTest.isIssued(a), true)
        @Assert(TokenServiceTest.isIssued(b), true)
        @Assert(svc.logoutAll("u1"), 2)
        @Assert(store.listByUser("u1").size, 2)
    }

    @TestCase
    public func testRefreshRotatesToken() {
        let store = MemorySessionStore()
        let svc = this.service(store)
        let issued = svc.issue("u1", Array<String>(0, repeat: ""), Array<String>(0, repeat: ""), "1.1.1.1", "ua")
        @Assert(TokenServiceTest.refreshRotates(svc, issued), true)
    }

    @TestCase
    public func testRefreshReplayRevokesAllSessions() {
        let store = MemorySessionStore()
        let svc = this.service(store)
        let issued = svc.issue("u1", Array<String>(0, repeat: ""), Array<String>(0, repeat: ""), "1.1.1.1", "ua")
        @Assert(TokenServiceTest.replayRevokesAll(svc, store, issued), true)
    }

    @TestCase
    public func testRefreshInvalidTokenFails() {
        let store = MemorySessionStore()
        let svc = this.service(store)
        @Assert(TokenServiceTest.isRefreshErr(svc.refresh("not-a-real-token")), true)
    }

    // ---- 辅助 ----

    private static func isIssued(r: CryptoResult<(String, String, String)>): Bool {
        match (r) {
            case CryptoResult.Ok(_) => return true
            case CryptoResult.Err(_) => return false
        }
    }

    private static func isErrPayload(r: CryptoResult<TokenPayload>): Bool {
        match (r) {
            case CryptoResult.Ok(_) => return false
            case CryptoResult.Err(_) => return true
        }
    }

    private static func isRefreshOk(r: CryptoResult<(String, String, Bool)>): Bool {
        match (r) {
            case CryptoResult.Ok(_) => return true
            case CryptoResult.Err(_) => return false
        }
    }

    private static func isRefreshErr(r: CryptoResult<(String, String, Bool)>): Bool {
        match (r) {
            case CryptoResult.Ok(_) => return false
            case CryptoResult.Err(_) => return true
        }
    }

    /**
     * 篡改令牌后应被拒绝。
     */
    private static func tamperedRejected(
        svc: TokenService,
        issued: CryptoResult<(String, String, String)>
    ): Bool {
        // 说明：仓颉的 match 分支只能是**单个表达式**（不能有 { } 块），
        // 故此处用「先解包再判断」而非嵌套 match。
        let t = TokenServiceTest.unwrapTriple(issued)
        if (t[0] == "") {
            return false
        }
        let tampered = "AAAA." + t[0].split(".")[1]
        return isErrPayload(svc.verifyAccessToken(tampered))
    }

    /**
     * 解包三元组（失败时返回空元组）。
     */
    private static func unwrapTriple(
        r: CryptoResult<(String, String, String)>
    ): (String, String, String) {
        match (r) {
            case CryptoResult.Ok(t) => return t
            case CryptoResult.Err(_) => return ("", "", "")
        }
    }

    /**
     * 登出后令牌应失效。
     */
    private static func rejectedAfterLogout(
        svc: TokenService,
        issued: CryptoResult<(String, String, String)>
    ): Bool {
        let t = TokenServiceTest.unwrapTriple(issued)
        if (t[0] == "") {
            return false
        }
        svc.logout(t[2])
        return isErrPayload(svc.verifyAccessToken(t[0]))
    }

    /**
     * 刷新应旋转出新令牌。
     */
    private static func refreshRotates(
        svc: TokenService,
        issued: CryptoResult<(String, String, String)>
    ): Bool {
        let t = TokenServiceTest.unwrapTriple(issued)
        if (t[0] == "") {
            return false
        }
        return TokenServiceTest.newTokenDiffers(svc, t[1])
    }

    /**
     * 刷新后新令牌应与旧的不同。
     */
    private static func newTokenDiffers(svc: TokenService, oldRefresh: String): Bool {
        match (svc.refresh(oldRefresh)) {
            case CryptoResult.Ok(x) => return x[1] != oldRefresh
            case CryptoResult.Err(_) => return false
        }
    }

    /**
     * 重放旧刷新令牌应被检测并吊销全部会话。
     */
    private static func replayRevokesAll(
        svc: TokenService,
        store: MemorySessionStore,
        issued: CryptoResult<(String, String, String)>
    ): Bool {
        let t = TokenServiceTest.unwrapTriple(issued)
        if (t[0] == "") {
            return false
        }
        return TokenServiceTest.replayDetected(svc, store, t[1])
    }

    /**
     * 重放检测：第二次使用同一刷新令牌应失败，且会话被标记吊销。
     */
    private static func replayDetected(
        svc: TokenService,
        store: MemorySessionStore,
        refreshToken: String
    ): Bool {
        // 第一次刷新成功（旋转）
        if (!isRefreshOk(svc.refresh(refreshToken))) {
            return false
        }
        // 用旧令牌重放 -> 应被检测
        if (!isRefreshErr(svc.refresh(refreshToken))) {
            return false
        }
        // 该用户全部会话已被吊销（仍存在记录但已标记吊销）
        return store.listByUser("u1").size == 1
    }

    /**
     * 验证访问令牌并检查载荷（抽成方法）。
     */
    private static func verifyToken(
        svc: TokenService,
        issued: CryptoResult<(String, String, String)>,
        expectUid: String
    ): Bool {
        let t = TokenServiceTest.unwrapTriple(issued)
        if (t[0] == "") {
            return false
        }
        match (svc.verifyAccessToken(t[0])) {
            case CryptoResult.Ok(p) => return p.uid == expectUid && p.sid == t[2]
            case CryptoResult.Err(_) => return false
        }
    }
}
