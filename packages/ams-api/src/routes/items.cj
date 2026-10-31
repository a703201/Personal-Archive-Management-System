// ============================================================
// ams.api.routes.items · 档案条目接口
//
// 覆盖 FR-ARCH-001 ~ FR-ARCH-008：
//   GET    /api/items                 列表（按归属 + 分类 + 状态 + 关键字）
//   POST   /api/items                 创建
//   GET    /api/items/:id             详情
//   PUT    /api/items/:id             更新（带乐观锁）
//   POST   /api/items/:id/status      状态流转
//   DELETE /api/items/:id             软删除（进回收站）
//   GET    /api/items/recycle-bin     回收站列表
//   POST   /api/items/:id/restore     从回收站恢复
//
// 【资源级鉴权】
//   本模块的每条**涉及具体条目**的路由都挂了 guard，
//   由鉴权中间件执行对象级判定（FR-ACL-006/007/008/009）：
//     - 数据归属：条目必须属于调用者可访问的主体
//     - 敏感度分级：high 分类需显式授权
//     - 显式授权与有效期：临时授权在服务端判定是否仍有效
//   guard 返回的 AuthzResource 由**服务端查库**得到，
//   前端无法伪造归属（FR-ACL-006）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.search.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.security.authz.*

/**
 * 条目接口。
 *
 * 【检索索引接线】
 *   searchService 可选注入：条目创建 / 更新后同步重建 arc_search_index。
 *   此前 indexItem() 有实现但**零调用点**，GIN tokens 索引恒为空，
 *   导致 /api/search 的关键词检索永远命中不了结果（FR-SRC-001 形同虚设）。
 *   索引失败**不阻断**主流程（条目已落库，索引可后续重建），只记日志。
 */
public class ItemRoutes {
    private let itemRepo: ItemRepo
    private let userRepo: UserRepo
    private let searchService: ?SearchService
    private let versionRepo: ?ItemVersionRepo
    /**
     * 标签仓储（可选）。
     *
     * 只有「批量编辑（FR-ARCH-013）」的打标动作需要它：给已有的构造器
     * 加必填参数会牵动所有调用点（含测试），而批量打标是**可选能力** ——
     * 未注入时该字段的编辑照常工作，只是打标会被跳过并如实返回 0。
     */
    private let tagRepo: ?TagRepo

    public init(
        itemRepo: ItemRepo,
        userRepo: UserRepo,
        versionRepo!: ?ItemVersionRepo = None,
        searchService!: ?SearchService = None,
        tagRepo!: ?TagRepo = None
    ) {
        this.itemRepo = itemRepo
        this.userRepo = userRepo
        this.versionRepo = versionRepo
        this.searchService = searchService
        this.tagRepo = tagRepo
    }

    /**
     * 重建检索索引（尽力而为，失败仅记日志）。
     */
    private func reindex(itemId: Int64): Unit {
        match (this.searchService) {
            case Some(svc) =>
                try {
                    svc.indexItem(itemId)
                } catch (e: Exception) {
                    Log.get().warn("search.index.failed", None, [
                        ("itemId", "${itemId}"),
                        ("reason", e.toString())
                    ])
                }
            case None => ()
        }
    }

