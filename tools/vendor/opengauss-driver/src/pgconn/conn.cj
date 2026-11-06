/**
 * Copyright (c) [2022] Huawei Technologies Co., Ltd.
 * [opengauss-driver] is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *            http://license.coscl.org.cn/MulanPSL2
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS,
 * WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 * See the Mulan PSL v2 for more details.
 */
package cangjie_tpc::opengauss.pgconn

internal import std.convert.*
internal import cangjie_tpc::opengauss.slog.*
internal import std.math.*
internal import std.net.*
internal import std.database.sql.*
internal import std.sync.AtomicInt64
import std.sync.*
import std.collection.*
import std.time.*
import stdx.net.tls.*
internal import cangjie_tpc::opengauss.proto3.*
internal import cangjie_tpc::opengauss.error.*
import cangjie_tpc::opengauss.proto3
import cangjie_tpc::opengauss.slog
import cangjie_tpc::opengauss.utils.*
import cangjie_tpc::opengauss.interx.*

let logger = slog.Default()

public enum ConnStatus <: Equatable<ConnStatus> {
    | Uninitialized
    | Connecting
    | Closed
    | Idle
    | Busy

    public func value(): UInt8 {
        match (this) {
            case Uninitialized => 0
            case Connecting => 1
            case Closed => 2
            case Idle => 3
            case Busy => 4
        }
    }

    public operator func ==(rhs: ConnStatus): Bool {
        return this.value() == rhs.value()
    }
    public operator func !=(rhs: ConnStatus): Bool {
        return this.value() != rhs.value()
    }
}

func startTls(socket: StreamingSocket, tlscfg: TlsClientConfig): TlsSocket {
    let sslReq = SSLRequest()
    socket.write(sslReq.encode())
    socket.flush()
    logger.debug("send sslReq ${sslReq}")
    let buf = Array<UInt8>(1, repeat: 0)
    let len = socket.read(buf)
    if (len != 1) {
        throw SqlException("server not response SSLRequest")
    }
    if (buf[0] != b'S') {
        throw SqlException("server refused TLS connection")
    }

    let conn = TlsSocket.client(socket, session: None, clientConfig: tlscfg)
    return conn
}

let nextConnId = AtomicInt64(1)

public func connect(config: Config, info: String): (PgConn, Int32) {
    var ignoreAddrs = HashMap<String, String>()
    var interceptorAddrs = HashMap<String, String>()
    var connId = nextConnId.fetchAdd(1)
    var addr = getServerAddr(config, ignoreAddrs, interceptorAddrs)
    var threadid = getCurrentThreadId()
    var context = PgConnInterceptorContext(connId, threadid, addr[0], addr[1])
    while (true) {
        var interceptorenabled = PgConnInterceptorManager.instance().isInterceptorEnable()
        try {
            if (interceptorenabled) {
                PgConnInterceptorManager.instance().connectStart(context)
            }
            var ret = connect(connId, config, addr[0], addr[1], addr[2], info)
            if (interceptorenabled) {
                PgConnInterceptorManager.instance().connectSuccess(context)
            }
            return ret
        } catch (ex: Exception) {
            logger.debug(
                "connect ${addr[0]}:${addr[1]} with timeout ${config.connTimeout} ${info} error. ${ex.toString()}")
            if (interceptorenabled) {
                PgConnInterceptorManager.instance().connectException(context, ex)
            }
            if (addr[3]) {
                // interceptor返回的地址
                interceptorAddrs["${addr[0]}:${addr[1]}"] = "${ex.toString()}"
            } else {
                ignoreAddrs["${addr[0]}:${addr[1]}"] = "${ex.toString()}"
                if (ignoreAddrs.size >= config.addrs.size) {
                    // 所有地址连接都有问题
                    if (config.addrs.size >= 1) {
                        var exstrs = ""
                        for ((addrkey, exstr) in ignoreAddrs) {
                            exstrs += "${addrkey}: ${exstr}\n"
                        }
                        throw SqlException(exstrs)
                    } else {
                        throw ex
                    }
                }
            }
            addr = getServerAddr(config, ignoreAddrs, interceptorAddrs)
            context = PgConnInterceptorContext(connId, threadid, addr[0], addr[1])
        }
    }

    // 应该到不了这里，补上这行语句是为了避免编译问题
    throw SqlException("connect error")
}

public func connectDirect(config: Config, host: String, port: UInt16, info: String): (PgConn, Int32) {
    var connId = nextConnId.fetchAdd(1)
    var threadid = getCurrentThreadId()
    var context = PgConnInterceptorContext(connId, threadid, host, port)
    var interceptorenabled = PgConnInterceptorManager.instance().isInterceptorEnable()
    try {
        if (interceptorenabled) {
            PgConnInterceptorManager.instance().connectStart(context)
        }
        var (pgConn, index) = connect(connId, config, host, port, 0i32, info)
        if (interceptorenabled) {
            PgConnInterceptorManager.instance().connectSuccess(context)
        }
        pgConn.setUseCurAddrOnly(true)
        return (pgConn, index)
    } catch (ex: Exception) {
        if (interceptorenabled) {
            PgConnInterceptorManager.instance().connectException(context, ex)
        }
        throw ex
    }
}

