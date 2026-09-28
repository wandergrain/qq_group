<#
 
常用参数：
  -Api <地址>        NapCat 接口地址，默认 http://127.0.0.1:3000
  -Token <令牌>      接口令牌，默认 dupcheck-7f3a
  -Out <文件>        CSV 输出路径
  -Delay <毫秒>      每个群之间的请求间隔，默认 100（过密会被 QQ 风控掉线，可调大）
  -Exclude <群号>    跳过的群（重跑时用于跳过已扫描的群）
  -ExcludeQq <QQ号>  命中和结果中额外剔除的 QQ 号
  -FindQq <QQ号>     QQ号反查的目标号，可多个
  -Rank              出现群数排行
  -RankTop <数量>     排行显示前多少名，默认 20
  （群号/QQ号列表均支持 英文逗号、中文逗号、顿号 或空格 分隔）

如果提示禁止运行脚本，用这种方式运行：
  powershell -ExecutionPolicy Bypass -File .\qq_group_duplicate_check.ps1 -All -Target 222222

使用前请确认 NapCat 已启动并登录。
#>

param(
  [switch]$All,
  [string]$Target = '',
  [string]$FindQq = '',
  [switch]$Rank,
  [int]$RankTop = 20,
  [string]$Api = 'http://127.0.0.1:3000',
  [string]$Token = 'dupcheck-7f3a',
  [string]$Out = '',
  [int]$Delay = 100,
  [string[]]$Exclude = @(),
  [string[]]$ExcludeQq = @()
)

$ErrorActionPreference = 'Stop'
$script:Api = $Api
$script:Token = $Token

$OfficialBotQqu = @('2854196310')   # Q群管家
$RoleText = @{ owner = '群主'; admin = '管理员'; member = '成员' }

# ============ NapCat 接口 ============

function Invoke-NapCatApi {
  param([string]$Action, [hashtable]$Params)
  $headers = @{ 'Content-Type' = 'application/json' }
  if ($script:Token) { $headers['Authorization'] = "Bearer $($script:Token)" }
  try {
    $resp = Invoke-RestMethod -Uri "$($script:Api)/$Action" -Method Post -Headers $headers -Body ($Params | ConvertTo-Json -Compress) -TimeoutSec 30
  } catch {
    throw "无法连接 $($script:Api)（请确认 NapCat 已启动且已登录）: $($_.Exception.Message)"
  }
  if ($resp.status -ne 'ok' -or $resp.retcode -ne 0) {
    throw "调用 $Action 失败: retcode=$($resp.retcode) $($resp.message)"
  }
  return $resp.data
}

function Get-GroupMembers {
  param([string]$GroupId)
  return @(Invoke-NapCatApi -Action 'get_group_member_list' -Params @{ group_id = [long]$GroupId })
}

# 获取账号加入的群列表，去掉 -Exclude 指定的群；SkipId 为目标群（单独处理）
function Get-AccountGroups {
  param([string]$SkipId = '')
  Write-Host '正在获取账号加入的群列表...'
  $groups = @(Invoke-NapCatApi -Action 'get_group_list' -Params @{})
  Write-Host "账号共加入 $($groups.Count) 个群"

  $excludeSet = @{}
  foreach ($item in @($Exclude)) {
    foreach ($gid in ("$item" -split '[,\s，、]+')) { if ($gid) { $excludeSet[$gid.Trim()] = $true } }
  }
  $skipped = @($groups | Where-Object { "$($_.group_id)" -ne "$SkipId" -and $excludeSet.ContainsKey("$($_.group_id)") }).Count
  if ($skipped -gt 0) { Write-Host "已按 -Exclude 跳过 $skipped 个群" }

  $others = @($groups | Where-Object { "$($_.group_id)" -ne "$SkipId" -and -not $excludeSet.ContainsKey("$($_.group_id)") })
  $target = if ($SkipId) { @($groups | Where-Object { "$($_.group_id)" -eq "$SkipId" })[0] } else { $null }
  return @{ others = $others; target = $target }
}

