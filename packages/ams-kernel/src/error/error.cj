// ============================================================
// ams-kernel.error · 统一错误类型与错误码映射
//
// 设计要点（实测 SDK 1.0.5）：
//   ① 仓颉的 throw 只能抛 Exception 子类，**枚举不能被抛出**
//   ② 枚举构造器只写类型，不写参数名：| ValidationFailed
//   ③ 枚举没有 toString()，需用 match 显式映射
//
// 因此采用「enum 定义错误种类 + class 承载错误实例」的组合：
//   - 保留 kind 的可枚举性（便于 match 与指标聚合）
//   - 又能正常抛出
// ============================================================
package ams.kernel.error

/**
 * 错误种类。成员命名遵循官方 cjlint 规则 G.NAM.03（大驼峰）。
 */
public enum AppErrorKind {
    | ValidationFailed
    | Unauthorized
    | Forbidden
    | NotFound
    | Conflict
    | RateLimited
    | PayloadTooLarge
    | UnsupportedMediaType
    | CryptoFailure
    | StorageFailure
    | DatabaseFailure
    | Internal
}

/**
 * 错误种类 -> 对外错误码（SCREAMING_SNAKE_CASE）。
 * 对外 JSON 用此字符串；内部用枚举。
 */
public func kindToCode(kind: AppErrorKind): String {
    match (kind) {
        case AppErrorKind.ValidationFailed => "VALIDATION_FAILED"
        case AppErrorKind.Unauthorized => "UNAUTHORIZED"
        case AppErrorKind.Forbidden => "FORBIDDEN"
        case AppErrorKind.NotFound => "NOT_FOUND"
        case AppErrorKind.Conflict => "CONFLICT"
        case AppErrorKind.RateLimited => "RATE_LIMITED"
        case AppErrorKind.PayloadTooLarge => "PAYLOAD_TOO_LARGE"
        case AppErrorKind.UnsupportedMediaType => "UNSUPPORTED_MEDIA_TYPE"
        case AppErrorKind.CryptoFailure => "CRYPTO_FAILURE"
        case AppErrorKind.StorageFailure => "STORAGE_FAILURE"
        case AppErrorKind.DatabaseFailure => "DATABASE_FAILURE"
        case AppErrorKind.Internal => "INTERNAL_ERROR"
    }
}

/**
 * 错误种类 -> HTTP 状态码。
 * 单一映射表，避免各层各写一份。
 */
public func kindToHttpStatus(kind: AppErrorKind): Int64 {
    match (kind) {
        case AppErrorKind.ValidationFailed => 400
        case AppErrorKind.Unauthorized => 401
        case AppErrorKind.Forbidden => 403
        case AppErrorKind.NotFound => 404
        case AppErrorKind.Conflict => 409
        case AppErrorKind.PayloadTooLarge => 413
        case AppErrorKind.UnsupportedMediaType => 415
        case AppErrorKind.RateLimited => 429
        case AppErrorKind.CryptoFailure => 500
        case AppErrorKind.Internal => 500
        case AppErrorKind.StorageFailure => 503
        case AppErrorKind.DatabaseFailure => 503
    }
}

/**
 * 可抛出的业务异常。
 *
 * 规约：
 *   - message 面向用户，不得包含内部细节（SQL、堆栈、密钥）
 *   - 内部细节写日志，不进异常
 */
public class AppError <: Exception {
    /** 错误种类（用于 match 与指标聚合） */
    public let kind: AppErrorKind
    /** 对外错误码 */
    public let code: String
    /** HTTP 状态码 */
    public let httpStatus: Int64
    /** 出错字段（可空，如 "idCard"） */
    public let field: String

    public init(kind: AppErrorKind, message: String) {
        super(message)
        this.kind = kind
        this.code = kindToCode(kind)
        this.httpStatus = kindToHttpStatus(kind)
        this.field = ""
    }

    public init(kind: AppErrorKind, field: String, message: String) {
        super(message)
        this.kind = kind
        this.code = kindToCode(kind)
        this.httpStatus = kindToHttpStatus(kind)
        this.field = field
    }
}

/**
 * 构造校验错误。
 */
public func validationError(field: String, message: String): AppError {
    return AppError(AppErrorKind.ValidationFailed, field, message)
}

/**
 * 构造未认证错误。
 */
public func unauthorized(message!: String = "未认证或令牌无效"): AppError {
    return AppError(AppErrorKind.Unauthorized, message)
}

/**
 * 构造无权限错误。
 */
public func forbidden(message!: String = "无权限执行该操作"): AppError {
    return AppError(AppErrorKind.Forbidden, message)
}

/**
 * 构造资源不存在错误。
 */
public func notFound(resource: String): AppError {
    return AppError(AppErrorKind.NotFound, "${resource}不存在")
}

/**
 * 构造冲突错误。
 */
public func conflict(message: String): AppError {
    return AppError(AppErrorKind.Conflict, message)
}
