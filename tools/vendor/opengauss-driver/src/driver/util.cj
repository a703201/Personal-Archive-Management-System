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
package cangjie_tpc::opengauss.driver

func fd2column(fd: FieldDescription): ColumnInfo {
    // let sql = "SELECT c.column_name, c.is_nullable, c.udt_name, c.character_maximum_length, c.numeric_precision, c.numeric_precision_radix, c.numeric_scale, c.datetime_precision, typlen, c.column_default, pd.description, c.identity_increment FROM information_schema.columns AS c JOIN pg_type AS pgt ON c.udt_name = pgt.typname LEFT JOIN pg_catalog.pg_description as pd ON pd.objsubid = c.ordinal_position AND pd.objoid = (SELECT oid FROM pg_catalog.pg_class WHERE relname = c.table_name AND relnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = c.table_schema)) where table_catalog = 'loggable' AND table_schema = 'public' AND table_name = 'change_logs'"
    var ci = PGColumn()
    var precision = Int64(fd.datatypeLen)
    var scale = 0
    if (fd.datatypeOid == 1700 || fd.datatypeOid == 1231) {
        var mod = fd.typeModifier - 4
        precision = Int64((mod >> 16) & 0xffff)
        scale = Int64(mod & 0xffff)
    }
    ci._name = fd.name
    ci._typename = oid2typename(fd.datatypeOid)
    if (precision == -1) {
        ci._length  = 0
    } else {
        ci._length = precision
    }
    ci._scale = scale
    if (fd.typeModifier == -1) {
        ci._displaySize = Int64.Max
    } else {
        ci._displaySize = Int64(fd.typeModifier - 4)
    }
    return ci
}
