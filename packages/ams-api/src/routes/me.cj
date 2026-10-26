// ============================================================
// ams.api.routes.me · 个人中心与概览接口
//
// 覆盖 FR-UX-001（个人主页与概览）：
//   GET /api/me        当前登录者档案（不含任何凭据字段）
//   GET /api/overview  概览统计（总数 / 分类分布 / 最近更新 / 待处理提醒）
//
// 【为什么单独开这个文件】
//   这两个端点是前端首屏就要用的「用户态」接口，与既有 management.cj
//   （管理员视角的用户管理）语义不同，混在一起容易误用管理权限。
//
// 【安全约束】
//   ① /api/me **绝不返回** passwordHash / kdfCost 等凭据字段
//   ② /api/overview 的统计一律按**服务端算出的可访问主体**过滤（FR-ACL-006），
//      不统计他人数据
//   ③ 邮箱与手机号按敏感度掩码返回（FR-SRC-006 的掩码策略一以贯之）
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.core.search.*
import ams.data.repo.*
import ams.kernel.error.*

/**
 * 个人中心与概览接口。
 */
public class MeRoutes {
    private let userRepo: UserRepo
    private let itemRepo: ItemRepo
    private let notifyRepo: NotifyRepo

    public init(userRepo: UserRepo, itemRepo: ItemRepo, notifyRepo: NotifyRepo) {
        this.userRepo = userRepo
        this.itemRepo = itemRepo
        this.notifyRepo = notifyRepo
    }

    public func register(router: Router): Unit {
        // 两个端点只需登录 + 基础档案读权限即可访问自己的数据
        router.get("/api/me", { req: ApiRequest => this.me(req) },
                   requiredPerm: "archive:read:own")
        router.get("/api/overview", { req: ApiRequest => this.overview(req) },
                   requiredPerm: "archive:read:own")
    }

    // ---------------------------------------------------------

    /**
     * GET /api/me —— 当前登录者档案。
     *
     * 只需登录即可（能过鉴权中间件就说明令牌有效），不再要求额外权限点。
     */
    private func me(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let rec = match (this.userRepo.findById(uid)) {
            case Some(u) => u
            case None => throw notFound("用户")
        }
        let sb = StringBuilder()
        sb.append("{\"id\":${rec.id},")
        sb.append("\"username\":\"${ApiResponse.escape(rec.username)}\",")
        sb.append("\"nickname\":\"${ApiResponse.escape(rec.nickname)}\",")
        // 邮箱/手机号掩码：概览类接口不返回完整联系方式
        sb.append("\"email\":\"${ApiResponse.escape(Masker.mask(rec.email, 2))}\",")
        sb.append("\"phone\":\"${ApiResponse.escape(Masker.maskPhone(rec.phone))}\",")
        sb.append("\"status\":${rec.status},")
        sb.append("\"perms\":[")
        var first = true
        for (p in req.perms) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("\"${ApiResponse.escape(p)}\"")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * GET /api/overview —— 概览统计。
     */
    private func overview(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let subjects = this.userRepo.listAccessibleSubjectIds(uid).toArray()

        let total = this.itemRepo.count(subjects, 0, -1, "")

        // 分类分布：11 个内置分类逐个计数（数据量小，直接查即可）
        let sb = StringBuilder()
        sb.append("{\"total\":${total},\"categories\":[")
        var first = true
        var c: Int64 = 1
        while (c <= 11) {
            let n = this.itemRepo.count(subjects, c, -1, "")
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"category\":${c},\"count\":${n}}")
            c = c + 1
        }
        sb.append("],")

        // 最近更新（取前 5 条，按更新时间倒序）
        let recent = this.itemRepo.list(subjects, 0, -1, "", 5, 0)
        sb.append("\"recent\":[")
        var rf = true
        for (r in recent.all().iterator()) {
            if (!rf) {
                sb.append(",")
            }
            rf = false
            sb.append("{\"id\":${r.i64("id")},")
            sb.append("\"category\":${r.i64("category")},")
            sb.append("\"title\":\"${ApiResponse.escape(r.str("title"))}\",")
            sb.append("\"updatedAt\":${r.i64("updated_ms")}}")
        }
        sb.append("],")

        // 待处理提醒：未读通知数
        let unread = this.notifyRepo.unreadCount(uid)
        sb.append("\"unreadNotifications\":${unread}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }
}
