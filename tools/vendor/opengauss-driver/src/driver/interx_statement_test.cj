package cangjie_tpc::opengauss.driver

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.*
import std.time.*
import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.interx.*


class StmtInterceptorTest <: StmtInterceptorInteface {
    public var is_query_start = false
    public var is_query_success = false
    public var is_query_exception = false
    public var is_update_start = false
    public var is_update_success = false
    public var is_update_exception = false

    public func name(): String {
        return "StmtInterceptorTest"
    }
    public func priority(): Int32 {
        return 0
    }

    public func queryStart(context: StmtInterceptorContext): Unit {
        is_query_start = true
    }
    public func querySuccess(context: StmtInterceptorContext): Unit {
        is_query_success = true
    }
    public func queryException(context: StmtInterceptorContext, ex: Exception): Unit {
        is_query_exception = true
    }
    public func updateStart(context: StmtInterceptorContext): Unit {
        is_update_start = true
    }
    public func updateSuccess(context: StmtInterceptorContext): Unit {
        is_update_success = true
    }
    public func updateException(context: StmtInterceptorContext, ex: Exception): Unit{
        is_update_exception = true
    }
}

func do_query_single(cn: Connection): Unit {
    let sql = "select id, updatetime, text1 from simpletest1 limit 1"
    try (st = cn.prepareStatement(sql)) {
        let qr = st.query()
        var id = ""
        
        while (qr.next()) {
            id = qr.get<String>(1)
        }
        qr.close()
    } catch (e: Exception) {
        e.printStackTrace()
    }
}

func do_error_query(cn: Connection): Unit {
    let sql = "select id, updatetime, text1 from simpletest11 limit 1"
    try (st = cn.prepareStatement(sql)) {
        let qr = st.query()
        var id = ""
        
        while (qr.next()) {
            id = qr.get<String>(1)
        }
        qr.close()
    } catch (e: Exception) {
        // e.printStackTrace()
    }
}

func do_insert(cn: Connection): Unit {
    let sql = "INSERT INTO some_types (created_at,updated_at,deleted_at,source) VALUES (?,?,NULL,?) RETURNING id"
    try (st = cn.prepareStatement(sql)) {
        let create_at = DateTime.now()
        let updated_at = DateTime.now()
        let source = "walawala"

        st.set<DateTime>(0, create_at)
        st.set<DateTime>(1, updated_at)
        st.set<String>(2, source)
        let ur = st.update()
        println("${ur.rowCount}, ${ur.lastInsertId}")
    } catch (e: Exception) {
        e.printStackTrace()
    }
}

func do_error_insert(cn: Connection): Unit {
    let sql = "INSERT INTO some_types10 (created_at,updated_at,deleted_at,source) VALUES (?,?,NULL,?) RETURNING id"
    try (st = cn.prepareStatement(sql)) {
        let create_at = DateTime.now()
        let updated_at = DateTime.now()
        let source = "walawala"

        st.set<DateTime>(0, create_at)
        st.set<DateTime>(1, updated_at)
        st.set<String>(2, source)
        let ur = st.update()
        println("${ur.rowCount}, ${ur.lastInsertId}")
    } catch (e: Exception) {
        // e.printStackTrace()
    }
}

@Test
func testStmtInterceptorTest() {
    enableInterceptor()
    let stmt_interx = StmtInterceptorTest()
    StmtInterceptorManager.instance().registerInterceptor(stmt_interx)

    loadDefaultEnv()
    var url = getEnvString("connectionString")
    let drv = DriverManager.getDriver("opengauss") ?? return
    let ds = drv.open(url)
    try (cn = ds.connect()) {
        do_query_single(cn)
    }
    @Assert(stmt_interx.is_query_start)
    @Assert(stmt_interx.is_query_success)

    try (cn = ds.connect()) {
        do_error_query(cn)
    }
    @Assert(stmt_interx.is_query_exception)

    try (cn = ds.connect()) {
        do_insert(cn)
    }
    @Assert(stmt_interx.is_update_start)
    @Assert(stmt_interx.is_update_success)

    try (cn = ds.connect()) {
        do_error_insert(cn)
    }
    @Assert(stmt_interx.is_update_exception)

    StmtInterceptorManager.instance().unregisterInterceptor(stmt_interx.name())
    @Assert(0 == StmtInterceptorManager.instance().listInterceptors().size)
}




