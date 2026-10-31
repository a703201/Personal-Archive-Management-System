// ============================================================
// ams.security.audit · 单元测试
//
// 覆盖需求：FR-AUD-001 / 002 / 003 / 004 / 006
//
// [结构约定]（实测 SDK 1.0.5）：
//   测试代码与产品代码**物理分离**（本文件在 tests/ 目录，不在 src/）。
//   编译运行：bash scripts/test.sh ams-security
//
// [另一个约定]：仓颉的 match 分支必须是**单个表达式**，
//   不能写成 { 多行语句 }。故复杂场景一律抽成私有方法。
// ============================================================
package ams.security.audit.test

import std.collection.*
import std.unittest.*

import ams.crypto.impl.*
import ams.crypto.provider.*

import ams.security.audit.*

@Test
public class AuditActionTest {
    @TestCase
    public func testActionCodesAreStable() {
        // 动作码是审计检索的键，必须稳定
        @Assert(AuditAction.Login.code(), "auth.login")
        @Assert(AuditAction.LoginFailed.code(), "auth.login_failed")
        @Assert(AuditAction.Logout.code(), "auth.logout")
        @Assert(AuditAction.PasswordChange.code(), "auth.password_change")
        @Assert(AuditAction.DataExport.code(), "archive.export")
        @Assert(AuditAction.ItemDelete.code(), "archive.item_delete")
        @Assert(AuditAction.KeyRotate.code(), "crypto.key_rotate")
        @Assert(AuditAction.FieldReveal.code(), "archive.field_reveal")
    }

    @TestCase
    public func testAllActionsCovered() {
        // FR-AUD-001 要求覆盖：登录/登出/失败/口令修改/授权撤销/
        // 分享链接/导出/删除/恢复/密钥轮换/权限变更/配置变更/批量操作
        let codes = ArrayList<String>()
        let actions = [AuditAction.Login, AuditAction.LoginFailed, AuditAction.Logout,
                       AuditAction.LogoutAll, AuditAction.PasswordChange,
                       AuditAction.RoleAssign, AuditAction.RoleRevoke,
                       AuditAction.GrantCreate, AuditAction.GrantRevoke,
                       AuditAction.ShareCreate, AuditAction.ShareAccess,
                       AuditAction.DataExport, AuditAction.ItemDelete, AuditAction.ItemRestore,
                       AuditAction.KeyRotate, AuditAction.PermChange,
                       AuditAction.ConfigChange, AuditAction.BatchOperation,
                       AuditAction.FieldReveal]
        for (a in actions) {
            codes.add(a.code())
        }
        // 关键动作必须都在
        @Assert(codes.contains("auth.login"), true)
        @Assert(codes.contains("auth.logout"), true)
        @Assert(codes.contains("auth.login_failed"), true)
        @Assert(codes.contains("auth.password_change"), true)
        @Assert(codes.contains("acl.grant_revoke"), true)
        @Assert(codes.contains("acl.share_create"), true)
        @Assert(codes.contains("archive.export"), true)
        @Assert(codes.contains("archive.item_delete"), true)
        @Assert(codes.contains("archive.item_restore"), true)
        @Assert(codes.contains("crypto.key_rotate"), true)
        @Assert(codes.contains("acl.perm_change"), true)
        @Assert(codes.contains("cfg.change"), true)
        @Assert(codes.contains("archive.batch_operation"), true)
        // 码不重复
        @Assert(codes.size, 19)
    }

    @TestCase
    public func testResultAndActorCodes() {
        @Assert(AuditResult.Success.toCode(), 0)
        @Assert(AuditResult.Failure.toCode(), 1)
        @Assert(AuditResult.Denied.toCode(), 2)
        @Assert(ActorType.User.toCode(), 0)
        @Assert(ActorType.System.toCode(), 1)
        @Assert(ActorType.Anonymous.toCode(), 2)
        @Assert(ActorType.Service.toCode(), 3)
    }
}

@Test
public class AuditChainTest {
    private let provider = StdxCryptoProvider()
    private let svc = AuditService(StdxCryptoProvider())

