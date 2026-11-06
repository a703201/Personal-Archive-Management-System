package cangjie_tpc::opengauss.driver

import std.unittest.*
import std.unittest.testmacro.*
import std.sync.*
import std.time.*
import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.sqlpool.{PooledDatasource as P, ProxyConnection as PC}

@Test
public class TestSqlPool {

    @TestCase
    func testSqlPool1(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                @Assert(false)
                return
        }
        let ds = drv.open(url)
        var pool = P(ds)
        var conn = pool.connect()
        @Assert(!conn.isClosed())        
        conn.close()

        let conn1Opt = pool.connect() as PC
        @Assert(conn1Opt.isSome())
        conn1Opt.getOrThrow().discard()

        pool.setOption("defaultMaxIdleTimeout", "100")
        pool.closeAllConn()
        pool.close()
        @Assert(0 == pool.openConns)
        @Assert(0 == pool.idleConns)
        @Assert(0 == pool.usedConn)
    }

    @TestCase
    func testSqlPool2(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                @Assert(false)
                return
        }
        let ds = drv.open(url)

        let config = PoolConfig(1i32, 10i32, Duration.minute * 5, Duration.minute * 30, Duration.minute * 10)
        var pool = P(ds, config)
        var conn = pool.connect()
        @Assert(!conn.isClosed())

        var transaction = conn.createTransaction()
        transaction.begin()
        conn.getMetaData()
        var statment = conn.prepareStatement("select count(*) from simpletest1")
        var result = statment.query()
        @Assert(result.next())

        statment.close()        
        transaction.commit()
        conn.close()      
    }

    @TestCase
    func testSqlPool3(): Unit {
        loadDefaultEnv()
        var url = getEnvString("connectionString")
        let drvopt = DriverManager.getDriver("opengauss")
        var drv: Driver
        match (drvopt) {
            case Some(v) => drv = v
            case None =>
                @Assert(false)
                return
        }
        let ds = drv.open(url)

        var config = PoolConfig(10i32, 10i32, Duration.second * 1, Duration.second * 1, Duration.second * 1)
        var pool = P(ds, config)
        sleep(Duration.second * 2)
        pool.close()
        @Assert(pool.isClosed())
    }

}


