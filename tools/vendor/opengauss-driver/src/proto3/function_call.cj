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

public struct FunctionArgument <: Serializable<FunctionArgument> {
    var len = 0i32
    var val = Array<Byte>()

    public mut func decode(buf: ReadOnlyBuffer): Unit {
        this.len = buf.getInt32()
        this.val = Array<Byte>(Int64(len), repeat: 0)
        buf.get(this.val, 0, Int64(len))
    }

    public func encode(buf: ReadWriteBuffer) {
        buf.add(len)
        buf.add(val)
    }

    public func serialize(): DataModel {
        return DataModelStruct().add(field<Int32>("len", len)).add(field<String>("val", val.toString()))
    }

    public static func deserialize(dm: DataModel): FunctionArgument {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = FunctionArgument()
        result.len = Int32.deserialize(dms.get("len"))
        // result.val = Array<Byte>.deserialize(dms.get("val"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        return result
    }
}

public struct FunctionCall <: FrontendMessage & Serializable<FunctionCall> {
    var kind = b'F'
    var len: Int32 = 0
    var funcOid = 0i32
    var argFmtNum = 0i16
    var argFmts = ArrayList<Int16>()
    var argNum = 0i16
    var args = ArrayList<FunctionArgument>()
    var resultFmt = 0i16

    public init() {}

    public mut func decode(data: Array<UInt8>): Unit {
        var buf = ReadOnlyBuffer(data)

        this.funcOid = buf.getInt32()
        this.argFmtNum = buf.getInt16()
        this.argFmts = ArrayList<Int16>(Int64(argFmtNum))
        for (i in 0..Int64(argFmtNum)) {
            this.argFmts[i] = buf.getInt16()
        }
        this.argNum = buf.getInt16()
        this.args = ArrayList<FunctionArgument>(Int64(argNum))
        for (i in 0..Int64(argNum)) {
            var arg = FunctionArgument()
            arg.decode(buf)
            this.args.add(arg)
        }
        this.resultFmt = buf.getInt16()
    }

    public func encode(): Array<UInt8> {
        var buf = ReadWriteBuffer()
        buf.add(kind)
        buf.add(len)
        buf.add(funcOid)
        buf.add(argFmtNum)
        for (i in 0..Int64(argFmtNum)) {
            buf.add(this.argFmts[i])
        }
        buf.add(argNum)
        for (i in 0..Int64(argNum)) {
            this.args[i].encode(buf)
        }
        buf.add(resultFmt)
        var arr = buf.data()
        arr[1..5] = UInt32(arr.size - 1).toBeBytes()
        return arr
    }

    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<Byte>("kind", kind))
            .add(field<Int32>("len", len))
            .add(field<Int32>("funcOid", funcOid))
            .add(field<Int16>("argFmtNum", argFmtNum))
            .add(field<String>("argFmts", argFmts.toString()))
            .add(field<Int16>("argNum", argNum))
            .add(field<String>("args", "<args omitted>"))
            .add(field<Int16>("resultFmt", resultFmt))
    }

    public static func deserialize(dm: DataModel): FunctionCall {
        var dms = match (dm) {
            case data: DataModelStruct => data
            case _ => throw Exception("this data is not DataModelStruct")
        }
        var result = FunctionCall()
        result.kind = Byte.deserialize(dms.get("kind"))
        result.len = Int32.deserialize(dms.get("len"))
        result.funcOid = Int32.deserialize(dms.get("funcOid"))
        result.argFmtNum = Int16.deserialize(dms.get("argFmtNum"))
        // result.argFmts = ArrayList<Int16>.deserialize(dms.get("argFmts"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        result.argNum = Int16.deserialize(dms.get("argNum"))
        // result.args = ArrayList<FunctionArgument>.deserialize(dms.get("args"))  // stdx 1.2.0: 集合类型不再实现 Serializable，故不再从 DataModel 还原（协议解码走 decode()）
        result.resultFmt = Int16.deserialize(dms.get("resultFmt"))
        return result
    }

    public func toString() {
        return this.serialize().toJson().toJsonString()
    }
}