    /**
     * 注册路由。
     */
    public func register(router: Router): Unit {
        router.get("/api/items", { req: ApiRequest => this.listItems(req) },
                   requiredPerm: "archive:read:own")
        router.post("/api/items", { req: ApiRequest => this.createItem(req) },
                    requiredPerm: "archive:write:own")
        router.get("/api/items/recycle-bin", { req: ApiRequest => this.listRecycleBin(req) },
                   requiredPerm: "archive:read:own")
        router.get("/api/items/timeline", { req: ApiRequest => this.timeline(req) },
                   requiredPerm: "archive:read:own")
        router.get("/api/items/:id", { req: ApiRequest => this.getItem(req) },
                   requiredPerm: "archive:read:own",
                   guard: { req: ApiRequest => this.guardOf(req) })
        router.put("/api/items/:id", { req: ApiRequest => this.updateItem(req) },
                   requiredPerm: "archive:write:own",
                   guard: { req: ApiRequest => this.guardOf(req) })
        router.post("/api/items/:id/status", { req: ApiRequest => this.transitionItem(req) },
                    requiredPerm: "archive:write:own",
                    guard: { req: ApiRequest => this.guardOf(req) })
        router.delete("/api/items/:id", { req: ApiRequest => this.deleteItem(req) },
                     requiredPerm: "archive:delete:own",
                     guard: { req: ApiRequest => this.guardOf(req) })
        router.post("/api/items/:id/restore", { req: ApiRequest => this.restoreItem(req) },
                     requiredPerm: "archive:write:own",
                     guard: { req: ApiRequest => this.guardOf(req) })
        router.post("/api/items/:id/clone", { req: ApiRequest => this.cloneItem(req) },
                     requiredPerm: "archive:write:own",
                     guard: { req: ApiRequest => this.guardOf(req) })
        // FR-ARCH-011 历史版本：列表 + 回滚（对象级鉴权同条目）
        router.get("/api/items/:id/versions", { req: ApiRequest => this.listVersions(req) },
                   requiredPerm: "archive:read:own",
                   guard: { req: ApiRequest => this.guardOf(req) })
        router.post("/api/items/:id/versions/:vid/restore", { req: ApiRequest => this.restoreVersion(req) },
                    requiredPerm: "archive:write:own",
                    guard: { req: ApiRequest => this.guardOf(req) })
        // FR-ARCH-013 批量编辑：一次改多个条目的分类 / 有效期 / 标签。
        // 段数与 /api/items/:id/xxx 相同（4 段），但第 3 段是字面量 batch，
        // 不会与参数化路由冲突。
        router.post("/api/items/batch/edit", { req: ApiRequest => this.batchEdit(req) },
                    requiredPerm: "archive:write:own")
    }

    /**
     * 批量编辑（FR-ARCH-013）。
     *
     * 请求体：`{"ids":["1","2"],"category":5,"expiresAt":"2027-01-01","tagIds":["9"]}`
     * 三个字段都可省略（**打补丁**语义，不传的字段保持原值）。
     *
     * 【为什么不做「全量替换」】
     *   批量操作的输入来自勾选列表，用户往往只想改其中一项；
     *   用缺省值覆盖未填字段等于静默破坏数据 —— 这类缺陷在批量场景下
     *   一次就能毁掉几十条记录。
     *
     * 【为什么不算对象级 guard】
     *   本路由的 WHERE 里带了「可访问主体集合」，越权条目**根本不会被更新**，
     *   返回的实际行数与请求行数不一致就是信号；逐个条目跑 guard
     *   需要先把所有条目查出来，对批量场景是纯粹的浪费。
     */
    private func batchEdit(req: ApiRequest): ApiResponse {
        let json = ItemRoutes.body(req)
        let rawIds = ItemRoutes.strList(json, "ids")
        if (rawIds.isEmpty()) {
            throw validationError("ids", "请至少选择一个条目")
        }
        let ids = ArrayList<Int64>()
        for (s in rawIds) {
            let v = RowData.toI64(s)
            if (v > 0) {
                ids.add(v)
            }
        }
        if (ids.isEmpty()) {
            throw validationError("ids", "条目 ID 列表无效")
        }
        if (ids.size > 200) {
            throw validationError("ids", "单次最多编辑 200 条")
        }
        // 分类：给了就校验范围（与导入一致，1-11）
        var category: Option<Int64> = None
        let catRaw = json.get("category") ?? ""
        if (!catRaw.isEmpty()) {
            let c = RowData.toI64(catRaw)
            if (c < 1 || c > 11) {
                throw validationError("category", "分类必须是 1-11 的数字")
            }
            category = Some<Int64>(c)
        }
        // 有效期：给了就校验格式（YYYY-MM-DD，允许空串表示清除）
        var expiresAt: Option<String> = None
        match (json.get("expiresAt")) {
            case Some(v) =>
                if (!v.isEmpty() && !ItemRoutes.isDate(v)) {
                    throw validationError("expiresAt", "有效期格式应为 YYYY-MM-DD")
                }
                expiresAt = Some<String>(v)
            case None => ()
        }
        let subjects = this.accessibleSubjects(req)
        let updated = this.itemRepo.batchEdit(
            subjects,
            ids.toArray(),
            category,
            expiresAt,
            UserRepo.parseId(req.subjectId)
        )
        // 重建索引：批量改分类后，索引里的分类与 tokens 需要跟上
        for (id in ids) {
            this.reindex(id)
        }
        // 打标（可选能力）
        var tagged: Int64 = 0
        let tagIds = ItemRoutes.strList(json, "tagIds")
        if (!tagIds.isEmpty()) {
            match (this.tagRepo) {
                case Some(tr) =>
                    for (t in tagIds) {
                        let tid = RowData.toI64(t)
                        if (tid > 0) {
                            tagged = tagged + tr.attachMany(tid, ids.toArray())
                        }
                    }
                case None => ()
            }
        }
        return ApiResponse.ok(
            "{\"requested\":${ids.size},\"updated\":${updated},\"tagged\":${tagged}}",
            req.requestId
        )
    }

