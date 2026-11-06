# 插件说明

为了在不修改客户端程序的情况下，插入一些额外的功能，数据库驱动提供插件的功能。

插件有一个共同的父接口Interceptor，主要定义了插件名称和插件优先级，具体定义如下

```shell
public interface Interceptor {
    // 名称，相同类型的interceptor名称不能重复
    func name(): String
    // 优先级，越大，越优先执行
    func priority(): Int32
}
```

目前有连接插件PgConnInterceptorInteface、服务地址插件ServerAddrInterceptorInteface、语句插件StmtInterceptorInteface等提供额外便利功能的插件。
每个插件都有相应的管理类进行注册和管理。
如果在插件代码中想打断当前处理流程，那么可以抛出InterceptorBreakException异常。

## 1. 连接插件PgConnInterceptorInteface

```shell
public interface PgConnInterceptorInteface <: Interceptor {
    func connectStart(context: PgConnInterceptorContext): Unit
    func connectSuccess(context: PgConnInterceptorContext): Unit
    func connectException(context: PgConnInterceptorContext, ex: Exception): Unit
    func close(context: PgConnInterceptorContext): Unit
}
```

连接插件可以在连接的建立和关闭时触发插件的相应代码，处理自定义流程。

#### func connectStart
```shell
    func connectStart(context: PgConnInterceptorContext): Unit
```
开始建立连接。
参数：
- context：连接上下文

#### func connectSuccess
```shell
    func connectSuccess(context: PgConnInterceptorContext): Unit
```
建立连接成功。
参数：
- context：连接上下文

#### func connectException
```shell
    func connectException(context: PgConnInterceptorContext, ex: Exception): Unit
```
建立连接异常。
参数：
- context：连接上下文
- ex：异常信息

#### func connectException
```shell
    func connectException(context: PgConnInterceptorContext, ex: Exception): Unit
```
建立连接异常。
参数：
- context：连接上下文
- ex：异常信息

#### func close
```shell
    func close(context: PgConnInterceptorContext): Unit
```
关闭连接。
参数：
- context：连接上下文

## 2. 连接插件管理类PgConnInterceptorManager

连接插件管理类可以注册和删除连接插件。

#### func registerInterceptor
```shell
    func registerInterceptor(interceptor: PgConnInterceptorInteface): Unit
```
注册插件。
参数：
- interceptor：插件

#### func unregisterInterceptor
```shell
    func unregisterInterceptor(name: String): Unit
```
删除插件。
参数：
- name：插件名称

## 3. 服务地址插件ServerAddrInterceptorInteface

```shell
public interface ServerAddrInterceptorInteface <: Interceptor {
    func getServerAddr(context: ServerAddrInterceptorContext): ?(String, UInt16)
}
```

服务地址插件可以指定发起连接时的数据库服务的地址。

#### func getServerAddr
```shell
    func getServerAddr(context: ServerAddrInterceptorContext): ?(String, UInt16)
```
获取发起连接时的数据库服务的地址，如果没有合适的地址返回，那么可以返回Option<(String, UInt16)>.None让驱动使用原配置的地址。
参数：
- context：服务地址上下文
返回值：
- (String, UInt16)：返回数据库服务地址，格式是(数据库服务主机地址, 数据库服务端口)，如果返回Option<(String, UInt16)>.None，那么将会连接原配置的地址。

## 4. 服务地址插件管理类ServerAddrInterceptorManager

服务地址插件管理类可以注册和删除服务地址插件。

#### func registerInterceptor
```shell
    func registerInterceptor(interceptor: ServerAddrInterceptorInteface): Unit
```
注册插件。
参数：
- interceptor：插件

#### func unregisterInterceptor
```shell
    func unregisterInterceptor(name: String): Unit
```
删除插件。
参数：
- name：插件名称

## 5. 服务用户名密码插件ServerUserPasswordInterceptorInteface

```shell
public interface ServerUserPasswordInterceptorInteface <: Interceptor {
    func getServerUserPassword(context: ServerUserPasswordInterceptorContext): ?(String, String)
}
```

服务用户名密码插件可以指定连接数据库服务的用户名密码。

#### func getServerUserPassword
```shell
    func getServerUserPassword(context: ServerUserPasswordInterceptorContext): ?(String, String)
```
获取发起连接时的数据库服务的用户名密码，如果没有合适的用户名密码返回，那么可以返回Option<(String, String)>.None让驱动使用原配置的用户名密码。
参数：
- context：服务用户名密码上下文
返回值：
- (String, String)：返回数据库服务用户名密码，格式是(用户名, 密码)，如果返回Option<(String, String)>.None，那么将会连接原配置的用户名密码。

## 6. 服务用户名密码插件管理类ServerUserPasswordInterceptorManager

服务用户名密码插件管理类可以注册和删除服务用户名密码插件。

#### func registerInterceptor
```shell
    func registerInterceptor(interceptor: ServerUserPasswordInterceptorInteface): Unit
```
注册插件。
参数：
- interceptor：插件

#### func unregisterInterceptor
```shell
    func unregisterInterceptor(name: String): Unit
```
删除插件。
参数：
- name：插件名称

## 7. 语句插件StmtInterceptorInteface

```shell
public interface StmtInterceptorInteface <: Interceptor {
    func queryStart(context: StmtInterceptorContext): Unit
    func querySuccess(context: StmtInterceptorContext): Unit
    func queryException(context: StmtInterceptorContext, ex: Exception): Unit
    func updateStart(context: StmtInterceptorContext): Unit
    func updateSuccess(context: StmtInterceptorContext): Unit
    func updateException(context: StmtInterceptorContext, ex: Exception): Unit
}
```

语句插件可以在执行语句时触发插件的相应代码，处理自定义流程。

#### func queryStart
```shell
    func queryStart(context: StmtInterceptorContext): Unit
```
开始执行query语句。
参数：
- context：语句上下文

#### func querySuccess
```shell
    func querySuccess(context: StmtInterceptorContext): Unit
```
执行query语句成功。
参数：
- context：语句上下文

#### func queryException
```shell
    func queryException(context: StmtInterceptorContext, ex: Exception): Unit
```
执行query语句异常。
参数：
- context：语句上下文
- ex：异常信息

#### func updateStart
```shell
    func updateStart(context: StmtInterceptorContext): Unit
```
开始执行update语句。
参数：
- context：语句上下文

#### func updateSuccess
```shell
    func updateSuccess(context: StmtInterceptorContext): Unit
```
执行update语句成功。
参数：
- context：语句上下文

#### func updateException
```shell
    func updateException(context: StmtInterceptorContext, ex: Exception): Unit
```
执行update语句异常。
参数：
- context：语句上下文
- ex：异常信息

## 8. 语句插件管理类StmtInterceptorManager

语句插件管理类可以注册和删除语句插件。

#### func registerInterceptor
```shell
    func registerInterceptor(interceptor: StmtInterceptorInteface): Unit
```
注册插件。
参数：
- interceptor：插件

#### func unregisterInterceptor
```shell
    func unregisterInterceptor(name: String): Unit
```
删除插件。
参数：
- name：插件名称