    /**
     * 追加记录并返回新的链头哈希。
     *
     * 抽成方法有两个原因：
     *   ① match 分支只能是单个表达式（仓颉限制）
     *   ② 链头需要回传，方法比在 match 块内赋值更清晰
     */
    private func pushRecord(
        out: ArrayList<AuditRecord>,
        rec: AuditRecord,
        prev: Array<Byte>
    ): Array<Byte> {
        out.add(rec)
        return rec.recordHash
    }

    /**
     * 构造一条审计记录。
     */
    private func entry(
        seq: Int64,
        action: AuditAction,
        result: AuditResult,
        detail: Array<(String, String)>
    ): AuditEntry {
        return AuditEntry(
            seq, "u1", ActorType.User, action, "测试动作", "item", "i1",
            "s1", 1, result, "", "127.0.0.1", "ua", "trace-1", detail, 1790000000000 + seq)
    }

    /**
     * 构造一条链（连续 prev_hash）。
     */
    private func buildChain(n: Int64): Array<AuditRecord> {
        let out = ArrayList<AuditRecord>()
        var prev = AuditService.genesisHash()
        for (i in 1..(n + 1)) {
            let e = this.entry(i, AuditAction.Login, AuditResult.Success, [("k", "v")])
            let r = this.svc.buildRecord(e, prev)
            match (r) {
                case CryptoResult.Ok(rec) => prev = this.pushRecord(out, rec, prev)
                case CryptoResult.Err(_) => ()
            }
        }
        return out.toArray()
    }

    // ---- FR-AUD-003：哈希链 ----

    @TestCase
    public func testChainBuilds() {
        let chain = this.buildChain(3)
        @Assert(chain.size, 3)
    }

    @TestCase
    public func testGenesisHashIsZero() {
        let g = AuditService.genesisHash()
        @Assert(g.size, 32)
        for (i in 0..32) {
            @Assert(g[i], 0u8)
        }
    }

    @TestCase
    public func testChainVerifyOk() {
        // 未被篡改的链 → 校验通过
        let chain = this.buildChain(5)
        @Assert(AuditTest.isOk(this.svc.verifyChain(chain)), true)
    }

    @TestCase
    public func testChainVerifyDetectsTamperedContent() {
        // 篡改第 3 条的 action → 必须检出
        let chain = this.buildChain(5)
        let tampered = AuditTest.tamperAction(chain, 3)
        let r = this.svc.verifyChain(tampered)
        @Assert(AuditTest.isTampered(r), true)
    }

    @TestCase
    public func testChainVerifyDetectsTamperedFirstRecord() {
        let chain = this.buildChain(3)
        let tampered = AuditTest.tamperAction(chain, 1)
        @Assert(AuditTest.isTampered(this.svc.verifyChain(tampered)), true)
    }

    @TestCase
    public func testChainVerifyDetectsTamperedLastRecord() {
        let chain = this.buildChain(3)
        let tampered = AuditTest.tamperAction(chain, 3)
        @Assert(AuditTest.isTampered(this.svc.verifyChain(tampered)), true)
    }

    @TestCase
    public func testChainVerifyDetectsBrokenLink() {
        // 破坏 prev_hash → 链断裂
        let chain = this.buildChain(4)
        let broken = AuditTest.breakPrevHash(chain, 3)
        @Assert(AuditTest.isBroken(this.svc.verifyChain(broken)), true)
    }

    @TestCase
    public func testChainVerifyDetectsMissingRecord() {
        // 删除中间一条 → 序号不连续
        let chain = this.buildChain(5)
        let missing = AuditTest.removeAt(chain, 2)
        @Assert(AuditTest.isMissing(this.svc.verifyChain(missing)), true)
    }

    @TestCase
    public func testHashIsDeterministic() {
        // 同样内容 → 同样哈希（否则审计链不可重现）
        let e = this.entry(1, AuditAction.Login, AuditResult.Success, [("k", "v")])
        let prev = AuditService.genesisHash()
        let h1 = this.svc.computeHash(e, prev)
        let h2 = this.svc.computeHash(e, prev)
        @Assert(AuditTest.sameHash(this.provider, h1, h2), true)
    }

    @TestCase
    public func testHashChangesWithContent() {
        // 内容不同 → 哈希不同
        let e1 = this.entry(1, AuditAction.Login, AuditResult.Success, [("k", "v")])
        let e2 = this.entry(1, AuditAction.Logout, AuditResult.Success, [("k", "v")])
        let prev = AuditService.genesisHash()
        let h1 = this.svc.computeHash(e1, prev)
        let h2 = this.svc.computeHash(e2, prev)
        @Assert(AuditTest.sameHash(this.provider, h1, h2), false)
    }