    /**
     * 从扁平 JSON 里取字符串数组（用于批量接口的 id / tagId 列表）。
     *
     * `SimpleJson` 只解析一层键值，数组值拿到的是**原始 token**
     * （如 `["1","2"]`）。这里去掉方括号、引号与空白后按逗号切分：
     * 元素只会是数字 ID，不会出现「逗号在值内部」的情况，
     * 因此不必为一个 ID 列表引入完整 JSON 解析器。
     */
    private static func strList(json: SimpleJson, key: String): Array<String> {
        let raw = json.get(key) ?? ""
        if (raw.isEmpty()) {
            return Array<String>()
        }
        let out = ArrayList<String>()
        for (part in raw.split(",")) {
            let sb = StringBuilder()
            for (r in part.runes()) {
                if (r == r'[' || r == r']' || r == r'"' || r == r'\'' || r == r' ') {
                    continue
                }
                sb.append(r.toString())
            }
            let v = sb.toString()
            if (!v.isEmpty()) {
                out.add(v)
            }
        }
        return out.toArray()
    }

    /**
     * 是否为 `YYYY-MM-DD` 形式（只做形状检查，不做日历合法性检查 ——
     * 真正的合法性由数据库类型转换把关，前端已用日期控件）。
     */
    private static func isDate(s: String): Bool {
        let b = s.toArray()
        if (b.size != 10) {
            return false
        }
        var i: Int64 = 0
        while (i < 10) {
            if (i == 4 || i == 7) {
                if (b[i] != 45u8) {      // '-'
                    return false
                }
            } else if (b[i] < 48u8 || b[i] > 57u8) {
                return false
            }
            i = i + 1
        }
        return true
    }

    // ---------------------------------------------------------------
    // 资源守卫
    // ---------------------------------------------------------------

    /**
     * 解析本请求涉及的条目，构造资源描述供鉴权中间件判定。
     *
     * 查不到条目时返回 None —— 此时只做功能权限判定，
     * 由业务处理器返回 404（不泄露资源存在性）。
     */
    private func guardOf(req: ApiRequest): Option<AuthzResource> {
        let idStr = req.pathParam("id") ?? ""
        if (idStr.isEmpty()) {
            return None
        }
        let id = UserRepo.parseId(idStr)
        // ⚠️ 这里**必须**用不过滤归属的查询：
        //   归属与显式授权的判定由 Authorizer 负责（它同时看
        //   「可访问主体集合」与「acl_grants 显式授权」）。
        //   若这里先按归属过滤，被显式授权的用户会在这里就查不到 →
        //   guard 返回 None → 跳过判定 → 404，
        //   于是 FR-ACL-008（临时授权）端到端不通。
        let rec = this.itemRepo.findByIdRaw(id)
        match (rec) {
            case Some(r) => return Some(AuthzResource(
                r.subjectId,
                r.category,
                ItemRoutes.toSensitivity(r.sensitivity),
                itemId: r.id,
                tenantId: r.tenantId
            ))
            case None => return None
        }
    }

    /**
     * 调用者可访问的主体 ID 集合（服务端算出）。
     */
    private func accessibleSubjects(req: ApiRequest): Array<String> {
        let uid = UserRepo.parseId(req.subjectId)
        return this.userRepo.listAccessibleSubjectIds(uid).toArray()
    }

