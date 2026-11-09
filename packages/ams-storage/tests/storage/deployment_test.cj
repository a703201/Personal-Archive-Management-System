// ============================================================
// ams.storage.deployment · DeploymentStore 单元测试
//
// [结构约定]（与 log_test.cj / error_test.cj 一致，实测 SDK 1.0.5）：
//   · 测试代码与产品代码物理分离，测试包声明为 <被测包>.test；
//   · @Test 顶层函数，断言用 std.unittest.* 的 @Assert；
//   · 不依赖数据库 / 网络 / HTTP 服务，全部内存 + 临时目录驱动。
//
// [临时目录] 用 AMS_CONFIG_DIR 或显式 dir: 参数指向临时路径。
//   DeploymentStore.init(dir!: String = "") 支持显式传目录，
//   故这里直接传 dir:，避免改动进程级环境；仅 resolve 的环境变量
//   优先级测试用 std.env.setVariable 注入，**键名全部唯一**，不污染产品配置。
//
// 编译运行：bash scripts/test.sh ams-storage
// ============================================================
package ams.storage.test

import std.collection.*
import std.env.*
import std.unittest.*

import ams.storage.*

/** 每个用例独立目录，避免相互污染，也避免上一次运行残留的 deployment.env。 */
private func dirOf(tag: String): String {
    return "./ams_deploy_test_${tag}"
}

/**
 * 造一个「干净」的 DeploymentStore：
 * 先往该目录写空的 deployment.env（等价于产品里「全部键被清空」后的落盘结果），
 * 再构造 store，load() 读到的即为空配置。
 */
private func freshStore(tag: String): DeploymentStore {
    let dir = dirOf(tag)
    let fs = LocalFileStorage(dir)
    fs.put(DeploymentStore.FILE_KEY, Array<Byte>())
    return DeploymentStore(dir: dir)
}

/** 单条更新。 */
private func updates(k: String, v: String): HashMap<String, String> {
    let m = HashMap<String, String>()
    m[k] = v
    return m
}

/** get：未设置返回 None，setAll 后返回 Some。 */
@Test
public func testGetMissingAndSet(): Unit {
    let store = freshStore("get")
    @Assert(store.get("MISSING").isNone())
    store.setAll(updates("K", "V"))
    @Assert(store.get("K").getOrThrow(), "V")
}

/** resolve：文件与环境变量都缺失时回退到代码默认。 */
@Test
public func testResolveFallbackWhenUnset(): Unit {
    let store = freshStore("resolve_fallback")
    // 该环境变量名刻意保证从未被设置
    let r = store.resolve("CFG_KEY", "AMS_TEST_NEVER_SET_FALLBACK", "the-fallback")
    @Assert(r, "the-fallback")
}

/** resolve：文件无值时取环境变量（环境变量 > 代码默认）。 */
@Test
public func testResolveEnvBeatsFallback(): Unit {
    setVariable("AMS_TEST_RESOLVE_ENV", "from-env-value")
    @Assert(getVariable("AMS_TEST_RESOLVE_ENV").getOrThrow(), "from-env-value")
    let store = freshStore("resolve_env")
    let r = store.resolve("CFG_KEY", "AMS_TEST_RESOLVE_ENV", "the-fallback")
    @Assert(r, "from-env-value")
}

/** resolve：文件值优先于环境变量与代码默认（文件 > 环境变量 > 默认）。 */
@Test
public func testResolveFileBeatsEnv(): Unit {
    setVariable("AMS_TEST_RESOLVE_FILE", "from-env-value")
    let store = freshStore("resolve_file")
    store.setAll(updates("CFG_KEY", "from-file-value"))
    let r = store.resolve("CFG_KEY", "AMS_TEST_RESOLVE_FILE", "the-fallback")
    @Assert(r, "from-file-value")
}

/** resolve：仅有文件值时也优先于代码默认。 */
@Test
public func testResolveFileBeatsFallback(): Unit {
    let store = freshStore("resolve_file_only")
    store.setAll(updates("CFG_KEY", "from-file-only"))
    let r = store.resolve("CFG_KEY", "AMS_TEST_NEVER_SET_FILE_ONLY", "the-fallback")
    @Assert(r, "from-file-only")
}