func connect(connId: Int64, config: Config, host: String, port: UInt16, index: Int32, info: String): (PgConn, Int32) {
    var socket: StreamingSocket
    if(config.udsfile.trimAscii().isEmpty()) {
        socket = connect(config, host, port, info)
    } else {
        // 通过UnixSocket连接数据库
        socket = connect(config, config.udsfile.trimAscii(), info)
    }
    let pgConn = PgConn(connId, config, socket, host, port, index)
    pgConn.startup()
    return (pgConn, index)
}

func setSocketOps(socket: TcpSocket, config: Config, host: String, port: UInt16) {
    match (config.readTimeout) {
        case Some(v) =>
            if (v.toMicroseconds() > 0) {
                socket.readTimeout = v
                logger.debug("${host}:${port} readTimeout=${v}")
            }
        case _ => ()
    }
    match (config.writeTimeout) {
        case Some(v) =>
            if (v.toMicroseconds() > 0) {
                socket.writeTimeout = v
                logger.debug("${host}:${port} writeTimeout=${v}")
            }
        case _ => ()
    }
    match (config.sendBufferSize) {
        case Some(v) =>
            if (v > 0) {
                socket.sendBufferSize = v
                logger.debug("${host}:${port} sendBufferSize=${v}")
            }
        case _ => ()
    }
    match (config.receiveBufferSize) {
        case Some(v) =>
            if (v > 0) {
                socket.receiveBufferSize = v
                logger.debug("${host}:${port} receiveBufferSize=${v}")
            }
        case _ => ()
    }
}

func setSocketOps(socket: UnixSocket, config: Config, uds: String) {
    match(config.readTimeout) {
        case Some(v) => 
            if (v.toMicroseconds() > 0) {
                socket.readTimeout = v
                logger.debug("${uds} readTimeout=${v}")
            }
        case _ => ()
    }
    match(config.writeTimeout) {
        case Some(v) => 
            if (v.toMicroseconds() > 0) {
                socket.writeTimeout = v
                logger.debug("${uds} writeTimeout=${v}")
            }
        case _ => ()
    }
    match(config.sendBufferSize) {
        case Some(v) => 
            if (v > 0) {
                socket.sendBufferSize = v
                logger.debug("${uds} sendBufferSize=${v}")
            }
        case _ => ()
    }
    match(config.receiveBufferSize) {
        case Some(v) => 
            if (v > 0) {
                socket.receiveBufferSize = v
                logger.debug("${uds} receiveBufferSize=${v}")
            }
        case _ => ()
    }
}

func connect(config: Config, selectedhost: String, selectedport: UInt16, info: String): StreamingSocket {
    logger.debug("connect ${selectedhost}:${selectedport} with timeout ${config.connTimeout} ${info}")
    var socket = TcpSocket(selectedhost, selectedport)
    setSocketOps(socket, config, selectedhost, selectedport)
    socket.connect(timeout: config.connTimeout)
    var conn: StreamingSocket
    if (let Some(tlscfg) <- config.tlsconfig) {
        try {
            let tls = startTls(socket, tlscfg)
            tls.handshake(timeout: config.connTimeout)
            conn = tls
        } catch (ex: Exception) {
            if (config.sslmode == "prefer") {
                logger.debug(
                    "cannot connect ${selectedhost}:${selectedport} with ssl. ${ex.toString()}\ntry to connect without ssl"
                )
                socket.close()
                socket = TcpSocket(selectedhost, selectedport)
                setSocketOps(socket, config, selectedhost, selectedport)
                socket.connect(timeout: config.connTimeout)
                conn = socket
            } else {
                throw ex
            }
        }
    } else {
        conn = socket
    }
    return conn
}

func connect(config: Config, udsfile: String, info: String): StreamingSocket {
    logger.debug("connect ${config.host}:${config.port} by ${udsfile} with timeout ${config.connTimeout} ${info}")
    var socket = UnixSocket(udsfile)
    setSocketOps(socket, config, udsfile)
    socket.connect(timeout: config.connTimeout)
    var conn: StreamingSocket
    if (let Some(tlscfg) <- config.tlsconfig) {
        try {
            let tls = startTls(socket, tlscfg)
            tls.handshake(timeout: config.connTimeout)
            conn = tls
        } catch (ex: Exception) {
            if (config.sslmode == "prefer") {
                logger.debug(
                    "cannot connect server by ${udsfile} with ssl. ${ex.toString()}\ntry to connect without ssl"
                )
                socket.close()
                socket = UnixSocket(udsfile)
                setSocketOps(socket, config, udsfile)
                socket.connect(timeout: config.connTimeout)
                conn = socket
            } else {
                throw ex
            }
        }
    } else {
        conn = socket
    }
    return conn
}

