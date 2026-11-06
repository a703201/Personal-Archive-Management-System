<div align="center">
<h1>opengauss-driver</h1>
</div>

<p align="center">
<img alt="" src="https://img.shields.io/badge/release-v1.0.2-brightgreen" style="display: inline-block;" />
<img alt="" src="https://img.shields.io/badge/build-pass-brightgreen" style="display: inline-block;" />
<img alt="" src="https://img.shields.io/badge/cjc-v1.0.0-brightgreen" style="display: inline-block;" />
<img alt="" src="https://img.shields.io/badge/cjcov-NA-red" style="display: inline-block;" />
<img alt="" src="https://img.shields.io/badge/project-open-brightgreen" style="display: inline-block;" />
</p>

## 1 介绍

opengauss-driver是纯仓颉语言实现的[openGauss](https://opengauss.org/)和[PostgreSQL](https://www.postgresql.org/)数据库驱动。

## 2 特性

1. 通过在连接串中添加逗号隔开的多个数据库实例地址，可以让驱动连接主备集群实例
2. 驱动可以识别主实例，自动把DDL、DML、DCL发给主实例
3. transaction事务也会连接主实例来完成
4. 驱动有容错功能，碰到连接不上的实例时，会自动连接下一个正常的实例
5. 支持openGauss和PostgreSQL

##  3 架构

### 3.1 项目结构

```shell
├── data
├── samples
│   └── sqltype_example
│       ├── src
│       └── target
│           └── release
│               ├── bin
│               ├── opengauss
│               └── sqltype_example
├── src
│   ├── chunkreader
│   ├── collections
│   ├── driver
│   ├── error
│   ├── interx
│   ├── pgconn
│   ├── proto3
│   ├── sema
│   ├── slog
│   ├── sqlpool
│   ├── subtle
│   ├── test
│   │   ├── dbtypes
│   │   ├── driver
│   │   └── sqltypes
│   ├── tinypool
│   ├── url
│   └── utils
```

### 3.2 接口说明

参考仓颉官方的数据库接口文档

### 3.3 模块说明

1. [前后端通信协议模块](https://www.postgresql.org/docs/current/protocol.html): proto3
2. 前后端连接管理模块: pgconn
3. 驱动接口实现模块: driver
4. 简单数据库连接池模块: sqlpool

## 4 使用说明

仓颉提供的摘要算法和加密算法依赖OpenSSL3的crypto 动态库文件, 因此使用该驱动时需要确保本地环境有相应的动态库文件。

windows openSSL预编译包下载 -> https://slproweb.com/products/Win32OpenSSL.html

<img alt="" src="./doc/readme-image/env.png"/>

### 4.1 编译构建（Win/Linux/Mac）

cjpm.toml文件添加以下配置后，再执行cjpm update，即可在项目中引入opengauss-driver。（需要额外设置环境变量CANGJIE_STDX，值为stdx的路径， 具体参考cjpm.toml中的说明）

```toml
[dependencies]
  opengauss = {git = "https://gitcode.com/Cangjie-TPC/opengauss-driver.git", branch="master"}
```

### 4.2 功能示例

```sql
CREATE TABLE simple (
    id integer NOT NULL,
    varchar_col varchar(255) DEFAULT NULL,
    int_col integer DEFAULT NULL,
    double_col numeric(10,4) DEFAULT NULL,
    decimal_col decimal(10,5) DEFAULT NULL,
    date_col date DEFAULT NULL,
    time_col time DEFAULT NULL,
    datetime_col timestamp DEFAULT NULL,
    PRIMARY KEY (id)
)
```

####  查询数据(Query)

```cangjie
import std.time.*
import std.math.numeric.*
import std.database.sql.*
import cangjie_tpc::opengauss.driver.*

main(): Unit {
  
	var url = "opengauss://gorm:pass@7.212.133.32:5432/loggable?sslmode=disable"
    var driver = DriverManager.getDriver("opengauss").getOrThrow()
    var dataSource = driver.open(url)
    var connection = dataSource.connect()
    var statemnt = connection.prepareStatement("select * from simple")
    var result = statemnt.query()
    while (result.next()) {
        result.get<Int32>(1)
        result.getOrNull<String>(2)
        result.getOrNull<Int32>(3)
        result.getOrNull<Float64>(4)
        result.getOrNull<DateTime>(5)
        result.getOrNull<DateTime>(6)
        result.getOrNull<DateTime>(7)
        result.getOrNull<DateTime>(8)
    }    
	
}
```

#### 更新数据(Insert、Update、Delete)

```cangjie
import std.database.sql.*
import cangjie_tpc::opengauss.driver.*
import std.time.DateTime
import std.math.numeric.Decimal

main(): Unit {
  
    var url = "opengauss://gorm:pass@7.212.133.32:5432/loggable?sslmode=disable"
    var driver = DriverManager.getDriver("opengauss").getOrThrow()
    var dataSource = driver.open(url)
    var connection = dataSource.connect()

    var statemnt = connection.prepareStatement("insert into simple values (?, ?, ?, ?, ?, ?, ?, ?)")
    statemnt.set(1, 1000)
    statemnt.set(2, "opengauss")
    statemnt.setNull(3)
    statemnt.set(4, 123.456789)
    statemnt.set(5, 1.234567)
    statemnt.set(6, DateTime.now())
    statemnt.set(7, DateTime.now())
    statemnt.set(8, DateTime.now())
    var result = statemnt.update()

    println("effect row: ${result.rowCount} lastInsertId: ${result.lastInsertId}")
  
}
```

#### 获取事务对象

```cangjie
import mysql.cdbc.*
import std.database.sql.*

main(){
    var url = "opengauss://gorm:pass@7.212.133.32:5432/loggable?sslmode=disable"
    var driver = DriverManager.getDriver("opengauss").getOrThrow()
    var dataSource = driver.open(url)
    var connection =  dataSource.connect()
    var transaction = connection.createTransaction()
    transaction.begin()
    transaction.commit()
}
```

#### 更多

先使用data目录里面的sql文件创建样例表

```cangjie
import cangjie_tpc::opengauss.driver.*
import std.database.sql.*

func do_insert(db: Datasource): Unit {
    let cn = db.connect()
    let sql = 
        #"INSERT INTO "some_types" ("created_at","updated_at","deleted_at","source") VALUES ('2022-12-29 11:02:25.566','2022-12-29 11:02:25.566',NULL,'Dec 15 11:02:25') RETURNING "id""#
    try (st = cn.prepareStmt(sql)) {
        if (let Update(ur) = st.execute()) {
            logger.debug("${ur.rowCount}, ${ur.lastInsertId}")
        }
    } catch (e: Exception) {
        logger.error(e.message)
        e.printStackTrace()
    }
}

func do_query_single(db: Datasource): Unit {
    let cn = db.connect()
    let sql = "SELECT * FROM public.change_logs ORDER BY id ASC"
    try (st = cn.prepareStmt(sql)) {
        if (let Query(qr) = st.execute()) {
            while (qr.next()) {
                logger.debug(
                    "${qr.getString(0)} ${qr.getTime(1)} ${qr.getString(2)} ${qr.getString(3)} ${qr.getString(6)}")
            }
            qr.close()
        }
    } catch (e: Exception) {
        logger.debug("exception ${e.message}")
        e.printStackTrace()
    }
}
func test_og(): Unit {
    var url = "opengauss://gorm:pass@7.212.133.32:5432/loggable?sslmode=disable"
    let db = sqlpool.openDb("opengauss", url)
    let p = db.ping()
    println("ping opengauss OK.")
    do_insert(db)
    do_query_single(db)
}
func test_pg(): Unit {
    logger.level = LogLevel.DEBUG
    var url = "postgres://gorm:pass@127.0.0.1:5432/loggable?sslmode=disable"
    let db = sqlpool.openDb("postgres", url)
    let p = db.ping()
    println("ping postgres OK.")
    do_insert(db)
    do_query_single(db)
}
main() {
	test_og()
	test_pg()
}

```

## 5 开源协议

本项目基于 [木兰宽松许可证，第2版](http://license.coscl.org.cn/MulanPSL2) ，请自由的享受和参与开源。

## 6 参与贡献

欢迎给我们提交PR，欢迎给我们提交Issue，欢迎参与任何形式的贡献。

