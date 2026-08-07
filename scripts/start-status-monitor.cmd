@echo off
rem 素素客状态监控启动器（供计划任务调用）
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0status-monitor.ps1" -PushInterval 180