#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AMS · opengauss-driver 本地适配补丁

用途：把 Cangjie-TPC/opengauss-driver 适配到仓颉 SDK 1.2.0 STS + stdx 1.2.0.1。

为什么需要补丁：
    驱动基于 stdx 1.1.x 编写，依赖 stdx.log / stdx.logger 的 `Logger` 接口
    与全局 `logger` 变量。stdx 1.2.0 对其做了破坏性变更：
      · 全局 `logger` 变量移除，改为 getGlobalLogger() / setGlobalLogger()；
      · `Logger` 接口方法集由 log(record: LogRecord) 改为 log(level, message, attrs)；
      · 旧 SimpleLogger 签名不兼容，导致 HashMap<String,String> 走 LogValue
        转换时抛 "extensionData is nullptr"。

    症状：驱动**编译通过但运行时崩溃**，在 ds.connect() 阶段即中止，
    表现为一运行就退出、无任何查询结果。

处置方式：
    把驱动的 slog 包改写为**自包含的最小日志实现**（不依赖 stdx.log），
    并把其余 8 个包里的 `import stdx.log.*` 换成 `import ...slog.*`。

    驱动全仓只用到 3 个级别方法（debug / warn / error）与 level 属性，
    自实现成本远低于适配上游破坏性变更；
    收益是驱动与 stdx 版本**彻底解耦**，后续 stdx 再升级也不影响数据库层。

幂等性：
    脚本可重复执行（已打过补丁的文件会被识别并跳过）。

用法：
    python3 scripts/patch-driver.py            # 打补丁
    python3 scripts/patch-driver.py --check    # 只检查是否已打
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRV_SRC = os.path.join(ROOT, "tools", "vendor", "opengauss-driver", "src")

# 需要把 stdx.log 换成 slog 的文件
REIMPORT_FILES = [
    "driver/driver.cj",
    "pgconn/auth_scram.cj",
    "pgconn/conn.cj",
    "proto3/proto3.cj",
    "sema/semaphore.cj",
    "sqlpool/pooled_database.cj",
    "tinypool/tiny_pool.cj",
    "url/parser.cj",
]

SLOG_FILE = "slog/slog.cj"

PATCH_MARK = "AMS 项目本地补丁"

