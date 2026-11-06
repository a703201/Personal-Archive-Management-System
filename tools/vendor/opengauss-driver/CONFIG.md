# 连接配置说明

数据库驱动提供了一些连接配置，以便更好地适配不同的环境。

这些连接配置可以设置到连接串中，比如 opengauss://bes:password@192.168.2.30:5432/bes?sslmode=prefer&connection_timeout=5000&read_timeout=10000&write_timeout=10000

## 1. 连接超时connection_timeout
发起网络连接最长等待时间。单位毫秒。

## 2. 读数据超时read_timeout
网络连接读取数据最长等待时间。单位毫秒。

## 3. 写数据超时write_timeout
网络连接写数据最长等待时间。单位毫秒。

## 4. 读缓冲区大小receive_buffer_size
网络连接SO_RCVBUF的大小。

## 5. 写缓冲区大小send_buffer_size
网络连接SO_SNDBUF的大小。