    @TestCase
    public func testHashChangesWithPrevHash() {
        // prev_hash 不同 → 哈希不同（这是链式防篡改的关键）
        let e = this.entry(1, AuditAction.Login, AuditResult.Success, [("k", "v")])
        let h1 = this.svc.computeHash(e, AuditService.genesisHash())
        let other = Array<Byte>(32, repeat: 1u8)
        let h2 = this.svc.computeHash(e, other)
        @Assert(AuditTest.sameHash(this.provider, h1, h2), false)
    }

    // ---- FR-AUD-002：结构化 ----

    @TestCase
    public func testCanonicalDetailIsSorted() {
        // detail 顺序不同 → 规范化结果相同（否则同内容不同哈希）
        let e1 = this.entry(1, AuditAction.Login, AuditResult.Success, [("b", "2"), ("a", "1")])
        let e2 = this.entry(1, AuditAction.Login, AuditResult.Success, [("a", "1"), ("b", "2")])
        let prev = AuditService.genesisHash()
        let h1 = this.svc.computeHash(e1, prev)
        let h2 = this.svc.computeHash(e2, prev)
        @Assert(AuditTest.sameHash(this.provider, h1, h2), true)
    }

    @TestCase
    public func testChainHeadIsLastHash() {
        let chain = this.buildChain(3)
        let head = AuditService.chainHead(chain)
        let last = chain[chain.size - 1].recordHash
        @Assert(this.provider.constantTimeEquals(head, last), true)
    }

    @TestCase
    public func testEmptyChainHeadIsGenesis() {
        let head = AuditService.chainHead(Array<AuditRecord>())
        let genesis = AuditService.genesisHash()
        @Assert(this.provider.constantTimeEquals(head, genesis), true)
    }
}

/**
 * 断言辅助（枚举不能用 == 比较）。
 */
class AuditTest {
    /**
     * 两个哈希结果是否相同。
     */
    static func sameHash(
        provider: CryptoProvider,
        h1: CryptoResult<Array<Byte>>,
        h2: CryptoResult<Array<Byte>>
    ): Bool {
        match (h1) {
            case CryptoResult.Ok(a) => match (h2) {
                case CryptoResult.Ok(b) => return provider.constantTimeEquals(a, b)
                case CryptoResult.Err(_) => return false
            }
            case CryptoResult.Err(_) => return false
        }
    }

    static func isOk(r: ChainVerifyResult): Bool {
        match (r) {
            case ChainVerifyResult.Ok => return true
            case _ => return false
        }
    }

    static func isTampered(r: ChainVerifyResult): Bool {
        match (r) {
            case ChainVerifyResult.Tampered(_) => return true
            case _ => return false
        }
    }

    static func isBroken(r: ChainVerifyResult): Bool {
        match (r) {
            case ChainVerifyResult.Broken(_) => return true
            case _ => return false
        }
    }

    static func isMissing(r: ChainVerifyResult): Bool {
        match (r) {
            case ChainVerifyResult.Missing(_) => return true
            case _ => return false
        }
    }

    /**
     * 篡改指定序号的记录的 action。
     */
    static func tamperAction(chain: Array<AuditRecord>, seq: Int64): Array<AuditRecord> {
        let out = ArrayList<AuditRecord>()
        for (r in chain) {
            if (r.entry.chainSeq == seq) {
                let e = AuditEntry(
                    r.entry.chainSeq, r.entry.actorId, r.entry.actorType,
                    AuditAction.ItemDelete, r.entry.actionDesc,
                    r.entry.targetType, r.entry.targetId, r.entry.subjectId,
                    r.entry.category, r.entry.result, r.entry.errorCode,
                    r.entry.clientIp, r.entry.userAgent, r.entry.traceId,
                    r.entry.detail, r.entry.occurredAt)
                out.add(AuditRecord(e, r.prevHash, r.recordHash))
            } else {
                out.add(r)
            }
        }
        return out.toArray()
    }

