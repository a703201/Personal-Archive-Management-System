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

public class ResultReader {
    var cn: PgConn
    let stname: String
    public var columns = Array<FieldDescription>()
    public var values = Array<DataField>()
    public var commandTag = CommandTag("")
    var closed = false
    var commandConcluded = false
    var hasReadyForQuery = false
    var err = ""

    public init(cn: PgConn, stname: String) {
        this.cn = cn
        this.stname = stname
    }
    public func update(): Bool {
        return commandTag.command() != "SELECT" && commandTag.command() != "FETCH"
    }
    public func rows(): Int64 {
        return commandTag.rowsAffected()
    }
    func rowsToString() {
        for (i in 0..columns.size) {
            let col = columns[i]
            let df = values[i]
            match (col.datatypeOid) {
                case 16 =>
                    let val: ?Bool = match (df.val[0]) {
                        case b't' => true
                        case b'f' => false
                        case _ => None
                    }
                    if (logger.level.ge(LogLevel.Debug)) {
                        logger.debug("${col.name} = ${val}")
                    }
                case 114 => ()
                case 1184 =>
                    if (logger.level.ge(LogLevel.Debug)) {
                        logger.debug("${i} ${df.val}")
                    }
                case _ => ()
            }
        }
    }
    public func nextRow(): Bool {
        while (!this.commandConcluded) {
            let m = receiveMessage()
            match (m) {
                case Some(msg) =>
                    if (logger.level.ge(LogLevel.Debug)) {
                        logger.debug("pgconn[${cn.objId}] in next recv ${msg}")
                    }
                    match (msg) {
                        case bm: DataRow =>
                            this.values = bm.fields
                            return true
                        case bm: ErrorResponse => try {
                            // 先关闭reader，再往外抛出异常，避免外部没有关闭close而导致消息混乱
                            close()
                        } catch (ex: Exception) {
                            logger.warn("close error while nextRow. ${ex.toString()}")
                        } finally {
                            throw SqlException(bm.getMessage())
                        }
                        case _ => ()
                    }
                case None => return false
            }
        }
        return false
    }
    public func close(): (CommandTag, String) {
        if (closed) {
            return (commandTag, "")
        }
        closed = true

        while (!commandConcluded) {
            let m = receiveMessage()
            logger.debug("pgconn[${cn.objId}] in close recv cc ${m}")
            match (m) {
                case Some(msg) => match (msg) {
                    case bm: DataRow => this.values = bm.fields.clone()
                    case _ => ()
                }
                case None => return (CommandTag(""), err)
            }
        }
        if (hasReadyForQuery) {
            // 已经收到过ReadyForQuery消息
            cn.unlock(stname)
            return (commandTag, err)
        }
        while (true) {
            let m = receiveMessage()
            match (m) {
                case Some(msg) =>
                    if (logger.level.ge(LogLevel.Debug)) {
                        logger.debug("pgconn[${cn.objId}] in close recv rest ${msg}")
                    }
                    match (msg) {
                        case bm: ErrorResponse => err = bm.getMessage()
                        case bm: ReadyForQuery =>
                            cn.unlock(stname)
                            return (commandTag, err)
                        case _ => ()
                    }
                case None => return (CommandTag(""), err)
            }
        }
        return (commandTag, err)
    }
    func readUntilRowDescription() {
        while (!commandConcluded) {
            if (let Some(msg) <- cn.peekMessage()) {
                if (logger.level.ge(LogLevel.Debug)) {
                    logger.debug("pgconn[${cn.objId}] in readURD peek ${msg}")
                }
                match (msg) {
                    case bm: DataRow => return
                    case _ => ()
                }
            }
            if (let Some(msg) <- receiveMessage()) {
                if (logger.level.ge(LogLevel.Debug)) {
                    logger.debug("pgconn[${cn.objId}] in readURD recv ${msg}")
                }
                if (msg is RowDescription) {
                    return
                }
            }
        }
    }
    func receiveMessage(): ?BackendMessage {
        let msg: BackendMessage
        let m = cn.receiveMessage()
        match (m) {
            case Ok(v) => msg = v
            case Err(v) =>
                concludeCommand(CommandTag(""), v.message)
                closed = true
                return None
            // case _ =>
            //     concludeCommand(CommandTag(""), "recv timeout")
            //     closed = true
            //     return None
        }

        match (msg) {
            case bm: RowDescription => this.columns = bm.fields
            case bm: CommandComplete => this.concludeCommand(CommandTag(bm.commandTag), "")
            // 虽然说，按照消息顺序，应该先有CommandComplete，再有ReadyForQuery，但是为了避免一些意外情况，
            // 这里还是增加了ReadyForQuery的处理，避免ReadyForQuery的意外遗漏导致close时处理出现问题
            case bm: ReadyForQuery =>
                this.concludeCommand(CommandTag(""), "")
                this.hasReadyForQuery = true
            case bm: EmptyQueryResponse => this.concludeCommand(CommandTag(""), "")
            case bm: ErrorResponse => this.concludeCommand(CommandTag(""), bm.getMessage())
            case _ => ()
        }

        return msg
    }
    public func isClosed(): Bool {
        return closed
    }
    public func concludeCommand(commandTag: CommandTag, errMsg: String) {
        if (errMsg != "" && err == "") {
            err = errMsg
        }
        if (this.commandConcluded) {
            return
        }
        this.commandTag = commandTag
        this.commandConcluded = true
        // this.values = []
    }
}
