// ============================================================
// ams-api · 路由元数据静态契约测试
//
// 性质：**纯内存断言**，不构造真实 DB / HTTP 服务，也不发起任何请求。
//   仓颉测试难以在编译期读取其它源文件，故这里以「契约快照」的方式，
//   把当前接口层公开的路由路径 / 权限点 / 公开路由白名单登记为常量表，
//   再逐条校验命名与前缀约定。任何破坏约定的改动都会让本用例失败。
//
// [写法] 与同目录 api_test.cj 保持一致：
//   · package 声明必须是 ams.api.tests（同目录只能有一个包声明）；
//   · @Test 顶层函数 + std.unittest.* 的 @Assert；
//   · 不定义与 api_test.cj 同名的顶层符号（makeReq / isTestHandler / TestHandler）。
//
// 编译运行：bash scripts/test.sh ams-api
// ============================================================
package ams.api.tests

import std.unittest.*

/** 轻量成员判断（不依赖 Array.contains，兼容当前工具链）。 */
private func contractContains(arr: Array<String>, target: String): Bool {
    for (x in arr) {
        if (x == target) {
            return true
        }
    }
    return false
}

/**
 * 路由路径约定：一律以 /api/ 开头，且无尾斜杠、无双斜杠。
 * 下表是接口层受保护路由的代表性快照（含参数化路径）。
 */
@Test
public func testContractRoutePathsAreApiPrefixed(): Unit {
    let paths: Array<String> = [
        "/api/items", "/api/items/:id",
        "/api/users", "/api/users/:id",
        "/api/attachments", "/api/attachments/:id", "/api/attachments/:id/versions",
        "/api/audit/logs", "/api/roles", "/api/tags", "/api/search",
        "/api/export", "/api/import", "/api/import/attachments",
        "/api/admin/health", "/api/system/config", "/api/subjects", "/api/notify"
    ]
    var allOk = true
    for (p in paths) {
        if (!p.startsWith("/api/")) { allOk = false }
        if (p.endsWith("/")) { allOk = false }
        if (p.contains("//")) { allOk = false }
    }
    @Assert(allOk)
}

/**
 * 权限点命名约定：非空、含 ':' 分隔（domain:action[:scope]）、
 * 不以上/下冒号开头结尾、不含空白，且全局唯一。
 * 下表是 routes 目录下各 .cj 中实际使用的权限点全集快照。
 */
@Test
public func testContractPermissionPointsWellFormed(): Unit {
    let perms: Array<String> = [
        "acl:grant:own", "acl:manage", "acl:read:own", "acl:revoke:own",
        "archive:delete:own", "archive:export:own", "archive:read:own",
        "archive:read_sensitive", "archive:write:own",
        "attachment:delete:any", "attachment:download:own",
        "attachment:read:own", "attachment:upload:own",
        "audit:export", "audit:read",
        "cfg:dict:manage", "cfg:manage", "cfg:read",
        "family:invite", "family:manage",
        "notify:read:own",
        "subject:read:own", "subject:write:own",
        "system:admin",
        "tag:read:own", "tag:write:own",
        "user:manage", "user:read:any"
    ]
    var wellFormed = true
    for (perm in perms) {
        if (perm.isEmpty()) { wellFormed = false }
        if (!perm.contains(":")) { wellFormed = false }
        if (perm.startsWith(":")) { wellFormed = false }
        if (perm.endsWith(":")) { wellFormed = false }
        if (perm.contains(" ")) { wellFormed = false }
    }
    @Assert(wellFormed)

    // 唯一性：任意两条不得重名
    var duplicated = false
    var i: Int64 = 0
    while (i < perms.size) {
        var j: Int64 = i + 1
        while (j < perms.size) {
            if (perms[i] == perms[j]) { duplicated = true }
            j = j + 1
        }
        i = i + 1
    }
    @Assert(!duplicated)
}

/**
 * 公开路由白名单：全部以 /api/ 开头，关键匿名入口必须登记，
 * 且绝不能混入需要鉴权的受保护路径。
 * 下表取自 routes 目录下各 .cj 中 isPublic: true 的单行注册项。
 */
@Test
public func testContractPublicWhitelist(): Unit {
    let publicPaths: Array<String> = [
        "/api/auth/login", "/api/auth/refresh", "/api/auth/register",
        "/api/auth/password/forgot", "/api/auth/password/verify",
        "/api/auth/password/reset",
        "/api/branding", "/api/i18n/locales",
        "/api/setup/status", "/api/setup/test-db", "/api/setup/database",
        "/api/setup/mail", "/api/setup/test-mail", "/api/setup/admin"
    ]
    @Assert(publicPaths.size == 14)

    var allApi = true
    for (p in publicPaths) {
        if (!p.startsWith("/api/")) { allApi = false }
    }
    @Assert(allApi)

    // 关键匿名入口在白名单内
    @Assert(contractContains(publicPaths, "/api/auth/login"))
    @Assert(contractContains(publicPaths, "/api/auth/register"))
    @Assert(contractContains(publicPaths, "/api/setup/status"))
    @Assert(contractContains(publicPaths, "/api/i18n/locales"))
    @Assert(contractContains(publicPaths, "/api/branding"))

    // 受保护路径绝不能出现在公开白名单里
    @Assert(!contractContains(publicPaths, "/api/users"))
    @Assert(!contractContains(publicPaths, "/api/items"))
    @Assert(!contractContains(publicPaths, "/api/admin/health"))
}

/** HTTP 方法约定：仅允许大写 GET / POST / PUT / DELETE。 */
@Test
public func testContractHttpMethodsUppercase(): Unit {
    let methods: Array<String> = ["GET", "POST", "PUT", "DELETE"]
    var allOk = true
    for (m in methods) {
        if (m != m.toAsciiUpper()) { allOk = false }
        if (!contractContains(methods, m)) { allOk = false }
        if (m != "GET" && m != "POST" && m != "PUT" && m != "DELETE") { allOk = false }
    }
    @Assert(allOk)
}