# 汇总需要剔除的 QQ 号：扫描账号自身 + 官方机器人 + -ExcludeQq 指定
function Build-ExcludeQq {
  $set = New-Object System.Collections.Generic.HashSet[string]
  foreach ($item in @($ExcludeQq) + $OfficialBotQqu) {
    foreach ($q in ("$item" -split '[,\s，、]+')) { if ($q) { [void]$set.Add($q.Trim()) } }
  }
  try {
    $info = Invoke-NapCatApi -Action 'get_login_info' -Params @{}
    if ($info -and $info.user_id) { [void]$set.Add("$($info.user_id)") }
  } catch { }
  return $set
}

# ============ 通用扫描循环 ============
# 依次读取每个群的成员：打印进度、记录失败/不完整、连续失败自动中止。
# $OnGroup 回调接收 (群对象, 成员数组)，返回进度行结尾的补充文字。
function Invoke-ScanLoop {
  param($Groups, [scriptblock]$OnGroup, [string]$ResumeBase, [switch]$AllowResume)
  $failed = New-Object System.Collections.Generic.List[string]
  $partial = New-Object System.Collections.Generic.List[string]
  $scanned = New-Object System.Collections.Generic.List[string]
  $failStreak = 0
  $aborted = $false
  $total = @($Groups).Count

  for ($i = 0; $i -lt $total; $i++) {
    $g = $Groups[$i]
    $label = "[$($i + 1)/$total] $($g.group_name)($($g.group_id))"
    try {
      $members = Get-GroupMembers -GroupId "$($g.group_id)"
      $failStreak = 0
      $scanned.Add("$($g.group_id)")
      if ($g.member_count -and $members.Count -lt [int]$g.member_count) {
        $partial.Add("$label 只取到 $($members.Count)/$($g.member_count) 人，可能漏检")
      }
      $extra = & $OnGroup $g $members
      Write-Host "$label -> $($members.Count) 人，$extra"
    } catch {
      $failStreak++
      $failed.Add("$label -> $($_.Exception.Message)")
      Write-Host "$label -> 失败: $($_.Exception.Message)"
      if ($failStreak -ge 3) {
        $aborted = $true
        Write-Host ''
        Write-Host "连续 $failStreak 个群请求失败，判断 NapCat/QQ 已断开，提前中止扫描。"
        Write-Host '请重启 NapCat 并登录后重跑：'
        if ($AllowResume) { Write-Host ("  $ResumeBase -Exclude " + ($scanned -join ',')) }
        else { Write-Host "  $ResumeBase" }
        break
      }
    }
    if ($i -lt $total - 1 -and $Delay -gt 0) { Start-Sleep -Milliseconds $Delay }
  }
  return @{ failed = $failed; partial = $partial; scanned = $scanned; aborted = $aborted }
}

# ============ 输出助手 ============

# 显示名：昵称与群名片不一致时显示"昵称/名片"，一致或缺失时只显示一个
function Get-NamePair {
  param($Member)
  $nick = "$($Member.nickname)".Trim()
  $card = "$($Member.card)".Trim()
  if ($nick -and $card -and $nick -ne $card) { return "$nick/$card" }
  if ($nick) { return $nick }
  return $card
}

function Get-RoleText {
  param($Role)
  if ($RoleText.ContainsKey("$Role")) { return $RoleText["$Role"] }
  return "$Role"
}

function ConvertTo-CsvCell {
  param($Value)
  $s = "$Value"
  if ($s -match '[",\r\n]') { return '"' + ($s -replace '"', '""') + '"' }
  return $s
}

