<#
.SYNOPSIS
    注册「素素客状态监控」开机自启计划任务（登录时启动）。

.DESCRIPTION
    创建 Windows 计划任务：用户登录时自动运行 start-status-monitor.cmd，
    隐藏窗口启动状态监控脚本，自动记录应用使用时长并同步到 GitHub。
    需以管理员权限运行一次。
#>
$taskName = "SuSuKe-StatusMonitor"
$launcher = Join-Path $PSScriptRoot "start-status-monitor.cmd"

if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Host "启动器不存在: $launcher" -ForegroundColor Red
    exit 1
}

# 删除旧任务
schtasks /Delete /TN $taskName /F | Out-Null

# 创建登录时启动的任务（使用当前用户，无需密码）
schtasks /Create /TN $taskName /SC ONLOGON /TR "`"$launcher`"" /RL LIMITED /F

Write-Host "已注册登录自启任务: $taskName" -ForegroundColor Green
Write-Host "启动器: $launcher"