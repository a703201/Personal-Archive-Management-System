/**
 * Copyright 2024 Beijing Baolande Software Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Runtime Library Exception to the Apache 2.0 License:
 *
 * As an exception, if you use this Software to compile your source code and
 * portions of this Software are embedded into the binary product as a result,
 * you may redistribute such product without providing attribution as would
 * otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
 */

package cangjie_tpc::opengauss.utils

import std.time.*

public class VBufferedInputStream {
    private var buf: Array<UInt8> = Array<UInt8>(8192, repeat: 0u8)
    private var buflen = 8192
    private var writepos: Int64 = 0
    private var readpos: Int64 = 0
    private var inputstream: InputStream

    public init(inputstream: InputStream) {
        this.inputstream = inputstream
    }

    public func get(dst: Array<UInt8>, offset: Int64, length: Int64): VBufferedInputStream {
        if (0 == length) {
            return this
        }            

        if (length >= buflen) {
            // 如果要获取的消息比较大，那么直接读取数据
            var tmpoffset = offset
            var tmplength = length
            if (writepos > readpos) {
                buf.copyTo(dst, readpos, offset, writepos - readpos)
                tmpoffset += writepos - readpos
                tmplength -= writepos - readpos
            }
            var readlen = 0
            while (tmplength > 0) {
                readlen = inputstream.read(dst[tmpoffset..tmpoffset + tmplength])
                if (readlen <= 0) {
                    throw IOException("cannot read data. read length is ${readlen}")
                }
                tmplength -= readlen
                tmpoffset += readlen
            }
            writepos = 0
            readpos = 0
        } else {
            if (writepos == 0) {
                var readlen = inputstream.read(buf[writepos..])
                if (readlen > 0) {
                    writepos += readlen
                } else {
                    throw IOException("cannot read data. read length is ${readlen}")
                }
            }
            if (writepos - readpos >= length) {
                // 数组长度足够
                buf.copyTo(dst, readpos, offset, length)
                readpos += length
            } else {
                var readlen = 0
                // 数组长度不够
                if (buflen - readpos > length) {
                    // 剩余的数组长度足够
                    while (writepos - readpos < length) {
                        readlen = inputstream.read(buf[writepos..])
                        if (readlen > 0) {
                            writepos += readlen
                        } else {
                            throw IOException("cannot read data. read length is ${readlen}")
                        }
                    }
                    buf.copyTo(dst, readpos, offset, length)
                    readpos += length
                } else {
                    // 剩余的数组长度不够，先把当前的数据拷贝出去
                    buf.copyTo(dst, readpos, offset, writepos - readpos)
                    var tmpoffset = offset + (writepos - readpos)
                    var tmplength = length - (writepos - readpos)
                    while (tmplength > 0) {
                        readlen = inputstream.read(dst[tmpoffset..tmpoffset + tmplength])
                        if (readlen <= 0) {
                            throw IOException("cannot read data. read length is ${readlen}")
                        }
                        tmplength -= readlen
                        tmpoffset += readlen
                    }
                    writepos = 0
                    readpos = 0
                }
            }
            if ((readpos == writepos) && (readpos > 0)) {
                // 如果数据已经读完，那么重置数据位置
                readpos = 0
                writepos = 0
            }
        }
        return this
    }
}
