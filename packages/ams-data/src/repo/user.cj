// ============================================================
// ams.data.repo · 用户 / 角色 / 权限仓储
//
// 需求：
//   FR-CFG-001 用户管理（列表 / 详情 / 增删改 / 启停用 / 重置口令）
//   FR-CFG-002 角色管理（角色 CRUD + 权限分配）
//   FR-AUTH-001 登录（查用户、校验状态与锁定）
//
// [驱动 API 约定]（opengauss-driver 实现 std.database.sql 标准接口）
//   Statement.set<T>(index, value)   绑定参数（1 起始）
//   Statement.query() -> QueryResult 查询
//   Statement.update() -> UpdateResult 更新（rowCount / lastInsertId）
//   QueryResult.next() -> Bool       前进到下一行
//   QueryResult.columnInfos          列元信息（name / typeName / nullable）
//   QueryResult.getOrNull<String>(i)  按下标取值，NULL 返回 None
//
// [安全约束]
//   ① 全部 SQL 用占位符参数化，杜绝字符串拼接（防 SQL 注入）
//   ② 登录失败计数 / 锁定用原子 UPDATE（failed_attempts = failed_attempts + 1）
//   ③ 口令哈希只出现在登录查询里，不进列表接口
//   ④ 软删除：deleted_at IS NULL 才可见
//
// [分层约束]
//   本包只依赖 ams-kernel 与 ams.data.db；
//   返回「行数据」（RowData）而非领域模型，映射在 ams-app 完成。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 通用行数据。
 *
 * 列名 -> 值。值统一为字符串表示（驱动 getOrNull<String> 已完成类型转换），
 * 上层按需再转型，避免为每个 PG 类型写一套映射。
 */
public class RowData {
    private let cols: ArrayList<String>
    private let vals: ArrayList<Option<String>>

    public init() {
        this.cols = ArrayList<String>()
        this.vals = ArrayList<Option<String>>()
    }

    public func put(name: String, value: Option<String>): Unit {
        this.cols.add(name)
        this.vals.add(value)
    }

    public func colCount(): Int64 {
        return this.cols.size
    }

    /**
     * 全部列名（按查询顺序）。
     */
    public func columnNames(): ArrayList<String> {
        return this.cols
    }

    /**
     * 取字符串值；列为 NULL 或不存在时返回 ""。
     */
    public func str(name: String): String {
        match (this.getOpt(name)) {
            case Some(v) => return v
            case None => return ""
        }
    }

    /**
     * 取整数值；列为 NULL 或不可解析时返回 0。
     */
    public func i64(name: String): Int64 {
        match (this.getOpt(name)) {
            case Some(v) => return RowData.toI64(v)
            case None => return 0
        }
    }

    /**
     * 取布尔值；列为 NULL 时返回 false。
     */
    public func bool(name: String): Bool {
        match (this.getOpt(name)) {
            case Some(v) => return v == "t" || v == "true" || v == "1"
            case None => return false
        }
    }

    /**
     * 查找列下标（**大小写不敏感回退**）。
     *
     * 为什么需要：PostgreSQL/openGauss 会把未加引号的别名转成小写，
     * 而驱动返回的列名形态不保证一致（可能保留数据库原始大小写）。
     * 实测踩坑：`encode(prev_hash,'hex') AS prev_hash_hex` 取不到值，
     * 导致哈希链校验误判「链断裂」。
     *
     * 策略：先精确匹配（快路径），未命中再忽略大小写匹配。
     */
    private func findIndex(name: String): Int64 {
        for (i in 0..this.cols.size) {
            if (this.cols[i] == name) {
                return i
            }
        }
        for (i in 0..this.cols.size) {
            if (this.cols[i].toAsciiLower() == name.toAsciiLower()) {
                return i
            }
        }
        return -1
    }

    /**
     * 取可空字符串。
     */
    public func getOpt(name: String): Option<String> {
        let idx = this.findIndex(name)
        if (idx < 0) {
            return None
        }
        return this.vals[idx]
    }