func getServerAddr(config: Config, ignoreAddrs: Map<String, String>, errorInterceptorAddrs: Map<String, String>): (String, 
    UInt16, Int32, Bool) {
    // 返回值格式，(地址, 端口, config地址的索引, 是否是插件返回的地址)
    var addrs = ArrayList<(String, UInt16)>()
    if (!config.udsfile.trimAscii().isEmpty()) {
        // 指定了unix domain socket文件
        if (config.addrs.size > 1) {
            logger.warn("only one address(${config.host}:${config.port}) will be used when the unix_domain_socket parameter is set")
            config.addrs.clear()
            config.addrs.add((config.host, config.port))
        }
        return (config.host, config.port, 0, false)
    }
    if (config.addrs.size > 0) {
        addrs.add(all: config.addrs)
    } else {
        addrs.add((config.host, config.port))
    }
    var context = ServerAddrInterceptorContext(addrs, ignoreAddrs, errorInterceptorAddrs)
    if (ServerAddrInterceptorManager.instance().isInterceptorEnable()) {
        match (ServerAddrInterceptorManager.instance().getServerAddr(context)) {
            case Some(v) =>
                // 返回服务地址插件的地址，index为0
                return (v[0], v[1], 0, true)
            case _ =>
                // ServerAddrInterceptor没有返回，那么正常进行操作
                ()
        }
    }
    match (getPriorityAddr(config, ignoreAddrs)) {
        // 首先获取优先级高的服务
        case Some(v) => return v
        case _ =>
            // 如果没有优先级高的服务，那么返回符合规则的服务
            match (config.balance) {
            case LEASTCONN => return getLeastConnServerAddr(config, ignoreAddrs)
            case ROUNDROBIN => return getNextServerAddr(config, ignoreAddrs)
            case _ => throw SqlException("invalid balance type(${config.balance.value()})")
        }
    }
}

func getNextServerAddr(config: Config, ignoreAddrs: Map<String, String>): (String, UInt16, Int32, Bool) {
    if (config.addrs.size > 0) {
        var initIndex = ConnManager.instance().nextConnectionIndex() % config.addrs.size
        var index = initIndex
        var addr = config.addrs[index]
        while (ignoreAddrs.contains("${addr[0]}:${addr[1]}")) {
            index = (index + 1) % config.addrs.size
            if (index == initIndex) {
                // 已经一轮了，还没有合适的地址，返回config中的地址
                return (config.host, config.port, 0i32, false)
            }
            addr = config.addrs[index]
        }
        return (addr[0], addr[1], Int32(index), false)
    } else {
        return (config.host, config.port, 0i32, false)
    }
}

func getLeastConnServerAddr(config: Config, ignoreAddrs: Map<String, String>): (String, UInt16, Int32, Bool) {
    if (config.addrs.size > 0) {
        var leastConnIndex = -1i32
        var leastConnCount = 999999i32
        var tmpConnCount = 0i32
        var index = 0i32
        for (addr in config.addrs) {
            if (!ignoreAddrs.contains("${addr[0]}:${addr[1]}")) {
                tmpConnCount = ConnManager.instance().count(addr[0], addr[1])

                if (tmpConnCount < leastConnCount) {
                    leastConnIndex = index
                    leastConnCount = tmpConnCount
                }
            }
            index++
        }
        if (leastConnIndex == -1) {
            // 没有符合要求的，返回config中的地址
            return (config.host, config.port, 0i32, false)
        } else {
            let addr = config.addrs[Int64(leastConnIndex)]
            return (addr[0], addr[1], index, false)
        }
    } else {
        return (config.host, config.port, 0i32, false)
    }
}

func getPriorityAddr(config: Config, ignoreAddrs: Map<String, String>): ?(String, UInt16, Int32, Bool) {
    var index = 0i32
    for (addr in config.addrs) {
        if (!ignoreAddrs.contains("${addr[0]}:${addr[1]}")) {
            if (config.priorityaddrs.contains("${addr[0]}:${addr[1]}")) {
                return (addr[0], addr[1], index, false)
            }
        }
        index++
    }
    return Option<(String, UInt16, Int32, Bool)>.None
}

let objIdSeed = AtomicInt64(1)
const DEFAULT_IS_MASTER_CACHE_INVALID_TIME = 600000

public class PgConn {
    let connId: Int64
    var config: Config
    var fb: Frontend
    var socket: StreamingSocket
    var pid: Int32 = 0
    var secretKey: Int32 = 0
    var params = HashMap<String, String>()
    var txStatus: Byte = b'I'
    var namei = AtomicInt64(1)
    var peekedMsg: ?proto3.BackendMessage = None
    var status = ConnStatus.Connecting
    let statusMtx = Mutex()
    var statusStatement: String = ""
    let objId = objIdSeed.fetchAdd(1)
    let maxNoticeCount = 100
    var isMaster = true
    var lastCheckMasterTime = DateTime.fromUnixTimeStamp(Duration.second)
    var curHost = ""
    var curPort = 0u16
    var useCurAddrOnly = false
    let instanceLock = Mutex()
    var notices = ArrayList<NoticeResponse>()
    var pgdb: ?PGDBInteface = Option<PGDBInteface>.None
    static var modifySqls = HashMap<String, String>()
    static let modifySqlsLock = Mutex()

