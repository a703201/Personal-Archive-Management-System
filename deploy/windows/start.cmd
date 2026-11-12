@echo off
REM ============================================================
REM AMS · Windows 前台启动脚本「示例」（物理机发布包）
REM
REM 参考 docs/09-部署与发布指南.md §2 交付物结构：发布包的
REM scripts/start.cmd 会加载 config/application.env；本示例改为从
REM config\ams.env 读取，仅用于演示加载方式，尚未与发布包集成/验证。
REM
REM [!] 这不是 Windows 服务：NSSM / WinSW 服务封装尚未落地，
REM     见 deploy/windows/README.md 与 docs/09 §4.1。
REM
REM 用法：把本文件放到发布包根目录（与 bin\、config\ 同级）后执行，
REM       或先自行 set 三个必填环境变量再启动。
REM ============================================================
setlocal EnableExtensions

cd /d "%~dp0"

REM 从 config\ams.env 逐行加载 KEY=VALUE（# 开头为注释，按第一个 = 切分）
if exist "%~dp0config\ams.env" (
    for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%~dp0config\ams.env") do (
        if not "%%~A"=="" set "%%~A=%%~B"
    )
)

REM SEC-001：缺令牌密钥直接拒绝启动（另两项请同样校验）
if "%AMS_TOKEN_SECRET%"=="" (
    echo [ERROR] 未设置 AMS_TOKEN_SECRET。请填写 config\ams.env 或先 set 环境变量。
    echo         生产必填：AMS_DB_PASSWORD / AMS_TOKEN_SECRET / AMS_KEK
    echo         见 deploy\RUNBOOK.md 凭据与 SEC-001 一节。
    exit /b 1
)

echo === AMS Server 前台启动，按 Ctrl+C 停止 ===
"%~dp0bin\ams-server.exe"
set "RC=%ERRORLEVEL%"
echo === 进程退出，代码 %RC% ===
exit /b %RC%