# 写出文本文件（UTF-8 带 BOM，记事本/Excel 打开中文不乱码）
function Save-TextFile {
  param([string]$Path, [string[]]$Lines)
  $full = [System.IO.Path]::GetFullPath($Path)
  [System.IO.File]::WriteAllText($full, ($Lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
  Write-Host "结果已保存: $full"
}

function Save-CsvRows {
  param([string]$Path, [string]$Header, $Rows)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add($Header)
  foreach ($row in $Rows) {
    $lines.Add((@($row | ForEach-Object { ConvertTo-CsvCell $_ }) -join ','))
  }
  Save-TextFile -Path $Path -Lines $lines
}

# 控制台：一个 QQ 号下面每群一行
function Write-GroupLines {
  param([string]$Header, $Hits)
  Write-Host $Header
  $i = 0
  foreach ($h in $Hits) {
    $i++
    Write-Host ("  [" + $i.ToString().PadLeft(2) + "] " + $h.name + "($($h.id))  " + $h.role)
  }
  Write-Host ''
}

# 扫描后的"可能不完整 / 获取失败"提示
function Write-ScanNotes {
  param($Scan)
  if ($Scan.partial.Count -gt 0) {
    Write-Host ''
    Write-Host '注意：以下群的成员列表可能不完整，结果可能漏检:'
    foreach ($s in $Scan.partial) { Write-Host "  $s" }
  }
  if ($Scan.failed.Count -gt 0) {
    Write-Host ''
    Write-Host '以下群获取失败（未参与比对）:'
    foreach ($s in $Scan.failed) { Write-Host "  $s" }
  }
}

# ============ 模式一：全群扫描 ============

function Invoke-ScanAllGroups {
  param([string]$TargetId)
  Write-Host "接口: $script:Api"
  $acc = Get-AccountGroups -SkipId $TargetId
  if ($acc.target) { Write-Host "目标群: $($acc.target.group_name)($TargetId)" }
  else { Write-Host "（目标群 $TargetId 不在群列表中，仍尝试直接获取其成员）" }

  $targetMembers = Get-GroupMembers -GroupId $TargetId
  Write-Host "目标群成员: $($targetMembers.Count) 人"

  # 命中统计就开始剔除：扫描账号自身 + 官方机器人 + -ExcludeQq 指定
  $excludeQqSet = Build-ExcludeQq
  $targetMap = @{}
  foreach ($m in $targetMembers) { $targetMap["$($m.user_id)"] = $m }

  Write-Host "开始扫描其余 $($acc.others.Count) 个群（每群间隔 ${Delay}ms）..."
  Write-Host '提示: 请求过密可能触发 QQ 风控掉线，如中途失败可调大 -Delay 后重跑'
  Write-Host '命中数已剔除扫描账号自身和 Q群管家等官方机器人'
  Write-Host ''

  $hits = @{}   # QQ号 -> List[@{ name; id; role }]
  $onGroup = {
    param($g, $members)
    $matched = @($members | Where-Object { $targetMap.ContainsKey("$($_.user_id)") -and -not $excludeQqSet.Contains("$($_.user_id)") })
    foreach ($m in $matched) {
      $qq = "$($m.user_id)"
      if (-not $hits.ContainsKey($qq)) { $hits[$qq] = New-Object System.Collections.Generic.List[object] }
      $hits[$qq].Add(@{ name = "$($g.group_name)"; id = "$($g.group_id)"; role = (Get-RoleText $m.role) })
    }
    return "命中 $($matched.Count) 人"
  }
  $scan = Invoke-ScanLoop -Groups $acc.others -OnGroup $onGroup -ResumeBase "-All -Target $TargetId" -AllowResume

  $results = @()
  foreach ($qq in @($hits.Keys)) {
    $results += [pscustomobject]@{ qq = $qq; member = $targetMap[$qq]; list = $hits[$qq] }
  }
  $results = @($results | Sort-Object @{ Expression = { $_.list.Count }; Descending = $true }, @{ Expression = { [long]$_.qq }; Descending = $false })

  Write-Host ''
  if ($scan.aborted) { Write-Host '注意: 扫描提前中止，以下仅为已扫描部分的结果。' }
  Write-Host "共扫描 $($scan.scanned.Count)/$($acc.others.Count) 个群；目标群 $($targetMembers.Count) 人，其中 $($results.Count) 人出现在其它群"
  Write-Host ('-' * 70)
  foreach ($r in $results) {
    Write-GroupLines -Header "QQ号 $($r.qq)（$(Get-NamePair $r.member)）：出现在 $($r.list.Count) 个其它群" -Hits $r.list
  }
  Write-Host ('-' * 70)

  Write-ScanNotes -Scan $scan

  $rows = @()
  foreach ($r in $results) {
    foreach ($h in $r.list) { $rows += , @($r.qq, $r.member.nickname, $r.member.card, $h.name, $h.id, $h.role) }
  }
  $outPath = if ($Out) { $Out } else { "duplicated_members_all_vs_$TargetId.csv" }
  Save-CsvRows -Path $outPath -Header 'QQ号,目标群昵称,目标群名片,群名,群号,身份' -Rows $rows

  # TXT 版：和窗口里显示的一致，方便直接发人
  $txtLines = New-Object System.Collections.Generic.List[string]
  $tname = if ($acc.target) { $acc.target.group_name } else { '未命名' }
  $txtLines.Add("目标群 $tname($TargetId)：$($targetMembers.Count) 人，其中 $($results.Count) 人出现在其它群")
  $txtLines.Add('')
  foreach ($r in $results) {
    $txtLines.Add("QQ号 $($r.qq)（$(Get-NamePair $r.member)）：出现在 $($r.list.Count) 个其它群")
    $i = 0
    foreach ($h in $r.list) { $i++; $txtLines.Add("  [" + $i.ToString().PadLeft(2) + "] " + $h.name + "($($h.id))  " + $h.role) }
    $txtLines.Add('')
  }
  Save-TextFile -Path ([System.IO.Path]::ChangeExtension($outPath, '.txt')) -Lines $txtLines
}

# ============ 模式二：QQ号反查 ============

function Invoke-FindQq {
  param([string[]]$QqList)
  $targets = New-Object System.Collections.Generic.List[string]
  foreach ($item in $QqList) {
    foreach ($q in ("$item" -split '[,\s，、]+')) {
      $q = $q.Trim()
      if ($q -match '^\d+$' -and $targets -notcontains $q) { $targets.Add($q) }
    }
  }
  if ($targets.Count -eq 0) { Write-Host '请提供要查询的 QQ 号。'; return }

  Write-Host "接口: $script:Api"
  Write-Host "查询目标: $($targets -join '、')"
  $acc = Get-AccountGroups
  Write-Host "开始扫描 $($acc.others.Count) 个群（每群间隔 ${Delay}ms）..."
  Write-Host '提示: 请求过密可能触发 QQ 风控掉线，如中途失败可调大 -Delay 后重跑'
  Write-Host ''

  $targetSet = New-Object System.Collections.Generic.HashSet[string]
  $hits = @{}    # QQ号 -> List[@{ name; id; role }]
  $names = @{}   # QQ号 -> 昵称
  foreach ($qq in $targets) {
    [void]$targetSet.Add($qq)
    $hits[$qq] = New-Object System.Collections.Generic.List[object]
  }

  $onGroup = {
    param($g, $members)
    $found = @($members | Where-Object { $targetSet.Contains("$($_.user_id)") })
    foreach ($m in $found) {
      $qq = "$($m.user_id)"
      $hits[$qq].Add(@{ name = "$($g.group_name)"; id = "$($g.group_id)"; role = (Get-RoleText $m.role) })
      $nick = "$($m.nickname)"
      if (-not $nick.Trim()) { $nick = "$($m.card)" }
      $names[$qq] = $nick
    }
    return "命中 $($found.Count) 个查询号"
  }
  $scan = Invoke-ScanLoop -Groups $acc.others -OnGroup $onGroup -ResumeBase "-FindQq $($targets -join ',')" -AllowResume

  $results = @()
  foreach ($qq in $targets) { $results += [pscustomobject]@{ qq = $qq; list = $hits[$qq] } }
  $results = @($results | Sort-Object @{ Expression = { $_.list.Count }; Descending = $true }, @{ Expression = { [long]$_.qq }; Descending = $false })
  $missCount = @($results | Where-Object { $_.list.Count -eq 0 }).Count

  Write-Host ''
  if ($scan.aborted) { Write-Host '注意: 扫描提前中止，未扫描的群没有检查，结果可能偏少。' }
  Write-Host "共扫描 $($scan.scanned.Count)/$($acc.others.Count) 个群；$($targets.Count) 个查询号中 $($targets.Count - $missCount) 个有出现记录"
  Write-Host ('-' * 70)
  foreach ($r in $results) {
    if ($r.list.Count -eq 0) { Write-Host "QQ号 $($r.qq)：未出现在已扫描的群里"; Write-Host ''; continue }
    $nick = "$($names[$r.qq])"
    $nameText = if ($nick.Trim()) { "（$nick）" } else { '' }
    Write-GroupLines -Header "QQ号 $($r.qq)$nameText：出现在 $($r.list.Count) 个群" -Hits $r.list
  }
  Write-Host ('-' * 70)

  Write-ScanNotes -Scan $scan

  $rows = @()
  foreach ($r in $results) {
    $nick = "$($names[$r.qq])"
    if ($r.list.Count -eq 0) { $rows += , @($r.qq, $nick, '（未出现）', '', ''); continue }
    foreach ($h in $r.list) { $rows += , @($r.qq, $nick, $h.name, $h.id, $h.role) }
  }
  $outPath = if ($Out) { $Out }
    elseif ($targets.Count -eq 1) { "qq_lookup_$($targets[0]).csv" }
    else { 'qq_lookup_multi.csv' }
  Save-CsvRows -Path $outPath -Header 'QQ号,QQ昵称,群名,群号,身份' -Rows $rows

  # TXT 版：和窗口里显示的一致，方便直接发人
  $txtLines = New-Object System.Collections.Generic.List[string]
  $txtLines.Add("查询目标：$($targets -join '、')")
  $txtLines.Add('')
  foreach ($r in $results) {
    if ($r.list.Count -eq 0) { $txtLines.Add("QQ号 $($r.qq)：未出现在已扫描的群里"); $txtLines.Add(''); continue }
    $nick = "$($names[$r.qq])"
    $nameText = if ($nick.Trim()) { "（$nick）" } else { '' }
    $txtLines.Add("QQ号 $($r.qq)$nameText：出现在 $($r.list.Count) 个群")
    $i = 0
    foreach ($h in $r.list) { $i++; $txtLines.Add("  [" + $i.ToString().PadLeft(2) + "] " + $h.name + "($($h.id))  " + $h.role) }
    $txtLines.Add('')
  }
  Save-TextFile -Path ([System.IO.Path]::ChangeExtension($outPath, '.txt')) -Lines $txtLines
}

# ============ 模式三：出现群数排行 ============

function Invoke-RankTop {
  param([int]$Top = 20)
  if ($Top -lt 1) { $Top = 20 }
  Write-Host "接口: $script:Api"
  $acc = Get-AccountGroups
  Write-Host "开始扫描 $($acc.others.Count) 个群（每群间隔 ${Delay}ms）..."
  Write-Host '提示: 请求过密可能触发 QQ 风控掉线，如中途失败可调大 -Delay 后重跑'
  Write-Host ''

  $rank = @{}   # QQ号 -> @{ count; name; groups = List[@{ name; id; role }] }
  $onGroup = {
    param($g, $members)
    foreach ($m in $members) {
      $qq = "$($m.user_id)"
      $info = @{ name = "$($g.group_name)"; id = "$($g.group_id)"; role = (Get-RoleText $m.role) }
      if ($rank.ContainsKey($qq)) {
        $rank[$qq].count++
        $rank[$qq].name = Get-NamePair $m
        $rank[$qq].groups.Add($info)
      } else {
        $rank[$qq] = @{ count = 1; name = (Get-NamePair $m); groups = (New-Object System.Collections.Generic.List[object]) }
        $rank[$qq].groups.Add($info)
      }
    }
    return "累计 QQ 数 $($rank.Count)"
  }
  $scan = Invoke-ScanLoop -Groups $acc.others -OnGroup $onGroup -ResumeBase '-Rank（排行需要完整扫描，建议重启后整跑）'

  Write-Host ''
  Write-Host "扫描完成，正在整理 $($rank.Count) 个 QQ 号的统计结果（请稍候几秒）..."
  $excludeQqSet = Build-ExcludeQq
  $removed = 0
  $allList = New-Object System.Collections.Generic.List[object]
  foreach ($qq in @($rank.Keys)) {
    if ($excludeQqSet.Contains($qq)) { $removed++; continue }
    $allList.Add([pscustomobject]@{ qq = $qq; count = $rank[$qq].count; name = $rank[$qq].name; groups = $rank[$qq].groups })
  }

  Write-Host '正在排序...'
  $cmp = [System.Comparison[object]]{ param($a, $b) ([int]$b.count) - ([int]$a.count) }
  $allList.Sort($cmp)
  $topRows = @($allList | Select-Object -First $Top)
  Write-Host '排序完成。'

  Write-Host ''
  if ($scan.aborted -or $scan.failed.Count -gt 0) { Write-Host '注意: 有群未成功读取，统计数量可能偏低。' }
  Write-Host "共扫描 $($scan.scanned.Count)/$($acc.others.Count) 个群，统计到 $($rank.Count) 个 QQ 号；剔除 $removed 个特殊号（扫描账号自身/官方机器人/-ExcludeQq）"
  Write-Host "出现群数最多的前 $($topRows.Count) 名："
  Write-Host ('-' * 70)
  Write-Host '排名  QQ号        出现群数 昵称/名片'
  $idx = 0
  foreach ($r in $topRows) {
    $idx++
    Write-Host ("{0,-5} {1,-11} {2,-8} {3}" -f $idx, $r.qq, $r.count, $r.name)
  }
  Write-Host ('-' * 70)

  Write-ScanNotes -Scan $scan

  $rows = @()
  $idx = 0
  foreach ($r in $topRows) {
    $idx++
    foreach ($h in $r.groups) { $rows += , @($idx, $r.qq, $r.count, $r.name, $h.name, $h.id, $h.role) }
  }
  $outPath = if ($Out) { $Out } else { "group_rank_top$Top.csv" }
  Save-CsvRows -Path $outPath -Header '排名,QQ号,出现群数,昵称/名片,群名,群号,身份' -Rows $rows

  # TXT 版：和窗口里显示的一致（明细看 CSV）
  $txtLines = New-Object System.Collections.Generic.List[string]
  $txtLines.Add("共扫描 $($scan.scanned.Count)/$($acc.others.Count) 个群，统计到 $($rank.Count) 个 QQ 号；出现群数最多的前 $($topRows.Count) 名：")
  $txtLines.Add('排名  QQ号        出现群数 昵称/名片')
  $idx = 0
  foreach ($r in $topRows) {
    $idx++
    $txtLines.Add(("{0,-5} {1,-11} {2,-8} {3}" -f $idx, $r.qq, $r.count, $r.name))
  }
  Save-TextFile -Path ([System.IO.Path]::ChangeExtension($outPath, '.txt')) -Lines $txtLines
}

# ============ 交互菜单 / 入口 ============

function Start-Interactive {
  while ($true) {
    Write-Host '======================================'
    Write-Host '   QQ 群重复成员检查（基于 NapCat 接口）'
    Write-Host '======================================'
    Write-Host '   1 全群扫描：找某群成员还出现在哪些群'
    Write-Host '   2 QQ号反查：查某个 QQ 出现在哪些群（支持多选）'
    Write-Host '   3 用户出现群数排行：谁出现在最多的群里'
    Write-Host '   4 退出'
    Write-Host '======================================'
    $mode = (Read-Host '请输入 1 到 4 后回车').Trim()
    if ($mode -eq '4') { Write-Host '已退出。'; break }
    try {
      if ($mode -eq '1') {
        $t = (Read-Host '请输入目标群号后回车').Trim()
        if (-not $t) { Write-Host '群号不能为空。'; continue }
        Invoke-ScanAllGroups -TargetId $t
      } elseif ($mode -eq '2') {
        $q = (Read-Host '请输入要查的 QQ 号（多个用逗号或顿号分隔）后回车').Trim()
        if (-not $q) { Write-Host 'QQ号不能为空。'; continue }
        Invoke-FindQq -QqList @($q)
      } elseif ($mode -eq '3') {
        $n = (Read-Host '显示前多少名？（直接回车 = 20）').Trim()
        if ($n -notmatch '^\d+$') { $n = 20 }
        Invoke-RankTop -Top ([int]$n)
      } else {
        Write-Host '输入无效。'
        continue
      }
    } catch {
      Write-Host ''
      Write-Host "出错: $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host '（已回到菜单，可继续查询；输入 4 退出）'
  }
}

if ($FindQq) {
  Invoke-FindQq -QqList @($FindQq)
} elseif ($Rank) {
  Invoke-RankTop -Top $RankTop
} elseif ($All) {
  if (-not $Target) {
    Write-Host '用法: .\qq_group_duplicate_check.ps1 -All -Target <目标群号>'
    exit 1
  }
  Invoke-ScanAllGroups -TargetId $Target
} else {
  Start-Interactive
}