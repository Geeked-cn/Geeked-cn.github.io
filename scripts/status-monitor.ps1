<#
.SYNOPSIS
    素素客状态监控脚本 - 检测前台应用并统计使用时长，定期同步到 GitHub Pages 博客。

.DESCRIPTION
    每 1.5 秒检测一次前台窗口对应的进程（应用），累计每个应用的使用时长，
    每 PUSH_INTERVAL 秒把状态写入 src/data/status.json 并自动 git 提交推送到 GitHub，
    触发博客的自动部署，网页侧边栏即可显示「素素客状态」。

    本地状态文件 status-state.json（含历史时长）不会被提交（已在 .gitignore 中）。

.PARAMETER PushInterval
    向 GitHub 同步的时间间隔（秒），默认 180（3 分钟）。
.PARAMETER SyncNow
    立即执行一次同步后继续监控。
#>
param(
    [int]$PushInterval = 180,
    [switch]$SyncNow
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$outputFile = Join-Path $repoRoot "src\data\status.json"
$stateFile = Join-Path $repoRoot "status-state.json"
$machineName = [Environment]::MachineName

$LOG_FILE = Join-Path $repoRoot "status-monitor.log"
function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Add-Content -LiteralPath $LOG_FILE -Value $line -Encoding UTF8
}

# ============ Win32 前台窗口检测 ============
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class FgWin {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
}
"@

function Get-ForegroundApp {
    $hwnd = [FgWin]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    if (-not [FgWin]::IsWindowVisible($hwnd)) { return $null }
    $len = [FgWin]::GetWindowTextLength($hwnd)
    if ($len -le 0) { return $null }
    $sb = New-Object System.Text.StringBuilder($len + 1)
    [void][FgWin]::GetWindowText($hwnd, $sb, $sb.Capacity)
    $title = $sb.ToString().Trim()
    if (-not $title) { return $null }
[uint32]$procId = 0
    [void][FgWin]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    return $proc.ProcessName
}

# 常见进程名 -> 显示名（其余回退为进程名）
$appDisplayNames = @{
    "chrome" = "Chrome"; "msedge" = "Edge"; "firefox" = "Firefox"; "brave" = "Brave";
    "code" = "VS Code"; "cursor" = "Cursor"; "windsurf" = "Windsurf";
    "pycharm64" = "PyCharm"; "idea64" = "IntelliJ IDEA"; "webstorm64" = "WebStorm";
    "goland64" = "GoLand"; "rider64" = "Rider"; "clion64" = "CLion";
    "WeChat" = "微信"; "Weixin" = "微信"; "QQ" = "QQ";
    "steam" = "Steam"; "steamwebhelper" = "Steam"; "epicgameslauncher" = "Epic";
    "discord" = "Discord"; "Telegram" = "Telegram";
    "explorer" = "资源管理器"; "powershell" = "PowerShell"; "pwsh" = "PowerShell";
    "WindowsTerminal" = "终端"; "cmd" = "命令行";
    "obs64" = "OBS"; "vlc" = "VLC"; "potplayer" = "PotPlayer";
    "wps" = "WPS"; "WINWORD" = "Word"; "EXCEL" = "Excel"; "POWERPNT" = "PowerPoint";
    "notepad" = "记事本"; "Notepad++" = "Notepad++"; "mspaint" = "画图";
    "Spotify" = "Spotify"; "Music" = "音乐"; "WindowsMediaPlayer" = "播放器";
    "python" = "Python"; "node" = "Node.js"; "git" = "Git";
    "Unity" = "Unity"; "UnrealEditor" = "UE5"; "Godot" = "Godot";
    "LeagueClient" = "英雄联盟"; "GTA5" = "GTA5"; "GTAV" = "GTA5";
    "bilibili" = "哔哩哔哩";
    "Huawei" = "华为"; "hwPCManager" = "华为电脑管家";
    "TencentMeeting" = "腾讯会议"; "Teams" = "Teams"; "Zoom" = "Zoom";
}

