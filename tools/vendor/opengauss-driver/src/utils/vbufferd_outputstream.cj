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

public class VBufferedOutputStream {
    private var buf: Array<UInt8> = Array<UInt8>(8192, repeat: 0u8)
    private var buflen = 8192
    private var writepos: Int64 = 0
    private var outputstream: OutputStream

    public init(outputstream: OutputStream) {
        this.outputstream = outputstream
    }

    public func write(dst: Array<UInt8>): VBufferedOutputStream {
        write(dst, 0, dst.size)
    }

    public func write(dst: Array<UInt8>, offset: Int64, length: Int64): VBufferedOutputStream {
        if (length > buflen) {
            outputstream.write(buf[0..writepos])
            outputstream.write(dst[offset..offset + length])
            writepos = 0
        } else if (writepos + length > buflen) {
            outputstream.write(buf[0..writepos])
            dst.copyTo(buf, offset, 0, length)
            writepos = length
        } else {
            dst.copyTo(buf, offset, writepos, length)
            writepos += length
        }
        return this
    }

    public func flush(): Unit {
        if (writepos > 0) {
            outputstream.write(buf[0..writepos])
            writepos = 0
        }
        outputstream.flush()
    }
}
