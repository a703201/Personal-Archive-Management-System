package cangjie_tpc::opengauss.driver

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.*
import std.convert.*
import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.url.*
import cangjie_tpc::opengauss.interx.*


class ServerAddrInterceptorTest <: ServerAddrInterceptorInteface {
    public func name(): String {
        return "ServerAddrInterceptorTest"
    }
    public func priority(): Int32 {
        return 0
    }

    public func getServerAddr(context: ServerAddrInterceptorContext): ?(String, UInt16) {
        loadDefaultEnv()
        var connstr = getEnvString("connectionString")

        if (let Some(url) <- Parser.parseURI(connstr)) {
            let port = UInt16.tryParse(url.authority.port) ?? 0
            return (url.authority.hostname, port)
        }

        return Option<(String, UInt16)>.None
    }
}


@Test
func testServerAddrInterceptorTest() {
    enableInterceptor()
    let pg_conn_interx = ServerAddrInterceptorTest()
    ServerAddrInterceptorManager.instance().registerInterceptor(pg_conn_interx)

    loadDefaultEnv()
    var url = getEnvString("connectionString")
    let drv = DriverManager.getDriver("opengauss") ?? return
    let ds = drv.open(url)
    try (cn = ds.connect()) {
        @Assert(ConnectionState.Connected == cn.state)        
    }

    ServerAddrInterceptorManager.instance().unregisterInterceptor(pg_conn_interx.name())
    @Assert(0 == ServerAddrInterceptorManager.instance().listInterceptors().size)
}



