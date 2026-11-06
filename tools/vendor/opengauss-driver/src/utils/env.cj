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

import std.io.*
import std.fs.*
import std.env.*

public func getEnvString(key: String): String {
    match (getVariable(key)) {
        case Some(v) => return v
        case _ => return ""
    }
}

const DEFAULT_DRIVER_ENV_PROPS_FILENAME = "env.props"

public func loadDefaultEnv(): Unit {
    try (file = File(getDefaultEnvPropsFilePath(), OpenMode.Read)) {
        try (sr = StringReader(file)) {
            var line = sr.readln()
            while (true) {
                match (line) {
                    case Some(v) =>
                        if (!v.startsWith("#")) {
                            // 仅支持行注释，即#开头的为注释行
                            var kv = v.split("=", 2)
                            var key = ""
                            var value = ""
                            if (kv.size > 1) {
                                key = kv[0].trimAscii()
                                value = kv[1].trimAscii()
                                setVariable(key, value)
                            } else if (kv.size > 0) {
                                key = kv[0].trimAscii()
                                setVariable(key, value)
                            }
                        }
                    case None => break
                }
                line = sr.readln()
            }
        } catch (ex: Exception) {
            throw ex
        }
    } catch (ex: Exception) {
        throw ex
    }
}

public func getDefaultEnvPropsFilePath(): Path {
    var dir = getWorkingDirectory()
    match (tryGetEnvPropsFilePath(dir)) {
        case Some(v) => return v
        case _ => throw Exception(
            "cannot find the default env props file ${DEFAULT_DRIVER_ENV_PROPS_FILENAME} in dir ${dir} and the parent directories of the dir"
        )
    }
}

public func tryGetEnvPropsFilePath(dir: Path): ?Path {
    try {
        var envFile = FileInfo(dir.join(DEFAULT_DRIVER_ENV_PROPS_FILENAME))
        if (!envFile.isDirectory()) {
            return envFile.path
        } else {
            return tryGetEnvPropsFilePath(dir.parent)
        }
    } catch (ex: Exception) {
        let dirpath = dir.parent.toString()
        if ((dirpath.size == 2) && (dirpath[1] == b':')) {
            // 目前在windows上遍历到根目录时，比如E:，Directory不再认为E:是根目录，因此需要特殊处理
            return Option<Path>.None
        } else {
            return tryGetEnvPropsFilePath(dir.parent)
        }
    }
    return Option<Path>.None
}
