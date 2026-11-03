# =====================================================================
# 早八 zaoba · Windows 客户端远程接管 一键配置脚本
# ---------------------------------------------------------------------
# 作用：让 Docker 容器（跑在 NAS/服务器上）能够通过网络
#       接管这台 Windows 电脑上正在运行的 AI 客户端（Trae / WorkBuddy /
#       豆包工作 / Qoder 等），替你完成每日签到。
#
# 原理：客户端的 CDP 调试端口只监听 127.0.0.1，局域网访问不到。
#       本脚本用 Windows 自带的 netsh portproxy 把端口转发出去，
#       并放行防火墙。配置重启后依然有效。
#
# 用法（管理员 PowerShell）：
#  powershell -ExecutionPolicy Bypass -File windows-cdp-setup.ps1            # 安装（默认 4 个端口）
#   powershell -ExecutionPolicy Bypass -File windows-cdp-setup.ps1 -Ports 9223,9333   # 只装指定端口
#   powershell -ExecutionPolicy Bypass -File windows-cdp-setup.ps1 -Remove   # 卸载全部
#   powershell -ExecutionPolicy Bypass -File windows-cdp-setup.ps1 -Status   # 查看当前状态
#
# 端口对照（与 zaoba config.json 一致）：
#   9223  Trae CN / Qoder CN（两家默认同端口，同机同时开需给 Qoder 改端口）
#   9333  WorkBuddy（靠环境变量开启，不是命令行参数）
#   9444  豆包工作
#   9445  豆包（注：当前版本客户端不支持 CDP，装了也接管不了）
# =====================================================================

param(
  [int[]]$Ports = @(9223, 9333, 9444, 9445),
  [string]$ListenAddress = '0.0.0.0',
  [switch]$Remove,
  [switch]$Status
)

$ErrorActionPreference = 'Stop'
$RuleName = 'zaoba-cdp'

# ---- 自动提权（portproxy/防火墙都需要管理员）----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host '[!] 需要管理员权限，正在自动提升（请在弹出的 UAC 窗口点"是"）...' -ForegroundColor Yellow
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  if ($Remove) { $argList += '-Remove' }
  if ($Status) { $argList += '-Status' }
  if ($Ports -ne @(9223, 9333, 9444, 9445)) { $argList += "-Ports $($Ports -join ',')" }
  Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait
  exit
}

# ---- 查看模式 ----
if ($Status) {
  Write-Host '==== 当前端口转发规则 ====' -ForegroundColor Cyan
  netsh interface portproxy show all
  Write-Host ''
  Write-Host '==== 防火墙规则 ====' -ForegroundColor Cyan
  Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue |
    Select-Object DisplayName, Enabled, Direction, Action | Format-Table
  exit
}

# ---- 卸载模式 ----
if ($Remove) {
  foreach ($p in $Ports) {
    netsh interface portproxy delete v4tov4 listenport=$p listenaddress=$ListenAddress | Out-Null
    Write-Host "[ok] 已删除端口转发 $ListenAddress`:$p" -ForegroundColor Green
  }
  Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  Write-Host "[ok] 已删除防火墙规则 $RuleName" -ForegroundColor Green
  if ($Ports -contains 9333) {
    [Environment]::SetEnvironmentVariable('WORKBUDDY_REMOTE_DEBUGGING_PORT', $null, 'User')
    Write-Host '[ok] 已删除用户环境变量 WORKBUDDY_REMOTE_DEBUGGING_PORT' -ForegroundColor Green
  }
  Write-Host ''
  Write-Host '卸载完成。别忘了：重启客户端（去掉调试参数）。' -ForegroundColor Cyan
  exit
}

# ---- 安装模式 ----
Write-Host "==> 目标端口: $($Ports -join ', ')" -ForegroundColor Cyan

# 1) 端口转发：0.0.0.0:port -> 127.0.0.1:port
foreach ($p in $Ports) {
  # 幂等：先删旧规则再建
  netsh interface portproxy delete v4tov4 listenport=$p listenaddress=$ListenAddress | Out-Null
  netsh interface portproxy add v4tov4 listenport=$p listenaddress=$ListenAddress connectport=$p connectaddress=127.0.0.1 | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "[ok] 端口转发 $ListenAddress`:$p -> 127.0.0.1:$p" -ForegroundColor Green
  } else {
    Write-Host "[!!] 端口转发 $p 建立失败（退出码 $LASTEXITCODE），请确认 IP Helper 服务(iphlpsvc)已启动" -ForegroundColor Red
  }
}

# 2) 防火墙放行（一条规则覆盖全部端口）
Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort ($Ports -join ',') | Out-Null
Write-Host "[ok] 防火墙放行入站 TCP: $($Ports -join ', ') （规则名 $RuleName）" -ForegroundColor Green

# 3) WorkBuddy：它只认环境变量（命令行参数会被拒），写入用户级环境变量
if ($Ports -contains 9333) {
  [Environment]::SetEnvironmentVariable('WORKBUDDY_REMOTE_DEBUGGING_PORT', '9333', 'User')
  Write-Host '[ok] 已写入用户环境变量 WORKBUDDY_REMOTE_DEBUGGING_PORT=9333（重启 WorkBuddy 后生效）' -ForegroundColor Green
}

# 4) 本机局域网 IP（填到 Docker 的 ZAOBA_CDP_HOST）
$lanIps = Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object -ExpandProperty IPAddress
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' 网络侧配置完成！接下来 3 步：' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host ' 第 1 步 · 让客户端带调试端口运行（关键！每次开机都要有效）：' -ForegroundColor Yellow
Write-Host '   - WorkBuddy：本脚本已帮你写入用户环境变量，重启 WorkBuddy 后生效'
Write-Host '   - Trae / Qoder / 豆包工作：右键客户端快捷方式 -> 属性 -> 目标，末尾追加：'
Write-Host ('       --remote-debugging-port=端口号   （Trae 用 9223，豆包工作用 9444）')
Write-Host '     然后把改好的快捷方式放进 shell:startup 实现开机自启'
Write-Host ''
Write-Host ' 第 2 步 · 在 Docker 侧（NAS/服务器）配置目标地址：' -ForegroundColor Yellow
Write-Host ('   这台电脑的局域网 IP 是: ' + ($lanIps -join ' / ')) -ForegroundColor White
Write-Host '   docker run 加参数:      -e ZAOBA_CDP_HOST=<上面的IP>'
Write-Host '   docker compose 加环境变量: ZAOBA_CDP_HOST=<上面的IP>'
Write-Host ''
Write-Host ' 第 3 步 · 验证（在 NAS/服务器上执行）：' -ForegroundColor Yellow
Write-Host '   curl http://<这台电脑的IP>:9223/json/version   # 有 JSON 输出即通'
Write-Host ''
Write-Host ' 注意：客户端调试端口只应暴露在家庭/办公内网使用，不要把端口映射到公网。' -ForegroundColor Magenta
