package cangjie_tpc::opengauss.driver

import std.unittest.*
import std.unittest.testmacro.*
import std.database.sql.*
import std.convert.*
import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.url.*
import cangjie_tpc::opengauss.interx.*


class ServerUserPasswordInterceptorTest <: ServerUserPasswordInterceptorInteface {
    public func name(): String {
        return "ServerUserPasswordInterceptorTest"
    }
    public func priority(): Int32 {
        return 0
    }

    public func getServerUserPassword(context: ServerUserPasswordInterceptorContext): ?(String, String) {
        loadDefaultEnv()
        var connstr = getEnvString("connectionString")

        if (let Some(url) <- Parser.parseURI(connstr)) {
            return (url.authority.userinfo.username, url.authority.userinfo.password)
        }

        return Option<(String, String)>.None
    }
}


@Test
func testServerUserPasswordInterceptorTest() {
    enableInterceptor()
    let user_interx = ServerUserPasswordInterceptorTest()
    ServerUserPasswordInterceptorManager.instance().registerInterceptor(user_interx)

    loadDefaultEnv()
    var url = getEnvString("connectionString")
    let drv = DriverManager.getDriver("opengauss") ?? return
    let ds = drv.open(url)
    try (cn = ds.connect()) {
        @Assert(ConnectionState.Connected == cn.state)        
    }

    ServerUserPasswordInterceptorManager.instance().unregisterInterceptor(user_interx.name())
    @Assert(0 == ServerUserPasswordInterceptorManager.instance().listInterceptors().size)
}