    /**
     * 按 ?subjectId 收窄可访问主体集合。
     *
     * 只在**已算出的可访问集合内**取交集 —— 传别人的 subjectId
     * 不会扩大可见范围：交集为空即空列表（FR-ACL-006：归属由服务端定）。
     */
    private static func narrow(subjects: Array<String>, want: String): Array<String> {
        if (want.isEmpty()) {
            return subjects
        }
        let out = ArrayList<String>()
        for (s in subjects) {
            if (s == want) {
                out.add(s)
            }
        }
        return out.toArray()
    }

    // ---------------------------------------------------------------
    // 处理器
    // ---------------------------------------------------------------

    /**
     * 列表。
     */
    private func listItems(req: ApiRequest): ApiResponse {
        let category = ItemRoutes.intOfQuery(req, "category", 0)
        let status = ItemRoutes.intOfQuery(req, "status", -1)
        let keyword = match (req.queryParam("keyword")) {
            case Some(v) => v
            case None => ""
        }
        // FR-SRC-010：来源系统筛选（0=不限）+ 创建时间范围
        let source = ItemRoutes.intOfQuery(req, "source", 0)
        let createdFrom = ItemRoutes.queryOrEmpty(req, "createdFrom")
        let createdTo = ItemRoutes.queryOrEmpty(req, "createdTo")
        let page = ItemRoutes.intOfQuery(req, "page", 1)
        let size = ItemRoutes.intOfQuery(req, "size", 20)
        if (size < 1 || size > 200) {
            throw validationError("size", "每页条数须在 1~200 之间")
        }
        // 支持按主体筛选（前端「档案」页的主体切换）：
        // 与服务端算出的可访问集合取交集，越权传参只会得到空结果。
        let wantSubject = match (req.queryParam("subjectId")) {
            case Some(v) => v
            case None => ""
        }
        let subjects = ItemRoutes.narrow(this.accessibleSubjects(req), wantSubject)
        // 家庭授权下推（FR-ACL-010 / docs/15 §6）：
        // 把「家人共享给我的条目」并入同一次查询，保证
        // **列表能看到 = 详情能打开**（此前详情已支持 FR-ACL-008 的
        // 单条授权，列表却只认自有主体，用户会以为共享没生效）。
        //
        // 两条约束：
        //   ① 只对读路径生效 —— 授权授予的是 `archive:read:own`，
        //      导出/写入仍需 `archive:export:*` / `archive:write:*`，
        //      没有对应权限的人在那些入口依旧拿不到数据（这是有意的）；
        //   ② 主体筛选走独立的 `subjectFilter` 形参，不能靠缩窄 subjects ——
        //      被授权分支与 subjectIds 是 OR 关系，缩窄只会让「自有」变小。
        let uid = UserRepo.parseId(req.subjectId)
        let rows = this.itemRepo.list(
            subjects, category, status, keyword, size, (page - 1) * size,
            source: source, createdFrom: createdFrom, createdTo: createdTo,
            granteeId: uid, subjectFilter: wantSubject
        )
        let total = this.itemRepo.count(
            subjects, category, status, keyword,
            source: source, createdFrom: createdFrom, createdTo: createdTo,
            granteeId: uid, subjectFilter: wantSubject
        )
        // 「自有主体」集合：不在其中的行来自家庭授权，打 shared 标记。
        let owned = HashSet<String>()
        for (s in subjects) {
            owned.add(s)
        }
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(ItemRoutes.toJson(r, !owned.contains(r.str("subject_id"))))
        }
        sb.append("],\"total\":${total},\"page\":${page},\"size\":${size}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 详情。
     */
    private func getItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let rec = this.itemRepo.findByIdRaw(UserRepo.parseId(idStr))
        match (rec) {
            case Some(r) =>
                let sb = StringBuilder()
                sb.append("{\"item\":")
                sb.append(ItemRoutes.toJsonOf(r))
                sb.append("}")
                return ApiResponse.ok(sb.toString(), req.requestId)
            case None => throw notFound("条目")
        }
    }