    public init(connId: Int64, config: Config, socket: StreamingSocket, host: String, port: UInt16, addrindex: Int32) {
        this.connId = connId
        this.config = config
        this.socket = socket
        this.config.setAddrIndex(addrindex)
        this.curHost = host
        this.curPort = port
        ConnManager.instance().add(curHost, curPort)
        fb = Frontend(socket, socket)
    }
    public static func isModifySql(sql: String): Bool {
        if (modifySqls.size == 0) {
            synchronized(modifySqlsLock) {
                if (modifySqls.size == 0) {
                    var tmpSqls = HashMap<String, String>()
                    tmpSqls["create"] = ""
                    tmpSqls["alter"] = ""
                    tmpSqls["drop"] = ""
                    tmpSqls["reindex"] = ""
                    tmpSqls["insert"] = ""
                    tmpSqls["update"] = ""
                    tmpSqls["delete"] = ""
                    tmpSqls["truncate"] = ""
                    tmpSqls["copy"] = ""
                    tmpSqls["lock"] = ""
                    tmpSqls["call"] = ""
                    tmpSqls["grant"] = ""
                    tmpSqls["revoke"] = ""
                    modifySqls = tmpSqls
                }
            }
        }
        return modifySqls.contains(getFirstWord(sql).toAsciiLower())
    }
    public func getConnId(): Int64 {
        return connId
    }
    public func setUseCurAddrOnly(useCurAddrOnly: Bool) {
        this.useCurAddrOnly = useCurAddrOnly
    }
    public func toString(): String {
        socket.toString()
    }
    public func isClosed(): Bool {
        return socket.isClosed()
    }
    public func close(): Unit {
        if (status == ConnStatus.Closed) {
            return
        }
        try {
            var threadid = getCurrentThreadId()
            var context = PgConnInterceptorContext(connId, threadid, curHost, curPort)
            if (PgConnInterceptorManager.instance().isInterceptorEnable()) {
                PgConnInterceptorManager.instance().close(context)
            }
            ConnManager.instance().remove(curHost, curPort)
            status = ConnStatus.Closed
            statusStatement = ""
            let term = Terminate()
            this.send(term)
            flush()
        } finally {
            socket.close()
        }
    }
    func asyncClose(): Unit {
        if (status == ConnStatus.Closed) {
            return
        }
        status = ConnStatus.Closed
        // 这个异步函数可能要调整，主要是添加了连接主备集群的功能后，可能会被重用。因此需要避免关闭后被重用，socket就不一样了
        let tmpsocket = socket
        spawn {
            => try {
                let term = Terminate()
                send(term)
                flush()
            } finally {
                tmpsocket.close()
            }
        }
    }
    public func closeStmt(name: String) {
        if (name.isEmpty()) {
            // 匿名语句不用关闭
            return
        }
        let close = proto3.Close(name, b'S')
        this.send(close)
        let sync = Sync()
        this.send(sync)
        this.flush()
        readUntilReadyForQuery()
    }
    func readUntilReadyForQuery() {
        while (true) {
            if (let Ok(msg) <- receiveMessage()) {
                if (logger.level.ge(LogLevel.Debug)) {
                    logger.debug("pgconn[${objId}] in readURFQ recv ${msg}")
                }
                if (msg is ReadyForQuery) {
                    return
                }
            }
        }
    }
    func pgAuth(msg: AuthenticationMessage, username: String, password: String): Unit {
        match (msg) {
            case bm: AuthenticationOk => bm
            case bm: AuthenticationKerberosV5 => bm
            case bm: AuthenticationCleartextPassword =>
                let pm = PasswordMessage(password)
                this.send(pm)
                this.flush()
            case bm: AuthenticationMD5Password =>
                let digestedPassword = authMd5(username, password, bm.data)
                let pm = PasswordMessage(digestedPassword)
                this.send(pm)
                this.flush()
            case bm: AuthenticationSCMCredential => bm
            case bm: AuthenticationGSS => bm
            case bm: AuthenticationGSSContinue => bm
            case bm: AuthenticationSSPI => bm
            case bm: AuthenticationSASL => this.scramAuth(bm.mechanisms, password, username)
            case bm: AuthenticationSASLContinue => bm
            case bm: AuthenticationSASLFinal => bm
            case _ => ()
        }
    }
    func ogAuth(msg: AuthenticationMessage, username: String, password: String): Unit {
        match (msg) {
            case bm: AuthenticationOk => bm
            case bm: AuthenticationKerberosV5 => bm
            case bm: AuthenticationCleartextPassword =>
                let pm = PasswordMessage(password)
                this.send(pm)
                this.flush()
            case bm: AuthenticationMD5Password =>
                let digestedPassword = authMd5(username, password, bm.data)
                let pm = PasswordMessage(digestedPassword)
                this.send(pm)
                this.flush()
            case bm: AuthenticationSCMCredential => bm
            case bm: AuthenticationGSS => bm
            case bm: AuthenticationGSSContinue => bm
            case bm: AuthenticationSSPI => bm
            case bm: AuthenticationRFC5802 =>
                if (bm.pwdMethod == 0 || bm.pwdMethod == 2) {
                    let digestedPassword = RFC5802Algorithm(
                        password,
                        String.fromUtf8(bm.rnd64),
                        String.fromUtf8(bm.token),
                        "",
                        Int64(bm.iterstep),
                        "sha256"
                    )
                    let pm = PasswordMessage(digestedPassword)
                    this.send(pm)
                    this.flush()
                } else {
                    throw SqlException("invalid AuthenticationRFC5802 message with pwdMethod(${bm.pwdMethod})")
                }
            case bm: AuthenticationSASLContinue => bm
            case bm: AuthenticationSASLFinal => bm
            case _ => ()
        }
    }
    func addNotice(notice: NoticeResponse): Unit {
        synchronized(instanceLock) {
            notices.add(notice)
            if (notices.size > maxNoticeCount) {
                notices.remove(0..1)
            }
        }
    }
    func getAllNotices(notice: NoticeResponse): ArrayList<NoticeResponse> {
        var ret: ArrayList<NoticeResponse>
        synchronized(instanceLock) {
            ret = notices
            notices = ArrayList<NoticeResponse>()
        }
        return ret
    }
    func startup(): Unit {
        var protocolVersion: Int32 = 196608
        if (config.scheme == DBType.OpenGauss) {
            protocolVersion = 196659
        }
        var username = config.user
        var password = config.password
        var context = ServerUserPasswordInterceptorContext((curHost, curPort))
        if (ServerUserPasswordInterceptorManager.instance().isInterceptorEnable()) {
            match (ServerUserPasswordInterceptorManager.instance().getServerUserPassword(context)) {
                case Some(v) =>
                    username = v[0]
                    password = v[1]
                case _ => ()
            }
        }
        var sm = StartupMessage(protocolVersion, config.params)
        if (username != "") {
            sm.addParam("user", username)
        }
        if (config.database != "") {
            sm.addParam("database", config.database)
        }
        for ((k, v) in config.params) {
            sm.addParam(k, v)
        }
        this.send(sm)
        this.flush()
        while (true) {
            let m = receiveMessage()
            logger.debug("pgconn[${objId}] in startup recv ${m}")
            match (m) {
                case Ok(msg) => match (msg) {
                    case bm: AuthenticationMessage =>
                        if (config.scheme == DBType.Postgres) {
                            pgAuth(bm, username, password)
                        } else {
                            ogAuth(bm, username, password)
                        }
                    case bm: NegotiateProtocolVersion => bm
                    case bm: BackendKeyData =>
                        this.pid = bm.processID
                        this.secretKey = bm.secretkey
                    case bm: ParameterStatus => ()
                    case bm: ReadyForQuery =>
                        // 这是启动流程，因此这里无需加锁
                        status = ConnStatus.Idle
                        break
                    case bm: NoticeResponse => addNotice(bm)
                    case _ =>
                        socket.close()
                        throw SqlException("not support message(${msg}) in startup stage")
                }
                case Err(e) =>
                    socket.close()
                    throw e
            }
        }
    }
    func genStmtName(): String {
        return "og_${namei.fetchAdd(1)}"
    }
    func canonicalPlaceholder(sql: String): (String, UInt16) {
        let sqlBytes = sql.toArray()
        let sb = ArrayList<Byte>()
        var count: UInt16 = 1
        for (b in sqlBytes) {
            if (b == b'?') {
                sb.add(all: "$${count}".toArray())
                count++
            } else {
                sb.add(b)
            }
        }
        return (String.fromUtf8(unsafe { sb.getRawArray()[0..sb.size] }), count - 1)
    }
    public func prepare(sql: String, paramOIDs: Array<Int32>): Result<StmtDescription> {
        // 为sql准备数据库实例，如果sql属于写sql，并且数据库连接的是集群，那么需要把sql发到主实例上
        prepareDatabaseInstanceForSql(sql)
        while (true) {
            // 连接，这个可以选择往外抛异常，和一直等待，目前暂时做一直等待处理，后续增加配置处理
            match (lock("")) {
                case Some(v) =>
                    logger.debug("${v.message}. sleep 1 second and try again")
                    sleep(Duration.second)
                case _ => break
            }
        }
        let (query, paramCount) = canonicalPlaceholder(sql)
        // 默认使用匿名预备语句
        var name = ""
        if (config.namedstatement) {
            // 命名预备语句
            name = genStmtName()
        }
        let parse = Parse(name, query, paramOIDs)
        // 不在这里发送，因为不好进行线程安全处理
        // this.send(parse)
        // 应该不需要发送预备语句的Describe命令
        // let desc = Describe(b'S', name)
        // this.send(desc)
        // 先不发送sync，到执行语句再发sync
        // let sync = Sync()
        // this.send(sync)
        // this.flush()

        var stDesc = StmtDescription(name, query, paramCount)
        stDesc.parse = Some(parse)
        // 先不进行消息接收，在statement执行时，再进行信息接收
        // var parseErr = false
        // var ex = SqlException()

        // while (true) {
        //     let m = receiveMessage()
        //     logger.debug("pgconn[${objId}] in prepare recv ${m}")
        //     match (m) {
        //         case Ok(msg) => match (msg) {
        //             case bm: ParameterDescription => stDesc.paramOIDs = bm.paramOids.clone()
        //             case bm: RowDescription => stDesc.fields = bm.fields.clone()
        //             case bm: ErrorResponse =>
        //                 // 这里知道出错了，但是还需要继续接收消息，一直到消息接收完，再去通知上层调用者
        //                 // 所以希望时这里记录错误，然后把错误信息返回给调用者，而不是在这里抛异常
        //                 ex = SqlException(bm.getMessage())
        //                 parseErr = true
        //             case bm: ReadyForQuery => break
        //             case _ => ()
        //         }
        //         case Err(e) =>
        //             unlock()
        //             return Err(e)
        //     }
        // }
        // if (parseErr) {
        //     unlock()
        //     return Err(ex)
        // }
        unlock("")
        return Ok(stDesc)
    }
    public func execParams(query: String, paramValues: Array<BindParameter>, paramOIDs: Array<Int32>): ResultReader {
        // 为sql准备数据库实例，如果sql属于写sql，并且数据库连接的是集群，那么需要把sql发到主实例上
        prepareDatabaseInstanceForSql(query)
        while (true) {
            // 锁连接，这个可以选择往外抛异常，和一直等待，目前暂时做一直等待处理，后续增加配置处理
            match (lock("")) {
                case Some(v) =>
                    logger.debug("${v.message}. sleep 1 second and try again")
                    sleep(Duration.second)
                case _ => break
            }
        }
        let rr = execExtendedPrefix("", paramValues)
        if (rr.closed) {
            return rr
        }
        let paramFmts = Array<Int16>(paramValues.size, repeat: 1)
        let resultFormats = Array<Int16>(paramValues.size, repeat: 1)
        let parse = Parse("", query, paramOIDs)
        this.send(parse)
        let bind = Bind("", "", paramFmts, paramValues, resultFormats)
        this.send(bind)
        execExtendedSuffix(rr)
        return rr
    }
    public func execPrepared(sd: StmtDescription, paramValues: Array<BindParameter>): ResultReader {
        // 连接锁已经在statement中进行处理，因此这个函数不处理
        let rr = execExtendedPrefix(sd.localname, paramValues)
        if (rr.closed) {
            return rr
        }
        // 传给数据库的字段以文本为主，除去用户直接用二进制的对象，比如SqlBinary、SqlVarBinary、SqlClob、SqlBlob等，其他默认都会转为文本传输
        let paramFmts = Array<Int16>(paramValues.size, repeat: 0)
        for (index in 0..paramValues.size) {
            if (paramValues[index].binaryformat == true) {
                paramFmts[index] = 1
            }
        }
        // 数据库返回有的字段不支持二进制，比如aclitem，会导致服务返回异常，因此默认为文本方式，虽然牺牲了性能，但是胜在安全
        var resultFormats = Array<Int16>(sd.fields.size, repeat: 0)
        // if (config.binarytransfer) {
        //     resultFormats = Array<Int16>(sd.fields.size, repeat: 1)
        // }
        let bind = Bind("", sd.name, paramFmts, paramValues, resultFormats)
        this.send(bind)
        execExtendedSuffix(rr)
        return rr
    }
    func execExtendedPrefix(stname: String, paramValues: Array<BindParameter>) {
        let rr = ResultReader(this, stname)
        if (paramValues.size > Int64(UInt16.Max)) {
            rr.concludeCommand(CommandTag(""), "extended protocol limited to ${UInt16.Max} parameters")
            rr.closed = true
            unlock(stname)
            return rr
        }
        return rr
    }
    func execExtendedSuffix(rr: ResultReader) {
        let desc = Describe(b'P', "")
        this.send(desc)
        let exec = Execute()
        this.send(exec)
        let sync = Sync()
        this.send(sync)
        this.flush()
        rr.readUntilRowDescription()
        if (rr.commandConcluded) {
            if (rr.err != "") {
                rr.close()
                throw SqlException(rr.err)
            }
        }
    }
    public func simpleExec(sql: String): ResultReader {
        // 为sql准备数据库实例，如果sql属于写sql，并且数据库连接的是集群，那么需要把sql发到主实例上
        prepareDatabaseInstanceForSql(sql)
        while (true) {
            // 锁连接，这个可以选择往外抛异常，和一直等待，目前暂时做一直等待处理，后续增加配置处理
            match (lock("")) {
                case Some(v) =>
                    logger.debug("${v.message}. sleep 1 second and try again")
                    sleep(Duration.second)
                case _ => break
            }
        }
        let rr = execExtendedPrefix("")
        if (rr.closed) {
            return rr
        }
        let query = proto3.Query(sql)
        this.send(query)
        this.flush()
        rr.readUntilRowDescription()
        if (rr.commandConcluded) {
            if (rr.err != "") {
                rr.close()
                throw SqlException(rr.err)
            }
        }
        return rr
    }
    public func exec(sql: String) {
        let rr = simpleExec(sql)
        let (cmdtag, err) = rr.close()
        if (err != "") {
            throw SqlException(err)
        }
    }
    public func send(msg: FrontendMessage) {
        if (logger.level.ge(LogLevel.Debug)) {
            logger.debug("pgconn[${objId}] send ${msg}")
        }
        fb.sendMessage(msg)
    }
    public func receiveMessage(): Result<BackendMessage> {
        let msg: BackendMessage
        let m = peekMessage()
        match (m) {
            case None => return Err(SqlException("receive message timeout"))
            case Some(v) => msg = v
        }
        peekedMsg = None
        match (msg) {
            case bm: ReadyForQuery => txStatus = bm.status
            case bm: ParameterStatus => params[bm.paramName] = bm.paramValue
            case bm: ErrorResponse =>
                if (bm.getSeverity() == "FATAL") {
                    // FATAL也不关闭，让应用关闭，是否更好？
                    synchronized(statusMtx) {
                        status = ConnStatus.Closed
                    }
                    socket.close()
                    return Err(SqlException(bm.getMessage()))
                }
            case bm: NoticeResponse => addNotice(bm)
            case bm: NotificationResponse => ()
            case _ => ()
        }

        return Ok(msg)
    }
    func peekMessage(): ?BackendMessage {
        match (peekedMsg) {
            case Some(msg) => return msg
            case None => ()
        }
        try {
            peekedMsg = fb.receive(config.scheme)
        } catch (ex: Exception) {
            // 读数据异常，关闭连接
            socket.close()
            throw ex
        }
        return peekedMsg
    }
    public func flush() {
        // let flush = Flush()
        // this.send(flush)
        fb.flush()
    }
    public func lock(stname: String): ?SqlException {
        var ret: ?SqlException = None
        synchronized(statusMtx) {
            if (statusStatement == "") {
                // 如果当前锁的对象都是connection本身
                match (status) {
                    case ConnStatus.Busy => ret = Some(SqlException("conn busy"))
                    case ConnStatus.Closed => ret = Some(SqlException("conn closed"))
                    case ConnStatus.Uninitialized => throw SqlException("conn uninitialized")
                    case _ =>
                        status = ConnStatus.Busy
                        statusStatement = stname
                }
            } else {
                // 如果当前锁的对象是statement
                if (stname != "") {
                    if (statusStatement == stname) {
                    // 如果是同一个statement在重复锁，目前按照与锁一次相同的方式处理
                    } else {
                        // 另一个statement已经锁了
                        ret = Some(SqlException("conn is busy processing another statement(${statusStatement})"))
                    }
                } else {
                    ret = Some(SqlException("conn is busy processing statement(${statusStatement})"))
                }
            }
        }
        return ret
    }
    public func unlock(stname: String) {
        synchronized(statusMtx) {
            if (statusStatement == "") {
                // 如果当前锁的对象是connection
                if (stname == "") {
                    // 如果要解锁的对象是connection
                    match (status) {
                        case ConnStatus.Busy => status = ConnStatus.Idle
                        case ConnStatus.Closed => ()
                        case _ => throw SqlException("BUG: cannot unlock unlocked connection")
                    }
                } else {
                    // 如果要解锁的对象是statement
                    match (status) {
                        case ConnStatus.Busy => throw SqlException(
                            "the connection is locked by itself. cannot unlock the connection by the statement(${stname})"
                        )
                        case _ => ()
                    }
                }
            } else {
                // 如果当前锁的对象是statement
                if (stname != "") {
                    if (statusStatement == stname) {
                        // 如果是同一个statement，那么可以解锁
                        status = ConnStatus.Idle
                        statusStatement = ""
                    } else {
                        throw SqlException(
                            "the connection is locked by the statement(${statusStatement}). cannot unlock the connection by the statement(${stname})"
                        )
                    }
                } else {
                    throw SqlException("cannot unlock. the conn is busy processing the statement(${statusStatement})")
                }
            }
        }
    }
    func scramAuth(mechanisms: Array<String>, password: String, username: String) {
        let sc = scramClient(mechanisms, password, username)
        let saslInitResp = SASLInitialResponse("SCRAM-SHA-256", sc.clientFirstMessage())
        send(saslInitResp)
        flush()
        let saslContinue = rxSASLContinue()
        sc.recvContinueMsg(saslContinue.data)
        let saslResponse = SASLResponse(sc.clientFinalMessage().toArray())
        send(saslResponse)
        flush()
        let saslFinal = rxSASLFinal()
        return sc.recvFinalMsg(saslFinal.data)
    }
    func rxSASLContinue(): AuthenticationSASLContinue {
        let m = receiveMessage()
        logger.debug("pgconn[${objId}] in rxSASLContinue recv ${m}")
        match (m) {
            case Ok(msg) => match (msg) {
                case bm: AuthenticationSASLContinue => return bm
                case bm: ErrorResponse => throw SqlException(bm.getMessage())
                case _ => ()
            }
            case _ => ()
        }
        throw SqlException("expected AuthenticationSASLContinue message but received unexpected message ${m}")
    }
    func rxSASLFinal(): AuthenticationSASLFinal {
        let m = receiveMessage()
        logger.debug("pgconn[${objId}] in rxSASLFinal recv ${m}")
        match (m) {
            case Ok(msg) => match (msg) {
                case bm: AuthenticationSASLFinal => return bm
                case bm: ErrorResponse => throw SqlException(bm.getMessage())
                case _ => ()
            }
            case _ => ()
        }
        throw SqlException("expected AuthenticationSASLFinal message but received unexpected message ${m}")
    }

