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

public enum AuthCode {
    | OK
    | KERBEROSV4
    | KERBEROSV5
    | CLEARTEXT_PASSWORD
    | CRYPT
    | MD5_PASSWORD
    | SCM_CREDENTIAL
    | GSS
    | GSS_CONTINUE
    | SSPI
    | SASL
    | SASL_CONTINUE
    | SASL_FINAL
    | SHA256_PASSWORD
    | MD5_SHA256_PASSWORD
    | SM3_PASSWORD

    public static func of(v: Int32): AuthCode {
        match (v) {
            case 0 => OK
            case 1 => KERBEROSV4
            case 2 => KERBEROSV5
            case 3 => CLEARTEXT_PASSWORD
            case 4 => CRYPT
            case 5 => MD5_PASSWORD
            case 6 => SCM_CREDENTIAL
            case 7 => GSS
            case 8 => GSS_CONTINUE
            case 9 => SSPI
            case 10 => SASL
            case 11 => SASL_CONTINUE
            case 12 => SASL_FINAL
            case _ => CRYPT
        }
    }

    public func value(): Int32 {
        match (this) {
            case OK => 0
            case KERBEROSV4 => 1
            case KERBEROSV5 => 2
            case CLEARTEXT_PASSWORD => 3
            case CRYPT => 4
            case MD5_PASSWORD => 5
            case SCM_CREDENTIAL => 6
            case GSS => 7
            case GSS_CONTINUE => 8
            case SSPI => 9
            case SASL => 10
            case SHA256_PASSWORD => 10
            case SASL_CONTINUE => 11
            case MD5_SHA256_PASSWORD => 11
            case SASL_FINAL => 12
            case SM3_PASSWORD => 13
        }
    }
}

public interface AuthenticationMessage <: BackendMessage {}