    /**
     * 字符串转 Int64。
     *
     * 不用 Int64.parse —— 它抛异常，在解析不可信数据时不应让整个查询失败。
     */
    public static func toI64(s: String): Int64 {
        var acc: Int64 = 0
        var neg = false
        var i = 0
        let bytes = s.toArray()
        if (bytes.size == 0) {
            return 0
        }
        if (bytes[0] == 45) {
            neg = true
            i = 1
        }
        if (i >= bytes.size) {
            return 0
        }
        while (i < bytes.size) {
            let b = bytes[i]
            if (b < 48 || b > 57) {
                return 0
            }
            acc = acc * 10 + Int64(b - 48)
            i++
        }
        return if (neg) { -acc } else { acc }
    }
}

/**
 * 结果集（行集合）。
 */
public class RowSet {
    private let rows: ArrayList<RowData>

    public init() {
        this.rows = ArrayList<RowData>()
    }

    public func add(r: RowData): Unit {
        this.rows.add(r)
    }

    public func size(): Int64 {
        return this.rows.size
    }

    public func isEmpty(): Bool {
        return this.rows.isEmpty()
    }

    public func at(i: Int64): RowData {
        return this.rows[i]
    }

    public func first(): Option<RowData> {
        if (this.rows.isEmpty()) {
            return None
        }
        return Some(this.rows[0])
    }

    public func all(): ArrayList<RowData> {
        return this.rows
    }
}

/**
 * 把 QueryResult 读成 RowSet。
 *
 * 统一用 getOrNull<String>：驱动的 PGTypeMap 会把任意 PG 类型转成字符串表示，
 * NULL 返回 None。这样上层按需转型，避免逐类型写映射。
 */
public func readRows(rs: QueryResult): RowSet {
    let out = RowSet()
    let infos = rs.columnInfos
    while (rs.next()) {
        let rd = RowData()
        for (i in 0..infos.size) {
            let name = infos[i].name
            match (rs.getOrNull<String>(i)) {
                case Some(v) => rd.put(name, Some(v))
                case None => rd.put(name, None)
            }
        }
        out.add(rd)
    }
    return out
}

/**
 * 用户记录。
 */
public class UserRecord {
    public let id: Int64
    public let username: String
    public let email: String
    public let phone: String
    public let nickname: String
    public let passwordHash: String
    public let status: Int64
    public let failedAttempts: Int64
    public let lockedUntilMillis: Int64
    public let permVersion: Int64
    public let kdfCost: Int64
    public let createdAtMillis: Int64
    public let version: Int64

    public init(
        id: Int64,
        username: String,
        email: String,
        phone: String,
        nickname: String,
        passwordHash: String,
        status: Int64,
        failedAttempts: Int64,
        lockedUntilMillis: Int64,
        permVersion: Int64,
        kdfCost: Int64,
        createdAtMillis: Int64,
        version: Int64
    ) {
        this.id = id
        this.username = username
        this.email = email
        this.phone = phone
        this.nickname = nickname
        this.passwordHash = passwordHash
        this.status = status
        this.failedAttempts = failedAttempts
        this.lockedUntilMillis = lockedUntilMillis
        this.permVersion = permVersion
        this.kdfCost = kdfCost
        this.createdAtMillis = createdAtMillis
        this.version = version
    }

    /**
     * 从行数据构造。
     */
    public static func fromRow(r: RowData): UserRecord {
        return UserRecord(
            r.i64("id"),
            r.str("username"),
            r.str("email"),
            r.str("phone"),
            r.str("nickname"),
            r.str("password_hash"),
            r.i64("status"),
            r.i64("failed_attempts"),
            r.i64("locked_until_ms"),
            r.i64("perm_version"),
            r.i64("kdf_cost"),
            r.i64("created_at_ms"),
            r.i64("version")
        )
    }
}

/**
 * 用户仓储。
 */
