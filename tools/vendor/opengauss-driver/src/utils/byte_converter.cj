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
/*
 * Copyright (c) Cangjie Library Team 2022. All rights reserved.
 * Description:
 */

/**
 * @file The file byte converter class.
 */

package cangjie_tpc::opengauss.utils

public class ByteConverter {
    public static func put(dst: Array<UInt8>, index: Int64, b: String) {
        var a = b.toArray()
        dst[index + 0..index + a.size] = a
    }
    public static func put(dst: Array<UInt8>, index: Int64, b: Bool) {
        dst[index + 0] = match (b) {
            case true => 1u8
            case false => 0u8
        }
    }
    public static func put(dst: Array<UInt8>, index: Int64, b: UInt8) {
        dst[index + 0] = b
    }
    public static func put(dst: Array<UInt8>, index: Int64, b: UInt16) {
        dst[index + 0] = UInt8(b >> 8)
        dst[index + 1] = UInt8(b & 0xff)
    }
    public static func put(dst: Array<UInt8>, index: Int64, b: UInt32) {
        dst[index + 0] = UInt8(b >> 24)
        dst[index + 1] = UInt8(b >> 16)
        dst[index + 2] = UInt8(b >> 8)
        dst[index + 3] = UInt8(b & 0xff)
    }
    public static func put(dst: Array<UInt8>, index: Int64, b: UInt64) {
        dst[index + 0] = UInt8(b >> 56)
        dst[index + 1] = UInt8(b >> 48)
        dst[index + 2] = UInt8(b >> 40)
        dst[index + 3] = UInt8(b >> 32)
        dst[index + 4] = UInt8(b >> 24)
        dst[index + 5] = UInt8(b >> 16)
        dst[index + 6] = UInt8(b >> 8)
        dst[index + 7] = UInt8(b & 0xff)
    }
}
