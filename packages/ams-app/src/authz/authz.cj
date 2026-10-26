// ============================================================
// ams.app.authz · 授权应用服务
//
// 职责（FR-ACL-005/006/007/008/009 的接线层）：
//   - 组装 AccessContext（权限点 + 可访问主体 + 数据可见上限）
//   - 加载该用户的临时授权，构造 Authorizer
//   - 对外提供统一的「资源级鉴权」入口
//
// 【为什么需要这一层】
//   Authorizer（ams-security）此前**实现了但从未被业务调用**：
//   敏感度分级（FR-ACL-007）与授权到期（FR-ACL-009）在真实请求中不生效。
//   本服务把「仓储查数 → 构造判定器 → 判定」串起来，
//   由 ams-api 的鉴权中间件调用。
//
// 依赖：ams.data.repo（查数）、ams.security.authz（判定）
// ============================================================
package ams.app.authz

import std.collection.*

import ams.data.repo.*
import ams.security.authz.*

/**
 * 授权服务。
 */
public class AuthzService {
    private let userRepo: UserRepo
    private let roleRepo: RoleRepo

    public init(userRepo: UserRepo, roleRepo: RoleRepo) {
        this.userRepo = userRepo
        this.roleRepo = roleRepo
    }

    /**
     * 载入用户的可访问范围。
     *
     * @param userId 用户 ID（字符串形式，雪花 ID）
     */
    public func loadAccess(userId: String): AccessContext {
        let uid = UserRepo.parseId(userId)
        // 权限点与角色码由 RoleRepo 提供（经 sys_user_roles → sys_roles → sys_role_perms 关联）
        let perms = this.roleRepo.listUserPermCodes(uid)
        let roles = this.roleRepo.listUserRoleCodes(uid)
        let subjects = this.userRepo.listAccessibleSubjectIds(uid)
        let owned = this.userRepo.listOwnedSubjectIds(uid)
        let level = this.userRepo.maxDataLevel(uid)
        return AccessContext(userId, perms.toArray(), subjects.toArray(), level,
                             ownedSubjectIds: owned.toArray())
    }

    /**
     * 构造该用户的授权判定器（含其收到的全部临时授权）。
     *
     * 授权记录**包含已撤销与已过期的** —— 有效期判定在每次请求时做
     * （FR-ACL-009：到期自动失效由服务端校验，不依赖定时任务）。
     */
    public func loadAuthorizer(userId: String): Authorizer {
        let uid = UserRepo.parseId(userId)
        let rows = this.userRepo.listGrantsForUser(uid)
        let grants = ArrayList<Grant>()
        for (r in rows.all().iterator()) {
            grants.add(this.toGrant(r))
        }
        return Authorizer(grants.toArray())
    }

    /**
     * 行记录 → Grant。
     */
    private func toGrant(r: RowData): Grant {
        let perms = ArrayList<String>()
        let raw = r.str("perm_codes")
        if (!raw.isEmpty()) {
            for (p in raw.split(",")) {
                let t = p.trimStart().trimEnd()
                if (!t.isEmpty()) {
                    perms.add(t)
                }
            }
        }
        let itemId = r.getOpt("item_id") ?? ""
        return Grant(
            "${r.i64("granted_by")}",
            "${r.i64("grantee_id")}",
            "${r.i64("subject_id")}",
            perms.toArray(),
            itemId,
            r.i64("category"),
            r.i64("expires_ms"),
            r.i64("revoked_ms")
        )
    }
}
