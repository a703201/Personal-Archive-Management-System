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

import std.binary.*

public class SqlArray<T> {
    private var _value: Array<T>
    private var _dimension = 0
    public init(value: Array<T>) {
        this._value = value
    }

    public mut prop value: Array<T> {
        get() {
            _value
        }
        set(v) {
            _value = v
        }
    }

    public mut prop dimension: Int64 {
        get() {
            _dimension
        }
        set(v) {
            _dimension = v
        }
    }

    public prop name: String {
        get() {
            "SqlArray<T>"
        }
    }
}

public class ArrayHeader <: ToString {
    var numDims = 0
    var containsNull = false
    var elementOID: Int32 = 0
    var dimensions = Array<ArrayDimension>()

    public func decode(val: Array<Byte>) {
        if (val.size < 12) {
            throw SqlException("")
        }
        var rp = 0
        this.numDims = Int64(Int32.readBigEndian(val[rp..]))
        rp += 4
        this.containsNull = UInt32.readBigEndian(val[rp..]) == 1
        rp += 4
        this.elementOID = Int32.readBigEndian(val[rp..])
        rp += 4
        this.dimensions = Array<ArrayDimension>(numDims, repeat: ArrayDimension())
        if (val.size < 12 + numDims * 8) {
            throw SqlException("")
        }
        for (i in 0..numDims) {
            this.dimensions[i].length = Int32.readBigEndian(val[rp..])
            rp += 4
            this.dimensions[i].lowerBound = Int32.readBigEndian(val[rp..])
            rp += 4
        }
        return rp
    }
    public func toString(): String {
        "{numDims=${numDims}, containsNull=${containsNull}, elementOID=${elementOID}, dimensions=${dimensions}}"
    }
}

class ArrayDimension <: ToString {
    var length: Int32 = 0
    var lowerBound: Int32 = 0

    public func toString(): String {
        "{length=${length}, lowerBound=${lowerBound}}"
    }
}

func cardinality(dimensions: Array<ArrayDimension>): Int64 {
    if (dimensions.size == 0) {
        return 0
    }
    var elementCount = Int64(dimensions[0].length)
    for (d in dimensions[1..]) {
        elementCount *= Int64(d.length)
    }
    return elementCount
}