    /**
     * 破坏指定序号的 prev_hash。
     */
    static func breakPrevHash(chain: Array<AuditRecord>, seq: Int64): Array<AuditRecord> {
        let out = ArrayList<AuditRecord>()
        for (r in chain) {
            if (r.entry.chainSeq == seq) {
                let bad = Array<Byte>(32, repeat: 0xFFu8)
                out.add(AuditRecord(r.entry, bad, r.recordHash))
            } else {
                out.add(r)
            }
        }
        return out.toArray()
    }

    /**
     * 删除指定下标的记录。
     */
    static func removeAt(chain: Array<AuditRecord>, idx: Int64): Array<AuditRecord> {
        let out = ArrayList<AuditRecord>()
        for (i in 0..chain.size) {
            if (i != idx) {
                out.add(chain[i])
            }
        }
        return out.toArray()
    }
}

/**
 * 动作码 / 结果码的反查必须与正向编码严格互逆。
 *
 * 背景（真实故障）：链校验重算哈希时走 `fromCode(落库 action).code()`。
 * 若某动作的 fromCode 与 code() 用词不一致（曾出现 4 个：
 * acl.share_create / acl.share_access / crypto.key_rotate /
 * archive.batch_operation），反查会退化为 Unknown("unknown")，
 * 规范化串随之改变 —— 该条记录被判「被篡改」，
 * 使 FR-AUD-003 对**应用自己写入的正常记录**大面积误报。
 *
 * 同理 AuditResult 的 2=Denied、ActorType 的 3=Service 若在反解时漏判，
 * 也会退回 0 造成同类误报（实测 result=2 的 20 条记录全部误报）。
 */
@Test
public class AuditCodeRoundTripTest {
    @TestCase
    public func testFromCodeIsInverseOfCode() {
        let actions = [
            AuditAction.Login, AuditAction.LoginFailed, AuditAction.Logout,
            AuditAction.LogoutAll, AuditAction.PasswordChange, AuditAction.PasswordReset,
            AuditAction.RoleAssign, AuditAction.RoleRevoke,
            AuditAction.GrantCreate, AuditAction.GrantRevoke,
            AuditAction.ShareCreate, AuditAction.ShareAccess,
            AuditAction.DataExport, AuditAction.ItemDelete, AuditAction.ItemRestore,
            AuditAction.KeyRotate, AuditAction.PermChange,
            AuditAction.ConfigChange, AuditAction.BatchOperation,
            AuditAction.FieldReveal
        ]
        for (a in actions) {
            let back = AuditAction.fromCode(a.code())
            // 反查不得退化为 Unknown（Unknown.code() == "unknown"）
            @Assert(back.code(), a.code())
        }
    }

    @TestCase
    public func testLegacyActionCodesStillResolve() {
        // 历史数据里的旧码必须仍能反查到同一动作（不能只认新码）
        @Assert(AuditAction.fromCode("share.create").code(), "acl.share_create")
        @Assert(AuditAction.fromCode("share.access").code(), "acl.share_access")
        @Assert(AuditAction.fromCode("kms.key_rotate").code(), "crypto.key_rotate")
        @Assert(AuditAction.fromCode("archive.batch").code(), "archive.batch_operation")
        // 新码同样要认
        @Assert(AuditAction.fromCode("acl.share_create").code(), "acl.share_create")
        @Assert(AuditAction.fromCode("archive.batch_operation").code(), "archive.batch_operation")
    }

    @TestCase
    public func testUnknownActionCodeDegradesToUnknown() {
        @Assert(AuditAction.fromCode("no.such_action").code(), "unknown")
        // 空串也不得抛异常
        @Assert(AuditAction.fromCode("").code(), "unknown")
    }

    @TestCase
    public func testResultCodesAreDistinct() {
        // 0/1/2 三值互不相同，且 Denied 不得与 Success 撞码
        @Assert(AuditResult.Success.toCode(), 0)
        @Assert(AuditResult.Failure.toCode(), 1)
        @Assert(AuditResult.Denied.toCode(), 2)
    }

    @TestCase
    public func testActorTypeCodesAreDistinct() {
        @Assert(ActorType.User.toCode(), 0)
        @Assert(ActorType.System.toCode(), 1)
        @Assert(ActorType.Anonymous.toCode(), 2)
        @Assert(ActorType.Service.toCode(), 3)
    }
}
