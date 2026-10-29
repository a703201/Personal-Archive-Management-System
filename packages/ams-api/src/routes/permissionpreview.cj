// ============================================================
// ams.api.routes.permissionpreview · 权限预览（FR-ACL-013 · 方案 A）
//
// 需求：以某角色登录「可见哪些数据」的模拟视图（仅机构管理员）。
//
// 为什么要做：RBAC 配好后，管理员只能靠「找人试一下」验证效果 ——
// 角色少还好，一旦有 5+ 角色互相组合，靠猜根本不可靠。
//
// 方案 A 的边界（刻意保守）：
//   · 只返回**统计口径**（可见条目数 / 分类分布 / 数据可见上限），
//     **不返回任何条目内容** —— 预览不是「越权浏览」的后门；
//   · 角色本身不带主体授权（主体是 per-user 的），故：
//       - 角色含 archive:read:any → 按「全机构主体」统计；
//       - 否则默认「仅本人范围」，不猜任何人的主体集合；
//       - 可选 ?userId= 精确到某个人（用其真实可访问主体计算）。
//   · 可见性口径与列表页一致：可访问主体内 + sensitivity <= maxDataLevel。
//
// 权限：acl:manage（角色与权限的管理者才需要看预览）
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.data.repo.*
import ams.kernel.error.*

/**
 * 权限预览接口。
 */
public class PermissionPreviewRoutes {
    private let roleRepo: RoleRepo
    private let userRepo: UserRepo
    private let itemRepo: ItemRepo
    private let subjectRepo: SubjectRepo

    public init(
        roleRepo: RoleRepo,
        userRepo: UserRepo,
        itemRepo: ItemRepo,
        subjectRepo: SubjectRepo
    ) {
        this.roleRepo = roleRepo
        this.userRepo = userRepo
        this.itemRepo = itemRepo
        this.subjectRepo = subjectRepo
    }

    public func register(router: Router): Unit {
        router.get("/api/admin/permission-preview",
            { req: ApiRequest => this.preview(req) },
            requiredPerm: "acl:manage")
    }

    /**
     * GET /api/admin/permission-preview?role=<code>[&userId=<id>]
     */
    private func preview(req: ApiRequest): ApiResponse {
        let roleCode = (req.queryParam("role") ?? "").trimAscii()
        if (roleCode.isEmpty()) {
            throw validationError("role", "缺少角色编码")
        }
        // 角色元数据（名称 / 数据可见上限）
        var roleName = ""
        var maxLevel: Int64 = 1
        var found = false
        for (r in this.roleRepo.listRoles().all().iterator()) {
            if (r.str("code") == roleCode) {
                roleName = r.str("name")
                maxLevel = r.i64("max_data_level")
                found = true
                break
            }
        }
        if (!found) {
            throw notFound("角色")
        }
        if (maxLevel < 1) {
            maxLevel = 1
        }
        if (maxLevel > 3) {
            maxLevel = 3
        }

        let perms = this.roleRepo.listRolePermCodes(roleCode)
        var scopeAny = false
        for (p in perms) {
            if (p == "archive:read:any" || p == "archive:write:any") {
                scopeAny = true
            }
        }

        // 主体范围：可选 userId 精确到人；否则按角色声明的范围取
        let userIdRaw = req.queryParam("userId") ?? ""
        let userId = RowData.toI64(userIdRaw)
        var subjectIds = ArrayList<String>()
        var scopeText = "own"
        if (userId > 0) {
            // 以「该用户的真实可访问主体」为口径（最接近真实登录效果）
            subjectIds = this.userRepo.listAccessibleSubjectIds(userId)
            scopeText = "user:${userId}"
        } else if (scopeAny) {
            subjectIds = this.subjectRepo.listAllIds()
            scopeText = "any"
        }

        let arr = subjectIds.toArray()
        let visibleCount = this.itemRepo.countVisible(arr, maxLevel)
        let cats = this.itemRepo.countVisibleByCategory(arr, maxLevel)
        let userCount = this.roleRepo.countUsersByRole(roleCode)

        let sb = StringBuilder()
        sb.append("{\"role\":{\"code\":\"${ApiResponse.escape(roleCode)}\",")
        sb.append("\"name\":\"${ApiResponse.escape(roleName)}\",")
        sb.append("\"maxDataLevel\":${maxLevel}},")
        sb.append("\"scope\":\"${scopeText}\",")
        sb.append("\"userCount\":${userCount},")
        sb.append("\"subjectCount\":${subjectIds.size},")
        sb.append("\"visibleItemCount\":${visibleCount},")
        sb.append("\"perms\":[")
        var first = true
        for (p in perms) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("\"${ApiResponse.escape(p)}\"")
        }
        sb.append("],\"categories\":[")
        var firstCat = true
        for (r in cats.all().iterator()) {
            if (!firstCat) {
                sb.append(",")
            }
            firstCat = false
            sb.append("{\"category\":${r.i64("category")},\"count\":${r.i64("n")}}")
        }
        sb.append("],\"fields\":{\"maxDataLevel\":${maxLevel},")
        sb.append("\"visibleLevels\":[")
        var firstLv = true
        for (lv in 1..(maxLevel + 1)) {
            if (!firstLv) {
                sb.append(",")
            }
            firstLv = false
            sb.append("${lv}")
        }
        sb.append("],\"maskedLevels\":[")
        var firstMask = true
        for (lv in (maxLevel + 1)..4) {
            if (!firstMask) {
                sb.append(",")
            }
            firstMask = false
            sb.append("${lv}")
        }
        sb.append("],\"policy\":\"敏感度不超过 ${maxLevel} 的字段可见；更高敏感度的字段在列表/详情中掩码，明文需显式授权并留痕\"},")
        sb.append("\"note\":\"本预览只做统计，不返回任何条目内容；角色不含全机构范围时默认只统计本人范围，可用 userId 精确到某个用户\"}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }
}
