@echo off
chcp 65001 >nul
title QQ 群重复成员检查
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0qq_group.ps1"

echo.
echo 运行结束，按任意键关闭窗口...
pause >nul
exit /b 0