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
package cangjie_tpc::opengauss.proto3

public struct BindParameter <: Serializable<BindParameter> {
    var len = 0i32
    var val = Array<Byte>()
    public var binaryformat = false

    public init() {}
    public init(len: Int32, val: Array<Byte>) {
        this.len = len
        this.val = val
    }

    public init(len: Int32, val: Array<Byte>, binaryformat: Bool) {
        this.len = len
        this.val = val
        this.binaryformat = binaryformat
    }

    public mut func decode(buf: ReadOnlyBuffer): Unit {
        this.len = buf.getInt32()
        if (this.len > 0) {
            // this.val = Array<Byte>(Int64(len), repeat: 0)
            // buf.get(this.val, 0, Int64(len))
            this.val = buf.get(Int64(len))
        }
    }

    public func encode(buf: ReadWriteBuffer) {
        buf.add(len)
        buf.add(val)
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Int32>("len", len))
            .add(field<String>("val", val.toString()))
            .add(field<Bool>("binaryformat", binaryformat))
    }

    public static func deserialize(dm: DataModel): BindParameter {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = BindParameter()
        result.len = Int32.deserialize(dms.get("len"))
        // result.val = Array<Byte>.deserialize(dms.get("val"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        result.binaryformat = Bool.deserialize(dms.get("binaryformat"))
        return result
    }
}

public struct Bind <: FrontendMessage & Serializable<Bind> {
    var kind = b'B'
    var len: Int32 = 0
    var dstPortalName = ""
    var srcPrepStmtName = ""
    var paramFmtNum = 0i16
    var paramFmts = ArrayList<Int16>()
    var paramValNum = 0i16
    var params = ArrayList<BindParameter>()
    var resultFmtNum = 0i16
    var resultFmts = ArrayList<Int16>()

    public init() {}
    public init(
        portalName: String,
        stmtName: String,
        paramFmts: Array<Int16>,
        params: Array<BindParameter>,
        resultFmts: Array<Int16>
    ) {
        this.dstPortalName = portalName
        this.srcPrepStmtName = stmtName
        this.paramFmts = ArrayList<Int16>(paramFmts)
        this.paramFmtNum = Int16(paramFmts.size)
        this.params = ArrayList<BindParameter>(params)
        this.paramValNum = Int16(params.size)
        this.resultFmts = ArrayList<Int16>(resultFmts)
        this.resultFmtNum = Int16(resultFmts.size)
    }

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.dstPortalName = buf.getString()
        this.srcPrepStmtName = buf.getString()
        this.paramFmtNum = buf.getInt16()
        this.paramFmts = ArrayList<Int16>(Int64(paramFmtNum))
        for (i in 0..Int64(paramFmtNum)) {
            this.paramFmts[i] = buf.getInt16()
        }
        this.paramValNum = buf.getInt16()
        this.params = ArrayList<BindParameter>(Int64(paramValNum))
        for (i in 0..Int64(paramValNum)) {
            var filed = BindParameter()
            filed.decode(buf)
            this.params[i] = filed
        }
        this.resultFmtNum = buf.getInt16()
        this.resultFmts = ArrayList<Int16>(Int64(resultFmtNum))
        for (i in 0..Int64(resultFmtNum)) {
            this.resultFmts[i] = buf.getInt16()
        }
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(dstPortalName)
        buf.add(0u8)
        buf.add(srcPrepStmtName)
        buf.add(0u8)
        buf.add(paramFmtNum)
        for (i in 0..Int64(paramFmtNum)) {
            buf.add(this.paramFmts[i])
        }
        buf.add(paramValNum)
        for (i in 0..Int64(paramValNum)) {
            this.params[i].encode(buf)
        }
        buf.add(resultFmtNum)
        for (i in 0..Int64(resultFmtNum)) {
            buf.add(this.resultFmts[i])
        }
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        let t: Rune = Rune(UInt32(kind))
        return DataModelStruct()
            .add(field<Rune>("type", t))
            .add(field<Int32>("len", len))
            .add(field<String>("dstPortalName", dstPortalName))
            .add(field<String>("srcPrepStmtName", srcPrepStmtName))
            .add(field<Int16>("paramFmtNum", paramFmtNum))
            .add(field<String>("paramFmts", paramFmts.toString()))
            .add(field<Int16>("paramValNum", paramValNum))
            .add(field<String>("params", "<params omitted>"))
            .add(field<Int16>("resultFmtNum", resultFmtNum))
            .add(field<String>("resultFmts", resultFmts.toString()))
    }

    public static func deserialize(dm: DataModel): Bind {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = Bind()
        result.kind = UInt8(UInt32(Rune.deserialize(dms.get("type"))))
        result.len = Int32.deserialize(dms.get("len"))
        result.dstPortalName = String.deserialize(dms.get("dstPortalName"))
        result.srcPrepStmtName = String.deserialize(dms.get("srcPrepStmtName"))
        result.paramFmtNum = Int16.deserialize(dms.get("paramFmtNum"))
        // result.paramFmts = ArrayList<Int16>.deserialize(dms.get("paramFmts"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        result.paramValNum = Int16.deserialize(dms.get("paramValNum"))
        // result.params = ArrayList<BindParameter>.deserialize(dms.get("params"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        result.resultFmtNum = Int16.deserialize(dms.get("resultFmtNum"))
        // result.resultFmts = ArrayList<Int16>.deserialize(dms.get("resultFmts"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