    public func getParams(): Map<String, String> {
        return HashMap<String, String>(params)
    }

    public func getStatus(): ConnStatus {
        return status
    }

    public func isMasterUseCache(): Bool {
        if (config.addrs.size <= 1) {
            // 单一地址都认为是主库
            isMaster = true
            return isMaster
        }

        if (lastCheckMasterTime + Duration.millisecond * DEFAULT_IS_MASTER_CACHE_INVALID_TIME < DateTime.now()) {
            match (pgdb) {
                case Some(v) =>
                    try {
                        isMaster = v.checkIsMaster(curHost, curPort)
                    } catch (ex: Exception) {
                        // 有异常认为不是master
                        logger.error("checkIsMaster error: ${ex.toString()}")
                        isMaster = false
                    }
                    lastCheckMasterTime = DateTime.now()
                case _ => logger.error(
                    "Cannot determine if the database(${curHost}:${curPort}) is master because PGDBInteface is not set."
                )
            }
        }
        return isMaster
    }

    public func prepareDatabaseInstanceForSql(sql: String): Unit {
        if (isModifySql(sql)) {
            // 如果是修改类型的sql，找到合适的实例去执行
            checkToResetToMasterConnection()
        }
    }

    public func checkToResetToMasterConnection(): Unit {
        if (!isMasterUseCache()) {
            // 如果不是主，那么连接到主
            var ignoreAddrs = ArrayList<(String, UInt16)>()
            ignoreAddrs.add((curHost, curPort))
            resetToMasterConnection(ignoreAddrs)
            isMaster = true
        }
    }