# 忽略这些系统/托盘进程
$ignoreProcesses = @(
    "ApplicationFrameHost", "explorer", "dllhost", "sihost", "taskhostw",
    "SearchApp", "LockApp", "TextInputHost", "ShellExperienceHost", "Widgets",
    "StartMenuExperienceHost", "backgroundTaskHost", "RuntimeBroker",
    "SearchHost", "SearchUI", "MicrosoftEdge", "winlogon", "LogonUI",
    "SecurityHealthSystray", "ShellHost", "SystemSettings", "Settings"
)

function Get-DisplayName {
    param([string]$procName)
    if ($appDisplayNames.ContainsKey($procName)) { return $appDisplayNames[$procName] }
    return $procName
}

# ============ 状态读写 ============
function Read-State {
    if (Test-Path -LiteralPath $stateFile) {
        try { return Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return $null
}

function Write-State {
    param($state)
    $json = $state | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($stateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-StatusFile {
    param($state, $currentApp, $currentSince)
    $status = [ordered]@{
        date = Get-Date -Format "yyyy-MM-dd"
        currentApp = $currentApp
        currentSince = $currentSince
        todayUsage = $state.usage
        sessionStart = $state.sessionStart
        lastUpdate = Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz"
        machine = $machineName
        running = $true
    }
    $json = $status | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($outputFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ============ Git 同步 ============
function Sync-ToGitHub {
    param($state, $currentApp, $currentSince)
    try {
        Write-StatusFile -state $state -currentApp $currentApp -currentSince $currentSince
        Push-Location $repoRoot
        git add -- "src/data/status.json"
        $status = git status --porcelain -- "src/data/status.json"
        if ($status) {
            git -c user.name="素素客状态" -c user.email="status@local" commit -m "chore: sync status ($currentApp)"
            git push
            Write-Log "已同步: $currentApp"
        } else {
            Write-Log "无变化，跳过提交"
        }
        Pop-Location
    } catch {
        Write-Log "同步失败: $($_.Exception.Message)"
        Pop-Location
    }
}

# ============ 主循环 ============
Write-Log "=== 素素客状态监控启动 (机器: $machineName) ==="

$state = Read-State
$today = Get-Date -Format "yyyy-MM-dd"
if (-not $state -or $state.date -ne $today -or -not $state.usage) {
    $state = [pscustomobject]@{
        date = $today
        usage = @{}
        sessionStart = Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz"
    }
}

$currentApp = "空闲"
$currentSince = (Get-Date).ToString("o")
$lastPush = (Get-Date).AddSeconds(-$PushInterval)
$lastTick = Get-Date
if ($SyncNow) { $lastPush = (Get-Date).AddSeconds(-$PushInterval) }

while ($true) {
    try {
        $now = Get-Date
        $todayNow = Get-Date -Format "yyyy-MM-dd"
        if ($todayNow -ne $state.date) {
            # 跨天重置时长
            $state.date = $todayNow
            $state.usage = @{}
            $state.sessionStart = $now.ToString("o")
        }

        $app = Get-ForegroundApp
        if ($app -and ($ignoreProcesses -contains $app)) { $app = $null }

        $display = if ($app) { Get-DisplayName $app } else { "空闲" }

$elapsed = ($now - $lastTick).TotalSeconds
        if ($elapsed -gt 0 -and $elapsed -lt 60) {
            $usage = $state.usage
            $existingNames = @($usage.PSObject.Properties.Name)
            if ($existingNames -notcontains $currentApp) {
                $usage | Add-Member -NotePropertyName $currentApp -NotePropertyValue 0.0
            }
            $currentValue = [double]($usage.$currentApp)
            $usage.$currentApp = $currentValue + $elapsed
        }
        $lastTick = $now

        if ($display -ne $currentApp) {
            $currentApp = $display
            $currentSince = $now.ToString("o")
        }

        # 定期同步
        if (($now - $lastPush).TotalSeconds -ge $PushInterval) {
            $lastPush = $now
            Write-State $state
            Sync-ToGitHub -state $state -currentApp $currentApp -currentSince $currentSince
        }
    } catch {
        Write-Log "主循环错误: $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 1500
}