public class UserRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 用户列表查询的公共列（不含口令哈希）。
     */
    private static let LIST_COLUMNS = "id, username, email, phone, nickname, status, " +
                                      "failed_attempts, perm_version, kdf_cost, " +
                                      "(EXTRACT(EPOCH FROM created_at) * 1000)::bigint AS created_at_ms, version"

    /**
     * 登录用的列（含口令哈希与锁定时间）。
     */
    private static let AUTH_COLUMNS = "id, username, email, phone, nickname, password_hash, status, " +
                                      "failed_attempts, " +
                                      "COALESCE((EXTRACT(EPOCH FROM locked_until) * 1000)::bigint, 0) AS locked_until_ms, " +
                                      "perm_version, kdf_cost, " +
                                      "(EXTRACT(EPOCH FROM created_at) * 1000)::bigint AS created_at_ms, version"

    /**
     * 绑定「可空文本」参数：空串按 NULL 落库。
     *
     * 不能直接 set("")：sys_users.email / phone 上有唯一部分索引
     * （WHERE email IS NOT NULL），空串会让第二个无邮箱用户撞约束。
     */
    private static func bindNullable(st: Statement, idx: Int, v: String): Unit {
        if (v.isEmpty()) {
            st.setNull(idx)
        } else {
            st.set(idx, v)
        }
    }

    /**
     * 把字符串形式的用户 ID 解析为 Int64。
     *
     * 解析失败返回 0（调用方据此判定无效主体）。
     */
    public static func parseId(uid: String): Int64 {
        var acc: Int64 = 0
        if (uid.isEmpty()) {
            return 0
        }
        for (b in uid.toArray().iterator()) {
            if (b < 48 || b > 57) {
                return 0
            }
            acc = acc * 10 + Int64(b - 48)
        }
        return acc
    }

    /**
     * 按用户名查用户（含口令哈希，用于登录校验）。
     *
     * @return 未找到返回 None
     */
    public func findByUsername(username: String): Option<UserRecord> {
        let sql = "SELECT ${UserRepo.AUTH_COLUMNS} FROM sys_users " +
                  "WHERE username = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, username)
            let rs = readRows(st.query())
            match (rs.first()) {
                case Some(r) => return Some(UserRecord.fromRow(r))
                case None => return None
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 按邮箱查用户（注册唯一性校验用，不返回口令哈希）。
     */
    public func findByEmail(email: String): Option<UserRecord> {
        let sql = "SELECT ${UserRepo.AUTH_COLUMNS} FROM sys_users " +
                  "WHERE email = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, email)
            let rs = readRows(st.query())
            match (rs.first()) {
                case Some(r) => return Some(UserRecord.fromRow(r))
                case None => return None
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 按手机号查用户（注册唯一性校验用，不返回口令哈希）。
     */
    public func findByPhone(phone: String): Option<UserRecord> {
        let sql = "SELECT ${UserRepo.AUTH_COLUMNS} FROM sys_users " +
                  "WHERE phone = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, phone)
            let rs = readRows(st.query())
            match (rs.first()) {
                case Some(r) => return Some(UserRecord.fromRow(r))
                case None => return None
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 按主键查用户（含口令哈希）。
     */
    public func findById(id: Int64): Option<UserRecord> {
        let sql = "SELECT ${UserRepo.AUTH_COLUMNS} FROM sys_users " +
                  "WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            let rs = readRows(st.query())
            match (rs.first()) {
                case Some(r) => return Some(UserRecord.fromRow(r))
                case None => return None
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 用户列表（分页）。
     *
     * @param keyword 模糊匹配用户名 / 昵称 / 邮箱；空则不过滤
     */
    public func list(keyword: String, offset: Int64, limit: Int64): RowSet {
        // LIMIT/OFFSET 只能是字面量（openGauss 不支持参数化 LIMIT），
        // 故此处用整数校验后拼接，杜绝注入。
        let lim = if (limit <= 0) { 20 } else if (limit > 200) { 200 } else { limit }
        let off = if (offset < 0) { 0 } else { offset }
        let base = "SELECT ${UserRepo.LIST_COLUMNS} FROM sys_users WHERE deleted_at IS NULL"
        let sql = if (keyword.isEmpty()) {
            "${base} ORDER BY id DESC LIMIT ${lim} OFFSET ${off}"
        } else {
            "${base} AND (username ILIKE ? OR nickname ILIKE ? OR email ILIKE ?) " +
            "ORDER BY id DESC LIMIT ${lim} OFFSET ${off}"
        }
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            if (!keyword.isEmpty()) {
                let like = "%${keyword}%"
                st.set(0, like)
                st.set(1, like)
                st.set(2, like)
            }
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 统计用户数（分页总数）。
     */
    public func count(keyword: String): Int64 {
        let base = "SELECT COUNT(*) AS n FROM sys_users WHERE deleted_at IS NULL"
        let sql = if (keyword.isEmpty()) {
            base
        } else {
            "${base} AND (username ILIKE ? OR nickname ILIKE ? OR email ILIKE ?)"
        }
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            if (!keyword.isEmpty()) {
                let like = "%${keyword}%"
                st.set(0, like)
                st.set(1, like)
                st.set(2, like)
            }
            let rs = readRows(st.query())
            match (rs.first()) {
                case Some(r) => return r.i64("n")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 创建用户。
     */
    public func create(
        username: String,
        email: Option<String>,
        phone: Option<String>,
        nickname: Option<String>,
        passwordHash: String,
        kdfCost: Int64,
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO sys_users (id, username, email, phone, nickname, password_hash, " +
                  "password_updated_at, kdf_cost, status, created_at, created_by, updated_at, updated_by) " +
                  "VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?, 0, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, username)
            // 可空列必须传 NULL 而非空串：
            //   sys_users.email / phone 上有 UNIQUE 索引（WHERE email IS NOT NULL），
            //   传空串会让第二个用户撞唯一约束（SQLSTATE 23505）。
            match (email) {
                case Some(v) => st.set(2, v)
                case None => st.setNull(2)
            }
            match (phone) {
                case Some(v) => st.set(3, v)
                case None => st.setNull(3)
            }
            match (nickname) {
                case Some(v) => st.set(4, v)
                case None => st.setNull(4)
            }
            st.set(5, passwordHash)
            st.set(6, kdfCost)
            st.set(7, operatorId)
            st.set(8, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 更新个人资料（自助修改昵称 / 邮箱 / 手机号）。
     *
     * 为什么单独一个方法而不是复用 create/update：
     *   ① 自助场景**不允许**改 status / perm_version（越权面）；
     *   ② 邮箱与手机号是「可空 + 唯一部分索引」列，
     *      空串必须写成 NULL，否则第二个用户会撞唯一约束
     *      （SQLSTATE 23505，与 create 的坑同源）；
     *   ③ 只按 id 定位，operator 恒为自己。
     *
     * @param nickname 空串 → NULL
     * @param email    空串 → NULL
     * @param phone    空串 → NULL
     * @return false = 用户不存在或已删除
     */
    public func updateProfile(
        userId: Int64,
        nickname: String,
        email: String,
        phone: String
    ): Bool {
        let sql = "UPDATE sys_users SET nickname = ?, email = ?, phone = ?, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            UserRepo.bindNullable(st, 0, nickname)
            UserRepo.bindNullable(st, 1, email)
            UserRepo.bindNullable(st, 2, phone)
            st.set(3, userId)
            st.set(4, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 更新口令哈希（重置密码 / 修改密码）。
     */
    public func updatePassword(userId: Int64, passwordHash: String, kdfCost: Int64, operatorId: Int64): Bool {
        let sql = "UPDATE sys_users SET password_hash = ?, kdf_cost = ?, " +
                  "password_updated_at = CURRENT_TIMESTAMP, failed_attempts = 0, locked_until = NULL, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, passwordHash)
            st.set(1, kdfCost)
            st.set(2, operatorId)
            st.set(3, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 记录一次登录失败（原子自增 + 达阈值锁定）。
     *
     * 阈值与锁定时长由调用方传入（与配置中心保持一致）。
     */
    public func recordLoginFailure(userId: Int64, maxAttempts: Int64, lockSeconds: Int64): Bool {
        let sql = "UPDATE sys_users SET failed_attempts = failed_attempts + 1, " +
                  "locked_until = CASE WHEN failed_attempts + 1 >= ? " +
                  "THEN CURRENT_TIMESTAMP + (? * INTERVAL '1 second') ELSE locked_until END, " +
                  "updated_at = CURRENT_TIMESTAMP, version = version + 1 " +
                  "WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, maxAttempts)
            st.set(1, lockSeconds)
            st.set(2, userId)
            st.update()
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 登录成功后清零失败计数并记录登录信息。
     */
    public func recordLoginSuccess(userId: Int64, ip: String): Bool {
        let sql = "UPDATE sys_users SET failed_attempts = 0, locked_until = NULL, " +
                  "last_login_at = CURRENT_TIMESTAMP, last_login_ip = ?, " +
                  "updated_at = CURRENT_TIMESTAMP, version = version + 1 " +
                  "WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, ip)
            st.set(1, userId)
            st.update()
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 启用 / 停用用户。
     */
    public func setStatus(userId: Int64, status: Int64, operatorId: Int64): Bool {
        let sql = "UPDATE sys_users SET status = ?, updated_at = CURRENT_TIMESTAMP, " +
                  "updated_by = ?, version = version + 1 WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, status)
            st.set(1, operatorId)
            st.set(2, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 解锁用户（清零失败计数与锁定时间）。
     */
    public func unlock(userId: Int64, operatorId: Int64): Bool {
        let sql = "UPDATE sys_users SET failed_attempts = 0, locked_until = NULL, " +
                  "updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, operatorId)
            st.set(1, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 软删除用户。
     */
    public func softDelete(userId: Int64, operatorId: Int64): Bool {
        let sql = "UPDATE sys_users SET deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP, " +
                  "updated_by = ?, version = version + 1 WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, operatorId)
            st.set(1, userId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出该用户可访问的主体 ID。
     *
     * 可访问范围 = 本人拥有的主体 + 本人被授权的主体（代管）。
     *
     * 依据（FR-ACL-006 数据归属校验）：
     *   所有档案查询强制附加 subject_id 归属条件，
     *   禁止由前端传参决定归属 —— 故此列表必须**由服务端**算出。
     */
    public func listAccessibleSubjectIds(userId: Int64): ArrayList<String> {
        let out = ArrayList<String>()
        let sql = "SELECT DISTINCT id FROM arc_subjects " +
                  "WHERE deleted_at IS NULL AND (" +
                  "  owner_id = ?" +
                  "  OR ? = ANY(custodian_ids)" +
                  ") ORDER BY id"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            st.set(1, userId)
            let rows = readRows(st.query())
            for (r in rows.all().iterator()) {
                out.add("${r.i64("id")}")
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
        return out
    }

    /**
     * 列出该用户**本人拥有**的主体 ID（不含代管）。
     *
     * 用途（FR-ACL-007 敏感度分级）：所有者对自己名下的一切天然可见，
     * 代管人则需显式授权 —— 故必须区分「拥有」与「可访问」。
     */
    public func listOwnedSubjectIds(userId: Int64): ArrayList<String> {
        let out = ArrayList<String>()
        let sql = "SELECT id FROM arc_subjects WHERE deleted_at IS NULL AND owner_id = ? ORDER BY id"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            let rows = readRows(st.query())
            for (r in rows.all().iterator()) {
                out.add("${r.i64("id")}")
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
        return out
    }

    /**
     * 该用户的数据可见上限（取所有角色的最大值）。
     *
     * 角色本身的数据可见上限由 sys_roles.max_data_level 定义；
     * 多角色取最大值（更宽松者生效）。
     */
    public func maxDataLevel(userId: Int64): Int64 {
        let sql = "SELECT COALESCE(MAX(r.max_data_level), 0) FROM sys_user_roles ur " +
                  "JOIN sys_roles r ON r.id = ur.role_id " +
                  "WHERE ur.user_id = ? AND (ur.expires_at IS NULL OR ur.expires_at > CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return 0
            }
            return rows.at(0).i64("coalesce")
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出该用户收到的全部临时授权。
     *
     * 包含已撤销与已过期的 —— 有效期判定在判定时进行
     * （FR-ACL-009：到期自动失效由**服务端校验**，不依赖定时任务）。
     */
    public func listGrantsForUser(userId: Int64): RowSet {
        // 时间戳**由数据库换算为 epoch 毫秒** —— 不在应用层解析 TIMESTAMPTZ
        // 字符串（会踩时区与格式的坑）。
        let sql = "SELECT id, subject_id, item_id, category, grantee_id, perm_codes, " +
                  "granted_by, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM expires_at) * 1000, 0) AS BIGINT) AS expires_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM revoked_at) * 1000, 0) AS BIGINT) AS revoked_ms " +
                  "FROM acl_grants WHERE grantee_id = ? ORDER BY granted_at DESC"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 查询距上次修改口令已过的毫秒数（从未改过返回 0）。
     *
     * 用于 FR-AUTH-004 的「两次修改间隔 ≥ N 小时」校验。
     *
     * 实现说明：时间差**由数据库计算**（EXTRACT(EPOCH FROM ...)），
     * 不在应用层解析 TIMESTAMPTZ 字符串 —— 后者会踩时区与格式的坑。
     */
    public func millisSincePasswordUpdate(userId: Int64): Int64 {
        let sql = "SELECT CAST(COALESCE(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - password_updated_at)) * 1000, 0) AS BIGINT) " +
                  "AS elapsed_ms FROM sys_users WHERE id = ? AND deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return 0
            }
            return rows.at(0).i64("elapsed_ms")
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}

/**
 * 角色 / 权限仓储。
 */
public class RoleRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }


    /**
     * 列出全部权限点。
     */
    public func listPerms(): RowSet {
        let sql = "SELECT id, code, name, domain, action, scope, is_sensitive, description " +
                  "FROM sys_perms ORDER BY domain, action, code"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出全部角色。
     */
    public func listRoles(): RowSet {
        let sql = "SELECT id, code, name, is_builtin, description, max_data_level, version " +
                  "FROM sys_roles WHERE deleted_at IS NULL ORDER BY id"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 取某用户的全部权限码（经角色聚合）。
     *
     * 这是授权判定的数据来源：authz 层拿到的 permSet 就是它的结果。
     */
    public func listUserPermCodes(userId: Int64): ArrayList<String> {
        let sql = "SELECT DISTINCT p.code FROM sys_user_roles ur " +
                  "JOIN sys_roles r ON r.id = ur.role_id AND r.deleted_at IS NULL " +
                  "JOIN sys_role_perms rp ON rp.role_id = r.id " +
                  "JOIN sys_perms p ON p.id = rp.perm_id " +
                  "WHERE ur.user_id = ? " +
                  "AND (ur.expires_at IS NULL OR ur.expires_at > CURRENT_TIMESTAMP)"
        return this.queryStrings(sql, userId)
    }

    /**
     * 取某用户绑定的角色码。
     */
    public func listUserRoleCodes(userId: Int64): ArrayList<String> {
        let sql = "SELECT r.code FROM sys_user_roles ur " +
                  "JOIN sys_roles r ON r.id = ur.role_id AND r.deleted_at IS NULL " +
                  "WHERE ur.user_id = ? " +
                  "AND (ur.expires_at IS NULL OR ur.expires_at > CURRENT_TIMESTAMP)"
        return this.queryStrings(sql, userId)
    }

    /**
     * 取某角色的权限码列表。
     */
    public func listRolePermCodes(roleCode: String): ArrayList<String> {
        let sql = "SELECT p.code FROM sys_roles r " +
                  "JOIN sys_role_perms rp ON rp.role_id = r.id " +
                  "JOIN sys_perms p ON p.id = rp.perm_id " +
                  "WHERE r.code = ? AND r.deleted_at IS NULL"
        return this.queryStrings(sql, roleCode)
    }

    /**
     * 通用单参数查询，返回第一列的字符串集合。
     *
     * 用泛型而非重载 —— 仓颉 1.2.0 不支持同名方法重载。
     * 参数类型由调用点推断（String / Int64 均可）。
     */
    private func queryStrings<T>(sql: String, param: T): ArrayList<String> {
        let out = ArrayList<String>()
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, param)
            let rs = readRows(st.query())
            for (r in rs.all().iterator()) {
                out.add(r.str("code"))
            }
            return out
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 给角色分配权限（全量覆盖）。
     *
     * @param permCodes 权限码列表；先删旧映射再插新映射
     */
    public func assignPerms(roleCode: String, permCodes: ArrayList<String>, operatorId: Int64): Bool {
        let c = this.db.connect()
        try {
            // 查 role_id
            let q = c.prepareStatement("SELECT id FROM sys_roles WHERE code = ? AND deleted_at IS NULL")
            // 参数下标 0-based（与全仓其他仓库一致；原为 1-based，导致越界 DATABASE_FAILURE）
            q.set(0, roleCode)
            let rs = readRows(q.query())
            var roleId: Int64 = 0
            match (rs.first()) {
                case Some(r) => roleId = r.i64("id")
                case None => return false
            }

            let del = c.prepareStatement("DELETE FROM sys_role_perms WHERE role_id = ?")
            del.set(0, roleId)
            del.update()

            for (code in permCodes.iterator()) {
                let ins = c.prepareStatement(
                    "INSERT INTO sys_role_perms (id, role_id, perm_id) " +
                    "SELECT ?, ?, id FROM sys_perms WHERE code = ?"
                )
                ins.set(0, Ids.next())
                ins.set(1, roleId)
                ins.set(2, code)
                ins.update()
            }
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ==================== RBAC 管理闭环（FR-ACL-002 / FR-ACL-004 / FR-ACL-008） ====================

    /**
     * 创建自定义角色（FR-ACL-002）。
     * 内置角色（is_builtin）不可覆盖；uk_sys_roles_code 唯一约束防重复。
     */
    public func createRole(
        code: String, name: String, description: String,
        maxDataLevel: Int64, parentRoleId: Int64, operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO sys_roles (id, code, name, is_builtin, description, " +
                  "max_data_level, parent_role_id, created_at, created_by, updated_at, updated_by) " +
                  "VALUES (?, ?, ?, FALSE, ?, ?, ?, CURRENT_TIMESTAMP, ?, CURRENT_TIMESTAMP, ?)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, code)
            st.set(2, name)
            if (description.isEmpty()) {
                st.setNull(3)
            } else {
                st.set(3, description)
            }
            st.set(4, maxDataLevel)
            if (parentRoleId <= 0) {
                st.setNull(5)
            } else {
                st.set(5, parentRoleId)
            }
            st.set(6, operatorId)
            st.set(7, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 更新自定义角色（FR-ACL-002）。内置角色不可改。
     */
    public func updateRole(
        code: String, name: String, description: String,
        maxDataLevel: Int64, parentRoleId: Int64, operatorId: Int64
    ): Bool {
        let sql = "UPDATE sys_roles SET name = ?, description = ?, max_data_level = ?, " +
                  "parent_role_id = ?, updated_at = CURRENT_TIMESTAMP, updated_by = ?, version = version + 1 " +
                  "WHERE code = ? AND deleted_at IS NULL AND is_builtin = FALSE"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, name)
            if (description.isEmpty()) {
                st.setNull(1)
            } else {
                st.set(1, description)
            }
            st.set(2, maxDataLevel)
            if (parentRoleId <= 0) {
                st.setNull(3)
            } else {
                st.set(3, parentRoleId)
            }
            st.set(4, operatorId)
            st.set(5, code)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 软删除自定义角色（FR-ACL-002）。内置角色不可删。
     */
    public func deleteRole(code: String, operatorId: Int64): Bool {
        let sql = "UPDATE sys_roles SET deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP, " +
                  "updated_by = ?, version = version + 1 " +
                  "WHERE code = ? AND deleted_at IS NULL AND is_builtin = FALSE"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, operatorId)
            st.set(1, code)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 为用户分配角色（FR-ACL-004）。
     * 支持按主体（subject_id）与分类（category）限定授权范围。
     * uk_sys_user_roles(user_id, role_id, COALESCE(subject_id,0)) 防重复分配。
     */
    public func assignUserRole(
        userId: Int64, roleCode: String, subjectId: Int64,
        category: Int64, grantedBy: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO sys_user_roles (id, user_id, role_id, subject_id, category, granted_by) " +
                  "SELECT ?, ?, r.id, ?, ?, ? FROM sys_roles r " +
                  "WHERE r.code = ? AND r.deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, userId)
            if (subjectId <= 0) {
                st.setNull(2)
            } else {
                st.set(2, subjectId)
            }
            st.set(3, if (category < 0) { 0 } else { category })
            st.set(4, grantedBy)
            st.set(5, roleCode)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 撤销用户角色（FR-ACL-004）。
     */
    public func revokeUserRole(userId: Int64, roleCode: String, subjectId: Int64): Bool {
        let sql = "DELETE FROM sys_user_roles " +
                  "WHERE role_id = (SELECT id FROM sys_roles WHERE code = ? AND deleted_at IS NULL) " +
                  "AND user_id = ? AND COALESCE(subject_id, 0) = COALESCE(?, 0)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, roleCode)
            st.set(1, userId)
            if (subjectId <= 0) {
                st.setNull(2)
            } else {
                st.set(2, subjectId)
            }
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出某用户的角色分配（FR-ACL-004）。含主体与分类限定。
     */
    public func listUserRoles(userId: Int64): RowSet {
        let sql = "SELECT r.code, r.name, ur.subject_id, ur.category, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM ur.expires_at) * 1000, 0) AS BIGINT) AS expires_ms " +
                  "FROM sys_user_roles ur JOIN sys_roles r ON r.id = ur.role_id " +
                  "WHERE ur.user_id = ? AND r.deleted_at IS NULL ORDER BY r.code"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, userId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ==================== 显式授权 Grant（FR-ACL-008） ====================

    /**
     * 创建一条临时授权（FR-ACL-008）。perm_codes 以逗号拼接存入 VARCHAR(512)。
     */
    public func createGrant(
        subjectId: Int64, itemId: Int64, category: Int64,
        granteeId: Int64, permCodes: String, grantedBy: Int64, expiresAt: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO acl_grants (id, subject_id, item_id, category, grantee_id, " +
                  "perm_codes, granted_by, expires_at) " +
                  "VALUES (?, ?, ?, ?, ?, ?, ?, to_timestamp(?))"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, subjectId)
            if (itemId <= 0) {
                st.setNull(2)
            } else {
                st.set(2, itemId)
            }
            st.set(3, if (category < 0) { 0 } else { category })
            st.set(4, granteeId)
            st.set(5, permCodes)
            st.set(6, grantedBy)
            if (expiresAt <= 0) {
                st.setNull(7)
            } else {
                st.set(7, expiresAt / 1000)
            }
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 撤销授权（FR-ACL-008 / FR-ACL-009）。仅置 revoked_at，保留记录用于审计。
     */
    public func revokeGrant(grantId: Int64, operatorId: Int64): Bool {
        let sql = "UPDATE acl_grants SET revoked_at = CURRENT_TIMESTAMP, revoke_reason = 'manual' " +
                  "WHERE id = ? AND revoked_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, grantId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出某用户收到的全部授权（FR-ACL-008）。含已撤销/已过期（由判定方过滤）。
     */
    public func listGrantsByGrantee(granteeId: Int64): RowSet {
        let sql = "SELECT id, subject_id, item_id, category, perm_codes, granted_by, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM expires_at) * 1000, 0) AS BIGINT) AS expires_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM revoked_at) * 1000, 0) AS BIGINT) AS revoked_ms " +
                  "FROM acl_grants WHERE grantee_id = ? ORDER BY granted_at DESC"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, granteeId)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}