/** setAll 落盘后，新建实例能重新读到值。 */
@Test
public func testSetAllPersistThenReload(): Unit {
    let dir = dirOf("persist")
    let fs = LocalFileStorage(dir)
    fs.put(DeploymentStore.FILE_KEY, Array<Byte>())
    let a = DeploymentStore(dir: dir)
    a.setAll(updates("DB_HOST", "db.internal"))
    a.setAll(updates("DB_PORT", "5432"))
    let b = DeploymentStore(dir: dir)
    @Assert(b.get("DB_HOST").getOrThrow(), "db.internal")
    @Assert(b.get("DB_PORT").getOrThrow(), "5432")
}

/** redactedJson：敏感键一律显示为 ***，绝不泄露口令原文。 */
@Test
public func testRedactedJsonHidesSecrets(): Unit {
    let store = freshStore("redact")
    let m = HashMap<String, String>()
    m["DB_HOST"] = "db.internal"
    m["DB_PASSWORD"] = "s3cr3t-pw"
    m["MAIL_PASSWORD"] = "mail-pw"
    m["TOKEN_SECRET"] = "token-secret"
    store.setAll(m)
    let json = store.redactedJson()
    // 非敏感值明文可见
    @Assert(json.contains("\"DB_HOST\":\"db.internal\""))
    // 三个敏感键都脱敏
    @Assert(json.contains("\"DB_PASSWORD\":\"***\""))
    @Assert(json.contains("\"MAIL_PASSWORD\":\"***\""))
    @Assert(json.contains("\"TOKEN_SECRET\":\"***\""))
    // 口令原文绝不能出现在输出里
    @Assert(!json.contains("s3cr3t-pw"))
    @Assert(!json.contains("mail-pw"))
    @Assert(!json.contains("token-secret"))
}

/** clearAll：写空串即视为删除，重新读取也不复活。 */
@Test
public func testClearAll(): Unit {
    let dir = dirOf("clear")
    let fs = LocalFileStorage(dir)
    fs.put(DeploymentStore.FILE_KEY, Array<Byte>())
    let store = DeploymentStore(dir: dir)
    store.setAll(updates("K1", "v1"))
    @Assert(store.get("K1").getOrThrow(), "v1")
    store.clearAll(["K1", "K2"])
    @Assert(store.get("K1").isNone())
    @Assert(store.get("K2").isNone())
    let reloaded = DeploymentStore(dir: dir)
    @Assert(reloaded.get("K1").isNone())
}

/** setAll：含换行 / 回车的值被拒绝，且不写入该键。 */
@Test
public func testSetAllRejectsNewline(): Unit {
    let store = freshStore("newline")
    var threwN = false
    try {
        store.setAll(updates("K", "line1\nline2"))
    } catch (e: Exception) {
        threwN = true
    }
    @Assert(threwN, true)
    @Assert(store.get("K").isNone())

    var threwR = false
    try {
        store.setAll(updates("K", "line1\rline2"))
    } catch (e: Exception) {
        threwR = true
    }
    @Assert(threwR, true)
    @Assert(store.get("K").isNone())
}

/** 空值等同未设置：setAll 写空串 / clearAll 都让 get 返回 None，resolve 回退。 */
@Test
public func testEmptyValueIsUnset(): Unit {
    let store = freshStore("empty")
    store.setAll(updates("K", ""))
    @Assert(store.get("K").isNone())
    @Assert(store.resolve("K", "AMS_TEST_NEVER_SET_EMPTY", "fallback-val"), "fallback-val")

    store.setAll(updates("K", "real-value"))
    @Assert(store.get("K").getOrThrow(), "real-value")
    store.clearAll(["K"])
    @Assert(store.get("K").isNone())
}

/** escape：最小 JSON 转义（引号 / 反斜杠 / 换行）。 */
@Test
public func testEscape(): Unit {
    @Assert(DeploymentStore.escape("a\"b"), "a\\\"b")
    @Assert(DeploymentStore.escape("a\\b"), "a\\\\b")
    @Assert(DeploymentStore.escape("a\nb"), "a\\nb")
    @Assert(DeploymentStore.escape("plain"), "plain")
}

/** init 未显式传 dir 时，经 AMS_CONFIG_DIR 环境变量定位配置目录。 */
@Test
public func testConfigDirFromEnv(): Unit {
    let dir = dirOf("envdir")
    let fs = LocalFileStorage(dir)
    fs.put(DeploymentStore.FILE_KEY, Array<Byte>())
    setVariable("AMS_CONFIG_DIR", dir)
    let a = DeploymentStore()
    a.setAll(updates("K", "from-env-dir"))
    let b = DeploymentStore()
    @Assert(b.get("K").getOrThrow(), "from-env-dir")
}