    /**
     * 创建。
     */
    private func createItem(req: ApiRequest): ApiResponse {
        let json = ItemRoutes.body(req)
        let title = json.get("title") ?? ""
        if (title.isEmpty()) {
            throw validationError("title", "标题不能为空")
        }
        let subjectIdStr = json.get("subjectId") ?? ""
        if (subjectIdStr.isEmpty()) {
            throw validationError("subjectId", "所属主体不能为空")
        }
        // 归属校验：创建时也要确认调用者可访问该主体
        let subjects = this.accessibleSubjects(req)
        var allowed = false
        for (s in subjects) {
            if (s == subjectIdStr) {
                allowed = true
            }
        }
        if (!allowed) {
            throw AppError(AppErrorKind.Forbidden, "无权限在该主体下创建条目")
        }
        let category = ItemRoutes.intOf(json, "category", 0)
        let sensitivity = ItemRoutes.intOf(json, "sensitivity", 1)
        let id = this.itemRepo.create(
            UserRepo.parseId(subjectIdStr),
            category,
            title,
            ItemRoutes.intOf(json, "status", 0),
            sensitivity,
            json.get("issuedDate") ?? "",
            json.get("expiresAt") ?? "",
            json.get("issuer") ?? "",
            json.get("remark") ?? "",
            json.get("extra") ?? "{}",
            req.tenantId,
            UserRepo.parseId(req.subjectId)
        )
        // 同步重建检索索引（失败不影响创建结果）
        this.reindex(id)
        return ApiResponse.ok("{\"id\":\"${id}\"}", req.requestId)
    }