# 自实现日志层（替代 stdx.log）
SLOG_CONTENT = r'''/**
 * Copyright (c) [2022] Huawei Technologies Co., Ltd.
 * [opengauss-driver] is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of the Mulan PSL v2 at:
 *            http://license.coscl.org.cn/MulanPSL2
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS,
 * WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 * See the Mulan PSL v2 for more details.
 *
 * ============================ 适配说明（AMS 项目本地补丁） ============================
 *
 * 背景：
 *   原实现依赖 stdx.log / stdx.logger 的 `Logger` 接口与全局 `logger` 变量。
 *   stdx 1.2.0（配合仓颉 SDK 1.2.0 STS）对该接口做了**破坏性变更**：
 *     - 全局 `logger` 变量被移除，改为 `getGlobalLogger()` / `setGlobalLogger()`；
 *     - `Logger` 接口的方法集由 `log(record: LogRecord)` 改为
 *       `log(level, message, attrs)`，`LogRecord` / `LogValue` 的构造方式亦变；
 *     - 旧的 `Logger` 实现（SimpleLogger 等）签名不兼容，
 *       导致 `HashMap<String,String>` 走 LogValue 转换时抛
 *       "extensionData is nullptr, itf: stdx.serialization.serialization:Serializable<...>"。
 *
 *   后果：驱动在 stdx 1.2.0 下**编译通过但运行时崩溃**（connect 阶段即中止）。
 *
 * 处置：
 *   本文件改为**自包含的最小日志实现**，不再依赖 stdx.log / stdx.logger。
 *   驱动全仓只用到 3 个级别方法（debug / warn / error）与 level 属性，
 *   自实现成本远低于适配上游破坏性变更，且让驱动与 stdx 版本解耦
 *   （后续 stdx 再升级也不会影响数据库驱动）。
 *
 *   保留原有对外接口：
 *     - `Default(): Logger`      取全局 logger
 *     - `setDefault(l: Logger)`  替换全局 logger
 *     - `Logger` 的 debug/info/warn/error/trace/fatal 与 level 属性
 *   其余驱动包（chunkreader / driver / interx / pgconn / proto3 / sema /
 *   sqlpool / tinypool / url）均只通过 `slog.Default()` 获取 logger，无需改动。
 *
 * 行为：
 *   - 默认级别 INFO，DEBUG 级别不输出（与原 SimpleLogger 默认行为一致，
 *     也避免驱动连接期产生大量日志噪声）；
 *   - 输出到 stdout，格式：`[LEVEL] message`；
 *   - 线程安全（用 Mutex 保护写操作）。
 * ==================================================================================
 */
package cangjie_tpc::opengauss.slog

import std.sync.*

/**
 * 日志级别。数值越大越严重，与原 stdx.log 的比较语义一致。
 */
public enum LogLevel {
    | Trace
    | Debug
    | Info
    | Warn
    | Error
    | Fatal
    | Off

    /**
     * 级别序号（供大小比较）。
     */
    public func toInt(): Int64 {
        match (this) {
            case LogLevel.Trace => return 0
            case LogLevel.Debug => return 1
            case LogLevel.Info => return 2
            case LogLevel.Warn => return 3
            case LogLevel.Error => return 4
            case LogLevel.Fatal => return 5
            case LogLevel.Off => return 6
        }
    }

    /**
     * 级别名（用于输出前缀）。
     */
    public func label(): String {
        match (this) {
            case LogLevel.Trace => return "TRACE"
            case LogLevel.Debug => return "DEBUG"
            case LogLevel.Info => return "INFO"
            case LogLevel.Warn => return "WARN"
            case LogLevel.Error => return "ERROR"
            case LogLevel.Fatal => return "FATAL"
            case LogLevel.Off => return "OFF"
        }
    }

    /**
     * 级别比较（>=）。
     *
     * 说明：仓颉的 enum **不支持** `>=` 等比较运算符
     *（编译报 "invalid binary operator '>=' on type 'Enum-LogLevel'"），
     * 故显式提供比较方法，调用方改为 `logger.level.ge(LogLevel.Debug)`。
     */
    public func ge(other: LogLevel): Bool {
        return this.toInt() >= other.toInt()
    }

    /**
     * 级别比较（>）。
     */
    public func gt(other: LogLevel): Bool {
        return this.toInt() > other.toInt()
    }

    /**
     * 级别比较（<=）。
     */
    public func le(other: LogLevel): Bool {
        return this.toInt() <= other.toInt()
    }

    /**
     * 级别比较（<）。
     */
    public func lt(other: LogLevel): Bool {
        return this.toInt() < other.toInt()
    }

    /**
     * 级别相等。
     */
    public func eq(other: LogLevel): Bool {
        return this.toInt() == other.toInt()
    }
}

/**
 * 日志器接口。
 *
 * 与驱动其余代码的使用方式保持一致：
 *   logger.debug("...") / logger.warn("...") / logger.error("...")
 *   logger.level >= LogLevel.Debug
 */
public interface Logger {
    /**
     * 写一条日志。
     */
    func log(level: LogLevel, message: String): Unit

    /**
     * TRACE 级别日志。
     */
    func trace(message: String): Unit {
        this.log(LogLevel.Trace, message)
    }

    /**
     * DEBUG 级别日志。
     */
    func debug(message: String): Unit {
        this.log(LogLevel.Debug, message)
    }

    /**
     * INFO 级别日志。
     */
    func info(message: String): Unit {
        this.log(LogLevel.Info, message)
    }

    /**
     * WARN 级别日志。
     */
    func warn(message: String): Unit {
        this.log(LogLevel.Warn, message)
    }

    /**
     * ERROR 级别日志。
     */
    func error(message: String): Unit {
        this.log(LogLevel.Error, message)
    }

    /**
     * FATAL 级别日志。
     */
    func fatal(message: String): Unit {
        this.log(LogLevel.Fatal, message)
    }

    /**
     * 当前最低输出级别。
     */
    mut prop level: LogLevel

    /**
     * 是否已关闭。
     */
    func isClosed(): Bool {
        return false
    }

    /**
     * 关闭日志器。
     */
    func close(): Unit {
        ()
    }
}

/**
 * 简单控制台日志器。
 *
 * 写操作加锁，保证多线程下不交错。
 */
public class SimpleLogger <: Logger {
    private let lock = Mutex()
    private var minLevel: LogLevel = LogLevel.Info
    private var closed: Bool = false

    public init() {
        // 默认 INFO：驱动连接期 DEBUG 日志量很大，默认不输出
        this.minLevel = LogLevel.Info
    }

    public init(minLevel: LogLevel) {
        this.minLevel = minLevel
    }

    public mut prop level: LogLevel {
        get() {
            return this.minLevel
        }
        set(value) {
            this.minLevel = value
        }
    }

    public func log(level: LogLevel, message: String): Unit {
        if (this.closed) {
            return
        }
        if (level.toInt() < this.minLevel.toInt()) {
            return
        }
        this.lock.lock()
        try {
            println("[${level.label()}] ${message}")
        } finally {
            this.lock.unlock()
        }
    }

    public func isClosed(): Bool {
        return this.closed
    }

    public func close(): Unit {
        this.lock.lock()
        try {
            this.closed = true
        } finally {
            this.lock.unlock()
        }
    }
}

/**
 * 全局日志器持有者。
 *
 * 说明：AtomicReference 的类型参数要求是 Object 子类，
 * 而 Logger 是接口（接口在仓颉里不是 Object 子类），
 * 故这里用「可变静态字段 + Mutex」实现线程安全的读写。
 */
public class LoggerWrapper {
    private static let lock = Mutex()
    private static var current: Logger = SimpleLogger()

    /**
     * 读取当前全局日志器。
     */
    public static func get(): Logger {
        LoggerWrapper.lock.lock()
        try {
            return LoggerWrapper.current
        } finally {
            LoggerWrapper.lock.unlock()
        }
    }

    /**
     * 替换全局日志器。
     */
    public static func set(l: Logger): Unit {
        LoggerWrapper.lock.lock()
        try {
            LoggerWrapper.current = l
        } finally {
            LoggerWrapper.lock.unlock()
        }
    }
}

/**
 * 取当前全局日志器。
 */
public func Default(): Logger {
    return LoggerWrapper.get()
}

/**
 * 替换全局日志器。
 */
public func setDefault(l: Logger): Unit {
    LoggerWrapper.set(l)
}
'''