    public func resetToMasterConnection(ignoreAddrs: ArrayList<(String, UInt16)>): Unit {
        if (status == ConnStatus.Closed) {
            throw SqlException("cannot reset a closed connection")
        }
        match (pgdb) {
            case Some(v) =>
                var foundMaster = false
                try {
                    var masterAddr = v.findMaster(ignoreAddrs)
                    foundMaster = true
                    var threadid = getCurrentThreadId()
                    var context = PgConnInterceptorContext(connId, threadid, curHost, curPort)
                    // 找到了master
                    if ((curHost != masterAddr[0]) || (curPort != masterAddr[1])) {
                        // 如果地址与当前不一样，重置当前连接，然后连接到master
                        var interceptorenabled = PgConnInterceptorManager.instance().isInterceptorEnable()
                        try {
                            if (interceptorenabled) {
                                PgConnInterceptorManager.instance().close(context)
                            }

                            ConnManager.instance().remove(curHost, curPort)
                            status = ConnStatus.Closed
                            statusStatement = ""
                            let term = Terminate()
                            this.send(term)
                            flush()
                            socket.close()
                        } catch (ex: Exception) {
                            logger.error(
                                "close connection to ${curHost}:${curPort} error in resetToMasterConnection. ${ex.toString()}"
                            )
                        }
                        // 连接到master
                        curHost = masterAddr[0]
                        curPort = masterAddr[1]
                        context = PgConnInterceptorContext(connId, threadid, curHost, curPort)
                        if (interceptorenabled) {
                            PgConnInterceptorManager.instance().connectStart(context)
                        }
                        try {
                            socket = connect(config, curHost, curPort, " to reset the pgconn to the master instance")
                            if (interceptorenabled) {
                                PgConnInterceptorManager.instance().connectSuccess(context)
                            }
                            ConnManager.instance().add(curHost, curPort)
                            fb = Frontend(socket, socket)
                            startup()
                        } catch (ex: Exception) {
                            if (interceptorenabled) {
                                PgConnInterceptorManager.instance().connectException(context, ex)
                            }
                            throw ex
                        }
                    }
                } catch (ex: Exception) {
                    if (foundMaster) {
                        // 如果找到了master，连接异常，抛出异常
                        throw ex
                    } else {
                        // 没有找到master，使用当前的服务尝试继续执行sql
                        logger.warn(
                            "cannot find the master database instance. ${ex.toString()}.\n continue with current connection."
                        )
                    }
                }
            case _ => logger.error("Cannot find the master database instance because PGDBInteface is not set.")
        }
    }

    public func setPgdb(pgdb: PGDBInteface): Unit {
        this.pgdb = pgdb
    }

    public func getHost(): String {
        return curHost
    }

    public func getPort(): UInt16 {
        return curPort
    }

    public func isBinarytransfer(): Bool {
        return config.binarytransfer
    }
}
