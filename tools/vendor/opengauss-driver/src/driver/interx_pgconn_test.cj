package cangjie_tpc::opengauss.driver

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.*
import std.time.*
import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.interx.*

class PgConnInterceptorTest <: PgConnInterceptorInteface {
    public var is_connect_start = false
    public var is_connect_success = false
    public var is_connect_exception = false
    public var is_connect_close = false

    public func name(): String {
        return "PgConnInterceptorTest"
    }
    public func priority(): Int32 {
        return 0
    }

    public func connectStart(context: PgConnInterceptorContext): Unit {
        is_connect_start = true
    }
    public func connectSuccess(context: PgConnInterceptorContext): Unit {
        is_connect_success = true
    }
    public func connectException(context: PgConnInterceptorContext, ex: Exception): Unit {
        is_connect_exception = true
    }
    public func close(context: PgConnInterceptorContext): Unit {
        is_connect_close = true
    }
}


@Test
func testPgConnInterceptorTest() {
    enableInterceptor()
    let pg_conn_interx = PgConnInterceptorTest()
    PgConnInterceptorManager.instance().registerInterceptor(pg_conn_interx)

    loadDefaultEnv()
    var url = getEnvString("connectionString")
    var drv = DriverManager.getDriver("opengauss") ?? return
    var ds = drv.open(url)
    try (cn = ds.connect()) {}
    @Assert(pg_conn_interx.is_connect_start)
    @Assert(pg_conn_interx.is_connect_success)
    @Assert(pg_conn_interx.is_connect_close)

    // url = "opengauss://gorm:pass@127.0.0.1:5432/loggable?sslmode=disable"
    // drv = DriverManager.getDriver("opengauss") ?? return
    // ds = drv.open(url)
    // try (cn = ds.connect()) {}
    // @Assert(pg_conn_interx.is_connect_exception)

    PgConnInterceptorManager.instance().unregisterInterceptor(pg_conn_interx.name())
    @Assert(0 == PgConnInterceptorManager.instance().listInterceptors().size)
}