def read(path):
    with io.open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def main():
    check_only = "--check" in sys.argv

    if not os.path.isdir(DRV_SRC):
        print("[ERROR] 驱动源码不存在：%s" % DRV_SRC)
        print("        请先执行：bash scripts/install-driver.sh")
        return 1

    changed = []
    pending = []

    # ---- 1. slog 包整体替换 ----
    slog_path = os.path.join(DRV_SRC, SLOG_FILE)
    if not os.path.isfile(slog_path):
        print("[ERROR] 找不到 %s" % slog_path)
        return 1
    cur = read(slog_path)
    if PATCH_MARK in cur:
        # 幂等：已打过补丁则只确保内容是最新版
        if cur != SLOG_CONTENT:
            if not check_only:
                write(slog_path, SLOG_CONTENT)
                changed.append(SLOG_FILE + " (内容更新)")
            else:
                pending.append(SLOG_FILE)
    else:
        if not check_only:
            write(slog_path, SLOG_CONTENT)
            changed.append(SLOG_FILE)
        else:
            pending.append(SLOG_FILE)

    # ---- 2. 替换 stdx.log 导入 ----
    for rel in REIMPORT_FILES:
        p = os.path.join(DRV_SRC, rel)
        if not os.path.isfile(p):
            print("[WARN] 缺少文件：%s" % rel)
            continue
        cur = read(p)
        if "import stdx.log.*" in cur:
            if not check_only:
                cur = cur.replace(
                    "import stdx.log.*",
                    "import cangjie_tpc::opengauss.slog.*",
                )
                write(p, cur)
                changed.append(rel)
            else:
                pending.append(rel)

    # ---- 4. 集合类型的 Serializable 依赖（stdx 1.2.0 变更）----
    # stdx 1.2.0 起 HashMap / Array / ArrayList **不再实现** Serializable 接口，
    # 而驱动的协议消息结构体用 `field<Collection>(...)` 把集合塞进 DataModel，
    # 运行期会抛
    #   "extensionData is nullptr, itf: stdx.serialization.serialization:Serializable<...>"
    # 导致连接阶段即崩溃。
    #
    # 处置：把集合字段改为字符串（`field<String>(name, coll.toString())`），
    #       与上游 error_response.cj 已有的做法保持一致。
    #       这些字段只服务于调试用的 toString()，协议编码走 encode()，不影响功能。
    COLL_FIELD_PAT = re.compile(
        r'field<(?:HashMap|Array|ArrayList)<[^>]+>>\("([^"]+)",\s*([A-Za-z_][A-Za-z0-9_]*)\)'
    )
    for root, _dirs, files in os.walk(DRV_SRC):
        for f in files:
            if not f.endswith(".cj") or "_test" in f:
                continue
            fp = os.path.join(root, f)
            txt = read(fp)
            new = COLL_FIELD_PAT.sub(
                lambda m: 'field<String>("%s", %s.toString())' % (m.group(1), m.group(2)),
                txt,
            )
            if new != txt:
                if not check_only:
                    write(fp, new)
                    changed.append(os.path.relpath(fp, DRV_SRC) + " (集合序列化)")
                else:
                    pending.append(os.path.relpath(fp, DRV_SRC))

    # ---- 5. 集合类型不再能从 DataModel 反序列化 ----
    # serialize() 改为字符串后，对应的 deserialize 调用会类型不匹配。
    # 这些调用只在调试用的 deserialize() 里，协议解码走 decode()，故注释掉。
    DESER_PAT = re.compile(
        r"^(\s*)(result\.[A-Za-z_][A-Za-z0-9_]* = "
        r"(?:Array<[^>]+>|ArrayList<[^>]+>|HashMap<[^>]+>)\.deserialize\(dms\.get\(\"[^\"]+\"\)\))\s*$",
        re.M,
    )
    for root, _dirs, files in os.walk(DRV_SRC):
        for f in files:
            if not f.endswith(".cj") or "_test" in f:
                continue
            fp = os.path.join(root, f)
            txt = read(fp)
            new = DESER_PAT.sub(
                lambda m: "%s// %s  // stdx 1.2.0: 集合类型不再实现 Serializable，"
                "故不再从 DataModel 还原（协议解码走 decode()）" % (m.group(1), m.group(2)),
                txt,
            )
            if new != txt:
                if not check_only:
                    write(fp, new)
                    changed.append(os.path.relpath(fp, DRV_SRC) + " (集合反序列化)")
                else:
                    pending.append(os.path.relpath(fp, DRV_SRC))

    # ---- 6. 枚举比较运算（仓颉 enum 不支持 >= ）----
    # 驱动的 `logger.level >= LogLevel.Debug` 在 enum 上不成立，
    # 改为调用自实现 LogLevel 的比较方法 ge()。
    CMP_FILES = [
        "driver/statement.cj",
        "pgconn/conn.cj",
        "pgconn/result_reader.cj",
        "proto3/backend.cj",
        "proto3/proto3.cj",
    ]
    for rel in CMP_FILES:
        p = os.path.join(DRV_SRC, rel)
        if not os.path.isfile(p):
            continue
        cur = read(p)
        new = re.sub(
            r"logger\.level\s*>=\s*(LogLevel\.\w+)",
            r"logger.level.ge(\1)",
            cur,
        )
        if new != cur:
            if not check_only:
                write(p, new)
                changed.append(rel + " (级别比较)")
            else:
                pending.append(rel)

    # ---- 7. 枚举成员名统一为大驼峰 ----
    # stdx 的 LogLevel 成员是全大写（DEBUG），自实现版本遵循仓颉命名规范用大驼峰（Debug）。
    for root, _dirs, files in os.walk(DRV_SRC):
        for f in files:
            if not f.endswith(".cj") or "_test" in f:
                continue
            fp = os.path.join(root, f)
            txt = read(fp)
            new = re.sub(
                r"LogLevel\.(TRACE|DEBUG|INFO|WARN|ERROR|FATAL|OFF)\b",
                lambda m: "LogLevel." + m.group(1).capitalize(),
                txt,
            )
            if new != txt:
                if not check_only:
                    write(fp, new)
                    changed.append(os.path.relpath(fp, DRV_SRC) + " (枚举命名)")
                else:
                    pending.append(os.path.relpath(fp, DRV_SRC))

    # ---- 8. 检查是否还有 stdx.log 残留 ----
    leftovers = []
    for root, _dirs, files in os.walk(DRV_SRC):
        for f in files:
            if not f.endswith(".cj"):
                continue
            if "_test" in f:
                continue
            fp = os.path.join(root, f)
            txt = read(fp)
            if re.search(r"^\s*(internal\s+)?import\s+stdx\.log", txt, re.M):
                leftovers.append(os.path.relpath(fp, DRV_SRC))

    if check_only:
        print("=== 驱动补丁状态 ===")
        print("待打补丁 : %s" % (", ".join(pending) if pending else "无"))
        print("stdx.log 残留 : %s" % (", ".join(leftovers) if leftovers else "无"))
        return 0 if not pending and not leftovers else 1

    print("=== 驱动适配补丁已应用 ===")
    for c in changed:
        print("  [PATCH] %s" % c)
    if not changed:
        print("  （已是最新，无需改动）")
    if leftovers:
        print("  [WARN] 仍有 stdx.log 残留，需人工检查：%s" % ", ".join(leftovers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
