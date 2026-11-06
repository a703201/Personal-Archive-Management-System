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

let microsecFromUnixEpochToY2K = 946684800 * 1000000
let negativeInfinityMicrosecondOffset = -9223372036854775808
let infinityMicrosecondOffset = 9223372036854775807
let datetimeFormats = [
    "yyyy-MM-dd",
    "HH:mm:ss",
    "HH:mm:ss.SS",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd HH:mm:ss.SS",
    "yyyy-MM-dd HH:mm:ss.SSZ",
    "yyyy-MM-dd HH:mm:ssZZZZ",
    "yyyy-MM-dd HH:mm:ssSSZZZZ"
]
let pgTimestampFormats = [
    "yyyy-MM-dd HH:mm:ss.SSO",
    "yyyy-MM-dd HH:mm:ss.SSS",
    "yyyy-MM-dd HH:mm:ss.SS",
    "yyyy-MM-dd HH:mm:ss.S",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd HH:mm:ssO",
    "yyyy-MM-dd HH:mm:ss.SSSO",
    "yyyy-MM-dd"
]
let pgTimestamptzFormats = [
    "yyyy-MM-dd HH:mm:ss.SSSOOOO",
    "yyyy-MM-dd HH:mm:ss.SSSO",
    "yyyy-MM-dd HH:mm:ss.SSOOOO",
    "yyyy-MM-dd HH:mm:ss.SSO",
    "yyyy-MM-dd HH:mm:ss.SSS",
    "yyyy-MM-dd HH:mm:ss.SS",
    "yyyy-MM-dd HH:mm:ss.S",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd HH:mm:ssO",
    "yyyy-MM-dd"
]