    /**
     * 更新（带乐观锁）。
     */
    private func updateItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = UserRepo.parseId(idStr)
        let json = ItemRoutes.body(req)
        let expected = ItemRoutes.intOf(json, "version", -1)
        if (expected < 0) {
            throw validationError("version", "缺少版本号（乐观锁必填）")
        }
        let rec = this.itemRepo.findByIdRaw(id)
        match (rec) {
            case Some(r) => return this.doUpdate(req, id, expected, r, json)
            case None => throw notFound("条目")
        }
    }

    /**
     * 执行更新（乐观锁）。
     *
     * 独立成方法的原因：仓颉的 match 分支**必须是单个表达式**，
     * 不能写 { 多行语句 }（会被当作 lambda 体）。
     */
    private func doUpdate(
        req: ApiRequest,
        id: Int64,
        expected: Int64,
        r: ItemRecord,
        json: SimpleJson
    ): ApiResponse {
        // FR-ARCH-011：更新前留快照（幂等；写失败不阻断更新主流程）
        this.snapshotCurrent(id, r, UserRepo.parseId(req.subjectId))
        let ok = this.itemRepo.update(
            id,
            expected,
            UserRepo.parseId(r.subjectId),
            json.get("title") ?? r.title,
            ItemRoutes.intOf(json, "sensitivity", r.sensitivity),
            json.get("issuedDate") ?? r.issuedDate,
            json.get("expiresAt") ?? r.expiresAt,
            json.get("issuer") ?? r.issuer,
            json.get("remark") ?? r.remark,
            json.get("extra") ?? r.extraJson,
            UserRepo.parseId(req.subjectId)
        )
        if (!ok) {
            // 乐观锁失败 → 409 冲突（FR-ARCH-007），并说明当前版本
            throw ItemRoutes.conflict(r.version)
        }
        // 同步重建检索索引（失败不影响更新结果）
        this.reindex(id)
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    /**
     * 状态流转。
     */
    private func transitionItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = UserRepo.parseId(idStr)
        let json = ItemRoutes.body(req)
        let to = ItemRoutes.intOf(json, "status", -1)
        if (to < 0) {
            throw validationError("status", "目标状态不能为空")
        }
        let expected = ItemRoutes.intOf(json, "version", -1)
        if (expected < 0) {
            throw validationError("version", "缺少版本号（乐观锁必填）")
        }
        let rec = this.itemRepo.findByIdRaw(id)
        match (rec) {
            case Some(r) => return this.doTransition(req, id, expected, to, r)
            case None => throw notFound("条目")
        }
    }

    /**
     * 执行状态流转（乐观锁）。
     */
    private func doTransition(
        req: ApiRequest,
        id: Int64,
        expected: Int64,
        to: Int64,
        r: ItemRecord
    ): ApiResponse {
        let ok = this.itemRepo.transition(
            id, expected, to, UserRepo.parseId(r.subjectId), UserRepo.parseId(req.subjectId))
        if (!ok) {
            throw ItemRoutes.conflict(r.version)
        }
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    /**
     * 软删除。
     */
    private func deleteItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = UserRepo.parseId(idStr)
        let json = ItemRoutes.body(req)
        let expected = ItemRoutes.intOf(json, "version", -1)
        let rec = this.itemRepo.findByIdRaw(id)
        match (rec) {
            case Some(r) => return this.doDelete(req, id, expected, r)
            case None => throw notFound("条目")
        }
    }

    /**
     * 执行软删除（进回收站）。
     */
    private func doDelete(
        req: ApiRequest,
        id: Int64,
        expected: Int64,
        r: ItemRecord
    ): ApiResponse {
        let ok = this.itemRepo.softDelete(
            id, expected, UserRepo.parseId(r.subjectId), UserRepo.parseId(req.subjectId))
        if (!ok) {
            throw ItemRoutes.conflict(r.version)
        }
        return ApiResponse.ok("{\"deleted\":true}", req.requestId)
    }

    /**
     * 回收站列表。
     */
    private func listRecycleBin(req: ApiRequest): ApiResponse {
        let rows = this.itemRepo.listRecycleBin(this.accessibleSubjects(req))
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(ItemRoutes.toJson(r))
        }
        sb.append("],\"total\":${rows.size()}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 恢复。
     */
    private func restoreItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = UserRepo.parseId(idStr)
        // 恢复的归属以**条目自身**的 subject_id 为准
        // （已删除的条目不在 findById 结果里，故用 restore 内部的条件表达）
        let ok = this.itemRepo.restoreAny(
            id,
            this.accessibleSubjects(req),
            UserRepo.parseId(req.subjectId)
        )
        if (!ok) {
            throw notFound("条目")
        }
        return ApiResponse.ok("{\"restored\":true}", req.requestId)
    }

    /**
     * 克隆条目（FR-ARCH-009）：复制为新草稿，源引用记入 source。
     */
    private func cloneItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = UserRepo.parseId(idStr)
        let newId = this.itemRepo.cloneItem(id, req.tenantId, UserRepo.parseId(req.subjectId))
        if (newId <= 0) {
            throw notFound("条目")
        }
        // 同步重建检索索引（失败不影响克隆结果）
        this.reindex(newId)
        return ApiResponse.ok("{\"id\":\"${newId}\",\"sourceId\":\"${id}\"}", req.requestId)
    }

    /**
     * 时间线（FR-ARCH-010）：按主体聚合条目的创建/更新事件。
     */
    private func timeline(req: ApiRequest): ApiResponse {
        let rows = this.itemRepo.listTimeline(this.accessibleSubjects(req), 200)
        let sb = StringBuilder()
        sb.append("{\"events\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"id\":\"${r.str("id")}\",")
            sb.append("\"title\":\"${ItemRoutes.escape(r.str("title"))}\",")
            sb.append("\"category\":${r.i64("category")},")
            sb.append("\"status\":${r.i64("status")},")
            sb.append("\"version\":${r.i64("version")},")
            sb.append("\"createdAt\":${r.i64("created_ms")},")
            sb.append("\"updatedAt\":${r.i64("updated_ms")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    // ---------------------------------------------------------------
    // 工具
    // ---------------------------------------------------------------

    /**
     * 敏感度码 → 枚举。
     */
    private static func toSensitivity(code: Int64): Sensitivity {
        if (code >= 3) {
            return Sensitivity.High
        }
        if (code == 2) {
            return Sensitivity.Sensitive
        }
        return Sensitivity.Normal
    }

    /**
     * 条目记录 → JSON（详情接口用）。
     */
    // ---------------------------------------------------------------
    // 历史版本（FR-ARCH-011）
    // ---------------------------------------------------------------

    /**
     * 写入更新前的状态快照（无仓储或失败时静默跳过，不影响更新主流程）。
     */
    private func snapshotCurrent(id: Int64, r: ItemRecord, operatorId: Int64): Unit {
        match (this.versionRepo) {
            case Some(repo) =>
                try {
                    repo.create(id, r.version, ItemRoutes.snapshotJson(r), operatorId)
                } catch (e: Exception) {
                    Log.get().warn("item.version.snapshot.failed", None, [
                        ("itemId", "${id}"),
                        ("reason", e.toString())
                    ])
                }
            case None => ()
        }
    }

    /**
     * 条目状态 → JSON 快照。
     */
    private static func snapshotJson(r: ItemRecord): String {
        let sb = StringBuilder()
        sb.append("{\"title\":\"${ItemRoutes.escape(r.title)}\",")
        sb.append("\"category\":${r.category},")
        sb.append("\"status\":${r.status},")
        sb.append("\"sensitivity\":${r.sensitivity},")
        sb.append("\"issuedDate\":\"${ItemRoutes.escape(r.issuedDate)}\",")
        sb.append("\"expiresAt\":\"${ItemRoutes.escape(r.expiresAt)}\",")
        sb.append("\"issuer\":\"${ItemRoutes.escape(r.issuer)}\",")
        sb.append("\"remark\":\"${ItemRoutes.escape(r.remark)}\",")
        sb.append("\"extra\":\"${ItemRoutes.escape(r.extraJson)}\",")
        sb.append("\"version\":${r.version}}")
        return sb.toString()
    }

    /**
     * GET /api/items/:id/versions —— 历史版本列表（版本倒序）。
     */
    private func listVersions(req: ApiRequest): ApiResponse {
        let id = UserRepo.parseId(req.pathParam("id") ?? "")
        let repo = match (this.versionRepo) {
            case Some(r) => r
            case None => throw notFound("历史版本功能未启用")
        }
        let rows = repo.list(id)
        let sb = StringBuilder()
        sb.append("{\"versions\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"id\":\"${r.i64("id")}\",")
            sb.append("\"version\":${r.i64("version")},")
            sb.append("\"snapshot\":\"${ItemRoutes.escape(r.str("snapshot"))}\",")
            sb.append("\"changedBy\":\"${r.i64("changed_by")}\",")
            sb.append("\"changedAt\":${r.i64("changed_ms")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/items/:id/versions/:vid/restore —— 回滚到指定快照。
     *
     * 先把当前状态快照一次，再用目标快照内容执行普通更新（version 继续递增），
     * 因此回滚本身也可再回滚，且不破坏乐观锁与审计链。
     */
    private func restoreVersion(req: ApiRequest): ApiResponse {
        let id = UserRepo.parseId(req.pathParam("id") ?? "")
        let vid = UserRepo.parseId(req.pathParam("vid") ?? "")
        let repo = match (this.versionRepo) {
            case Some(r) => r
            case None => throw notFound("历史版本功能未启用")
        }
        let row = match (repo.get(id, vid)) {
            case Some(r) => r
            case None => throw notFound("历史版本")
        }
        let snapshot = match (SimpleJson.parse(row.str("snapshot"))) {
            case Some(j) => j
            case None => throw validationError("snapshot", "快照格式损坏，无法回滚")
        }
        let current = match (this.itemRepo.findByIdRaw(id)) {
            case Some(r) => r
            case None => throw notFound("条目")
        }
        let operatorId = UserRepo.parseId(req.subjectId)
        // 回滚前先快照当前状态
        this.snapshotCurrent(id, current, operatorId)
        let ok = this.itemRepo.update(
            id,
            current.version,
            UserRepo.parseId(current.subjectId),
            snapshot.get("title") ?? current.title,
            ItemRoutes.intOf(snapshot, "sensitivity", current.sensitivity),
            snapshot.get("issuedDate") ?? current.issuedDate,
            snapshot.get("expiresAt") ?? current.expiresAt,
            snapshot.get("issuer") ?? current.issuer,
            snapshot.get("remark") ?? current.remark,
            snapshot.get("extra") ?? current.extraJson,
            operatorId
        )
        if (!ok) {
            throw ItemRoutes.conflict(current.version)
        }
        this.reindex(id)
        return ApiResponse.ok("{\"restored\":true,\"fromVersion\":${row.i64("version")}}", req.requestId)
    }

    private static func toJsonOf(r: ItemRecord): String {
        let sb = StringBuilder()
        sb.append("{\"id\":\"${r.id}\",")
        sb.append("\"subjectId\":\"${r.subjectId}\",")
        sb.append("\"category\":${r.category},")
        sb.append("\"title\":\"${ItemRoutes.escape(r.title)}\",")
        sb.append("\"status\":${r.status},")
        sb.append("\"sensitivity\":${r.sensitivity},")
        sb.append("\"issuedDate\":\"${ItemRoutes.escape(r.issuedDate)}\",")
        sb.append("\"expiresAt\":\"${ItemRoutes.escape(r.expiresAt)}\",")
        sb.append("\"issuer\":\"${ItemRoutes.escape(r.issuer)}\",")
        sb.append("\"remark\":\"${ItemRoutes.escape(r.remark)}\",")
        sb.append("\"version\":${r.version},")
        sb.append("\"createdAt\":${r.createdAt},")
        sb.append("\"updatedAt\":${r.updatedAt}}")
        return sb.toString()
    }

    /**
     * 行记录 → JSON（列表接口用）。
     */
    private static func toJson(r: RowData): String {
        return ItemRoutes.toJson(r, false)
    }

    /**
     * 行记录 → JSON（列表接口用）。
     *
     * @param shared 该条目是否来自「家人共享给我的授权」而不是我自己的主体。
     *               前端据此加「共享」标记 —— 两类条目混在一起而不加区分，
     *               用户会误以为别人的档案跑进了自己的库里（FR-ACL-010）。
     */
    private static func toJson(r: RowData, shared: Bool): String {
        let sb = StringBuilder()
        sb.append("{\"id\":\"${r.i64("id")}\",")
        sb.append("\"subjectId\":\"${r.i64("subject_id")}\",")
        sb.append("\"category\":${r.i64("category")},")
        sb.append("\"title\":\"${ItemRoutes.escape(r.str("title"))}\",")
        sb.append("\"status\":${r.i64("status")},")
        sb.append("\"sensitivity\":${r.i64("sensitivity")},")
        sb.append("\"issuer\":\"${ItemRoutes.escape(r.getOpt("issuer") ?? "")}\",")
        sb.append("\"remark\":\"${ItemRoutes.escape(r.getOpt("remark") ?? "")}\",")
        sb.append("\"version\":${r.i64("version")},")
        sb.append("\"source\":${r.i64("source")},")
        sb.append("\"createdAt\":${r.i64("created_ms")},")
        sb.append("\"shared\":${if (shared) { "true" } else { "false" }},")
        sb.append("\"updatedAt\":${r.i64("updated_ms")}}")
        return sb.toString()
    }

    /**
     * JSON 字符串转义。
     */
    private static func escape(s: String): String {
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
    }

    /**
     * 取整数参数。
     */
    private static func intOf(src: Map<String, String>, key: String, def: Int64): Int64 {
        match (src.get(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return def
                }
                return RowData.toI64(v)
            case None => return def
        }
    }

    /**
     * 取整数参数（JSON）。
     */
    private static func intOf(src: SimpleJson, key: String, def: Int64): Int64 {
        match (src.get(key)) {
            case Some(v) => return RowData.toI64(v)
            case None => return def
        }
    }

    /**
     * 取查询串中的整数参数。
     */
    private static func intOfQuery(req: ApiRequest, key: String, def: Int64): Int64 {
        match (req.queryParam(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return def
                }
                return RowData.toI64(v)
            case None => return def
        }
    }

    /** 取查询参数，缺省返回空串（FR-SRC-010 创建时间范围）。 */
    private static func queryOrEmpty(req: ApiRequest, key: String): String {
        match (req.queryParam(key)) {
            case Some(v) => return v
            case None => return ""
        }
    }

    /**
     * 乐观锁冲突（409）。
     */
    private static func conflict(currentVersion: Int64): AppError {
        return AppError(
            AppErrorKind.Conflict,
            "您基于旧版本，当前版本为 ${currentVersion}，请刷新后重试"
        )
    }

    /**
     * 解析请求体。
     */
    private static func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }
}
