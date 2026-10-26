param(
    [switch]$SelfTest,
    [switch]$IntegrationTest,
    [ValidateSet('text','edit')][string]$TestMode = 'text',
    [string]$TestModel = 'qwen21',
    [ValidateRange(1,2147483647)][int]$TestCount = 1,
    [string]$ScreenshotPath,
    [switch]$TestAssistant,
    [switch]$TestDrawer,
    [switch]$TestPaste,
    [string]$AppDirectory = ''
)
# ---- 便携化：未指定工作台目录时，从脚本所在位置自动推断 ----
# 支持的放置方式：脚本在 QwenImageApp 内、脚本在 ComfyUI 根目录、脚本在根目录上一级。
if (-not $AppDirectory) {
    foreach ($candidate in @(
        $PSScriptRoot,
        (Join-Path $PSScriptRoot 'QwenImageApp'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'QwenImageApp')
    )) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'qwen_worker.py'))) { $AppDirectory = $candidate; break }
    }
}
if (-not $AppDirectory -or -not (Test-Path -LiteralPath (Join-Path $AppDirectory 'qwen_worker.py'))) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show("找不到工作台文件（qwen_worker.py）。`n请先运行「一键安装.ps1」，或用 -AppDirectory 指定 QwenImageApp 目录。", '本地生图工作台') | Out-Null
    } catch { }
    exit 1
}
$AppDirectory = (Resolve-Path -LiteralPath $AppDirectory).Path
$ErrorActionPreference = 'Stop'
# ---- 兼容修复：清理大小写重复的环境变量 ----
# 症状：环境里同时存在 HTTP_PROXY 和 http_proxy（或 NO_PROXY/no_proxy）时，
# PowerShell 5.1 的 Start-Process 带 -RedirectStandardOutput 内部用区分大小写的字典，
# 会抛 "Item has already been added. Key in dictionary: 'NO_PROXY'"，导致生成/队列任务无法启动。
# 注意：GetEnvironmentVariables() 大小写不敏感、查不出这种重复，必须用 cmd set 读原始环境。
try {
    $seenEnv = @{}
    foreach ($line in @(& cmd.exe /c set 2>$null)) {
        if ($line -match '^([^=]+)=(.*)$') {
            $envName = $matches[1]
            $envKey = $envName.ToLowerInvariant()
            if ($seenEnv.ContainsKey($envKey)) {
                [System.Environment]::SetEnvironmentVariable($envName, $null)
            } else { $seenEnv[$envKey] = $envName }
        }
    }
} catch { }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$portable = Split-Path $AppDirectory -Parent
$python = Join-Path $portable 'python_embeded\python.exe'
$workerFile = Join-Path $AppDirectory 'qwen_worker.py'
$settingsFile = Join-Path $AppDirectory 'settings.json'
$script:worker = $null
# shortcut: queue is session-only; persist and reconnect workers if restart recovery is requested.
$script:queueItems=New-Object 'System.Collections.Generic.List[object]'
$script:queuePaused=$false
$script:currentQueueTask=$null
$script:queueSequence=0
$script:lastFile = $null
$script:resultFiles=@()
$script:resultIndex=-1
$script:manualGalleryBrowse=$false
$script:galleryCache=@{}
$script:seenGeneratedFiles=@{}
$script:previewingReference=$false
$script:job = $null
$script:started = $null
$script:referenceFiles = @()
$script:characterAppliedTexts=@{}
$script:textCount = 1
$script:assistantModelsLoaded=$false
$models = Get-Content -LiteralPath (Join-Path $AppDirectory 'models.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$form = New-Object System.Windows.Forms.Form
$form.Text = '本地生图工作台'
$form.Icon = New-Object System.Drawing.Icon((Join-Path $AppDirectory 'qwen_image_white.ico'))
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$startupWidth = [Math]::Min(1220, $workArea.Width - 20)
$startupHeight = [Math]::Min(940, $workArea.Height - 20)
$form.Size = New-Object System.Drawing.Size($startupWidth, $startupHeight)
$form.MinimumSize = New-Object System.Drawing.Size(960, 720)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',10)
$form.BackColor = [System.Drawing.Color]::White
$form.AutoScaleMode = 'Dpi'

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 76; $header.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F2F6FC')
$form.Controls.Add($header)
$title = New-Object System.Windows.Forms.Label
$title.Text = '本地生图工作台'; $title.Location = New-Object System.Drawing.Point(24,12); $title.AutoSize = $true
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',17,[System.Drawing.FontStyle]::Bold)
$header.Controls.Add($title)
$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '文字生成图片 · 参考图编辑 · 本地保存'; $subtitle.Location = New-Object System.Drawing.Point(27,48); $subtitle.AutoSize = $true
$subtitle.ForeColor = [System.Drawing.Color]::DimGray; $header.Controls.Add($subtitle)
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '重启工作台'
$btnRefresh.Location = New-Object System.Drawing.Point(250, 34)
$btnRefresh.Size = New-Object System.Drawing.Size(118, 28)
$btnRefresh.Anchor = 'Top,Left'
$header.Controls.Add($btnRefresh)
$btnRefresh.Add_Click({
    if ($script:worker -or $script:assistantBusy) { return }
    try {
        Save-Settings
        Start-Process 'powershell.exe' -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + $PSCommandPath + '" -AppDirectory "' + $AppDirectory + '"') -ErrorAction Stop
        $form.Close()
    } catch { $statusLabel.Text = '重新打开失败：' + $_.Exception.Message }
})
$characterLibraryFile = Join-Path $AppDirectory '素材库_角色.json'
$favoriteLibraryFile = Join-Path $AppDirectory '素材库_收藏.json'
$promptLibraryFile = Join-Path $AppDirectory '素材库_提示词.json'
$ldgPromptLib = New-Object System.Windows.Forms.Button
$ldgPromptLib.Text = '提示词库'
$ldgPromptLib.Location = New-Object System.Drawing.Point(188, 34)
$ldgPromptLib.Size = New-Object System.Drawing.Size(92, 28)
$ldgPromptLib.Anchor = 'Top,Left'
$ldgCharacter = New-Object System.Windows.Forms.Button
$ldgCharacter.Text = '选择角色'
$ldgCharacter.Location = New-Object System.Drawing.Point(380, 34)
$ldgCharacter.Size = New-Object System.Drawing.Size(92, 28)
$ldgCharacter.Anchor = 'Top,Left'

function Test-PromptFragment([string]$text,[string]$value) {
    if (-not $value) { return $false }
    return [regex]::IsMatch($text,'(?m)(?:^|,|\r?\n)[ \t]*'+[regex]::Escape($value)+'[ \t]*(?=,|\r?$)')
}
function Set-CharacterSelection([string[]]$names) {
    $names=@($names | Where-Object { $_ } | Select-Object -Unique)
    $text=$fixedPrompt.Text
    foreach ($old in @($script:characterAppliedTexts.Keys)) {
        if ($old -in $names) { continue }
        $appliedText=[string]$script:characterAppliedTexts[$old]
        if (-not (Test-PromptFragment $text $appliedText)) { $appliedText=$old }
        while ($appliedText -and (Test-PromptFragment $text $appliedText)) {
            $updated=Remove-FixedPresetText $text $appliedText
            if ($updated -eq $text) { break }
            $text=$updated
        }
        $script:characterAppliedTexts.Remove($old)
    }
    foreach ($name in $names) {
        $desc=''
        $row=@($script:dlgLibRows | Where-Object { $_.En -eq $name })[0]
        if ($row -and $row.Desc) { $desc=[string]$row.Desc }
        $full=$(if ($desc) { $name + ', ' + $desc } else { $name })
        if (-not (Test-PromptFragment $text $name)) { $text=(@($text.Trim(" `r`n,"),$full) | Where-Object { $_ }) -join "`r`n" }
        $script:characterAppliedTexts[$name]=$(if (Test-PromptFragment $text $full) { $full } else { $name })
    }
    $fixedPrompt.Text=$text.Trim(" `r`n,")
    if ($script:autoSaveReady) { Queue-SettingsSave }
}

function Show-CharacterLibrary {
    if (-not (Test-Path -LiteralPath $script:characterLibraryFile)) {
        [System.Windows.Forms.MessageBox]::Show('素材库缺失：' + $script:characterLibraryFile, '素材库')
        return
    }
    try {
        $lib = Get-Content -LiteralPath $script:characterLibraryFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        [System.Windows.Forms.MessageBox]::Show('素材库读取失败：' + $_.Exception.Message, '素材库')
        return
    }
    $script:dlgLibRows = New-Object System.Collections.Generic.List[object]
    $script:dlgFavFile = $favoriteLibraryFile
    $script:dlgFavMap = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    if (Test-Path -LiteralPath $favoriteLibraryFile) {
        try {
            $favData = Get-Content -LiteralPath $favoriteLibraryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $favNode = $favData.favorites
            if ($favNode -is [System.Management.Automation.PSCustomObject]) {
                foreach ($p in $favNode.PSObject.Properties) {
                    $lv = [int]$p.Value
                    if ($lv -ge 1) { $script:dlgFavMap[[string]$p.Name] = [Math]::Min(3, $lv) }
                }
            } elseif ($favNode) {
                foreach ($f in @($favNode)) { if ($f) { $script:dlgFavMap[[string]$f] = 1 } }
            }
        } catch { }
    }
    $script:dlgGenderOrder = @{ '女生' = 0; '男生' = 1 }
    foreach ($g in @(@('女生',$lib.female), @('男生',$lib.male))) {
        foreach ($prop in $g[1].PSObject.Properties) {
            foreach ($item in $prop.Value) {
                $lv = 0
                if ($script:dlgFavMap.ContainsKey([string]$item.en)) { $lv = $script:dlgFavMap[[string]$item.en] }
                $script:dlgLibRows.Add([pscustomobject]@{ Gender=$g[0]; Work=$prop.Name; Cn=$item.cn; Label=($item.cn + '  |  ' + $item.en); En=$item.en; Desc=[string]$item.desc; Stars=$lv })
            }
        }
    }
    $reorder = {
        $sorted = @($script:dlgLibRows | Sort-Object @{Expression={ $script:dlgGenderOrder[$_.Gender] }}, @{Expression={ - [int]$_.Stars }}, @{Expression={ $_.En }})
        $script:dlgLibRows = New-Object System.Collections.Generic.List[object]
        foreach ($r in $sorted) { $script:dlgLibRows.Add($r) }
    }
    & $reorder
    $script:dlgCharacterChecked=@{}
    $script:characterAppliedTexts=@{}
    foreach ($row in $script:dlgLibRows) {
        $full = $(if ($row.Desc) { $row.En + ', ' + $row.Desc } else { $row.En })
        if (Test-PromptFragment $fixedPrompt.Text $row.En) {
            $script:dlgCharacterChecked[$row.En]=$true
            $script:characterAppliedTexts[$row.En]=$(if (Test-PromptFragment $fixedPrompt.Text $full) { $full } else { $row.En })
        }
    }
    $script:dlgCharacterRebuilding=$false
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '素材库 · 角色（' + $script:dlgLibRows.Count + ' 条）'
    $dlg.Size = New-Object System.Drawing.Size(700, 580)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $gender = New-Object System.Windows.Forms.ComboBox
    $gender.Location = New-Object System.Drawing.Point(12, 10); $gender.Width = 90
    $gender.DropDownStyle = 'DropDownList'
    $gender.Items.AddRange(@('全部', '女生', '男生')); $gender.SelectedIndex = 0
    $dlg.Controls.Add($gender)
    $work = New-Object System.Windows.Forms.ComboBox
    $work.Location = New-Object System.Drawing.Point(110, 10); $work.Width = 200
    $work.DropDownStyle = 'DropDownList'
    $null=$work.Items.Add('全部作品')
    foreach ($prop in $lib.male.PSObject.Properties) { $null = $work.Items.Add($prop.Name) }
    $work.SelectedIndex = 0
    $dlg.Controls.Add($work)
    $bodyType = New-Object System.Windows.Forms.ComboBox
    $bodyType.Location = New-Object System.Drawing.Point(318, 10); $bodyType.Width = 100
    $bodyType.DropDownStyle = 'DropDownList'
    $bodyType.Items.AddRange(@('全部体型', '成女')); $bodyType.SelectedIndex = 0
    $dlg.Controls.Add($bodyType)
    $search = New-Object System.Windows.Forms.TextBox
    $search.Location = New-Object System.Drawing.Point(428, 10); $search.Width = 200
    $dlg.Controls.Add($search)
    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(12, 42); $list.Size = New-Object System.Drawing.Size(660, 440)
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $true; $list.CheckBoxes=$true
    $list.HideSelection = $false
    $list.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    [void]$list.Columns.Add('选择 / 收藏', 96)
    [void]$list.Columns.Add('中文名', 180)
    [void]$list.Columns.Add('英文名', 300)
    [void]$list.Columns.Add('性别', 55)
    $dlg.Controls.Add($list)
    $tip.SetToolTip($list,"左键点击勾选或取消角色；右键循环切换 0～3 星收藏。`n空格勾选，Ctrl+空格切换星级。Ctrl+C 复制英文名，Ctrl+Shift+C 复制中文名。`n✎ 表示角色包含详细描述。")
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '完成'; $ok.Location = New-Object System.Drawing.Point(12, 494); $ok.Width = 110
    $dlg.Controls.Add($ok)
    $favBtn = New-Object System.Windows.Forms.Button
    $favBtn.Text = '★ 切换星级'; $favBtn.Location = New-Object System.Drawing.Point(132, 494); $favBtn.Width = 120
    $dlg.Controls.Add($favBtn)
    $favBtn.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $picked = $list.SelectedItems[0].Tag
        if (-not $picked) { return }
        $topEn = ''
        $topIdx = 0
        if ($list.TopItem -and $list.TopItem.Tag) { $topEn = [string]$list.TopItem.Tag.En; $topIdx = $list.TopItem.Index }
        $cur = [int]$picked.Stars
        $next = ($cur + 1) % 4
        if ($next -eq 0) {
            [void]$script:dlgFavMap.Remove([string]$picked.En)
            $picked.Stars = 0
            $hint.Text = '已取消收藏：' + $picked.Cn
        } else {
            $script:dlgFavMap[[string]$picked.En] = $next
            $picked.Stars = $next
            $hint.Text = '已设为 ' + ('★' * $next) + '：' + $picked.Cn + '（' + $picked.Gender + '组置顶）'
        }
        try {
            $favObj = [ordered]@{ favorites = [ordered]@{} }
            foreach ($key in @($script:dlgFavMap.Keys | Sort-Object)) { $favObj.favorites[$key] = $script:dlgFavMap[$key] }
            ($favObj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:dlgFavFile -Encoding UTF8
        } catch { }
        & $reorder
        & $filter
        # 恢复滚动位置：以操作前的顶部行为锚点，避免视图跳回最顶
        $anchor = $null
        if ($topEn) { foreach ($item in $list.Items) { if ($item.Tag -and [string]$item.Tag.En -eq $topEn) { $anchor = $item; break } } }
        if ($anchor) {
            try { $list.TopItem = $anchor } catch { try { $anchor.EnsureVisible() } catch { } }
        } elseif ($topIdx -gt 0 -and $list.Items.Count -gt $topIdx) {
            try { $list.TopItem = $list.Items[$topIdx] } catch { }
        }
        # 选中刚才操作的行，但不再强制滚动
        foreach ($item in $list.Items) {
            if ($item.Tag -and $item.Tag.En -eq $picked.En) { $item.Selected = $true; break }
        }
    })
    $list.Add_ItemCheck({
        param($sender,$eventArgs)
        if ($script:dlgCharacterRebuilding) { return }
        $row=$sender.Items[$eventArgs.Index].Tag
        if (-not $row) { return }
        if ($eventArgs.NewValue -eq [Windows.Forms.CheckState]::Checked) { $script:dlgCharacterChecked[$row.En]=$true }
        else { $script:dlgCharacterChecked.Remove($row.En) }
        Set-CharacterSelection @($script:dlgCharacterChecked.Keys)
        $hint.Text='已选 '+$script:dlgCharacterChecked.Count+' 个角色 · 勾选即时生效'
    })
    $list.Add_KeyDown({
        param($sender,$e)
        if ($e.Control -and $e.KeyCode -eq [Windows.Forms.Keys]::C -and $sender.SelectedItems.Count) {
            $e.Handled=$true; $e.SuppressKeyPress=$true
            $row=$sender.SelectedItems[0].Tag
            $text=$(if($e.Shift){[string]$row.Cn}else{[string]$row.En})
            try { [Windows.Forms.Clipboard]::SetText($text); $hint.Text='已复制：'+$text } catch { $hint.Text='复制失败（剪贴板被占用）' }
        } elseif ($e.KeyCode -eq [Windows.Forms.Keys]::Space) {
            $e.Handled=$true; $e.SuppressKeyPress=$true
            if ($e.Control) { $favBtn.PerformClick() }
            else { foreach ($item in @($list.SelectedItems)) { $item.Checked=-not $item.Checked } }
        }
    })
    $list.Add_MouseUp({
        param($sender,$e)
        $hit=$sender.HitTest($e.X,$e.Y)
        if (-not $hit.Item) { return }
        if ($e.Button -eq [Windows.Forms.MouseButtons]::Right) {
            foreach ($item in @($sender.SelectedItems)) { $item.Selected=$false }
            $hit.Item.Selected=$true; $hit.Item.Focused=$true
            $favBtn.PerformClick()
        } elseif ($e.Button -eq [Windows.Forms.MouseButtons]::Left -and -not ($hit.Location -band [Windows.Forms.ListViewHitTestLocations]::StateImage)) {
            # Native checkbox clicks already toggle on mouse-down; toggle only the rest of the row.
            $hit.Item.Checked=-not $hit.Item.Checked
        }
    })
    $hint = New-Object System.Windows.Forms.Label
    $hint.Location = New-Object System.Drawing.Point(270, 498); $hint.AutoSize = $true
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($hint)
    $filter = {
        $g = [string]$gender.SelectedItem
        $w = [string]$work.SelectedItem
        $bt = [string]$bodyType.SelectedItem
        $q = $search.Text.Trim()
        $script:dlgCharacterRebuilding=$true
        $list.BeginUpdate()
        try {
        $list.Items.Clear()
        $shown = 0
        foreach ($row in $script:dlgLibRows) {
            if ($g -ne '全部' -and $row.Gender -ne $g) { continue }
            if ($w -ne '全部作品' -and $row.Work -ne $w) { continue }
            if ($bt -eq '成女') {
                $d = [string]$row.Desc
                if (-not ($d -match 'mature.female')) { continue }
            }
            if ($q -and ($row.Cn -notlike ('*' + $q + '*')) -and ($row.En -notlike ('*' + $q + '*')) -and ($row.Work -notlike ('*' + $q + '*'))) { continue }
            $item = New-Object System.Windows.Forms.ListViewItem($(if ([int]$row.Stars -gt 0) { ('★' * [int]$row.Stars) } else { '' }))
            [void]$item.SubItems.Add($(if ($row.Desc) { [string]$row.Cn + ' ✎' } else { [string]$row.Cn }))
            [void]$item.SubItems.Add([string]$row.En)
            [void]$item.SubItems.Add([string]$row.Gender)
            $item.Tag = $row
            [void]$list.Items.Add($item)
            $item.Checked=$script:dlgCharacterChecked.ContainsKey([string]$row.En)
            $shown++
        }
        } finally { $list.EndUpdate(); $script:dlgCharacterRebuilding=$false }
        $hint.Text='显示 '+$shown+' · 已选 '+$script:dlgCharacterChecked.Count+' · 左键选用 / 右键星级'
    }
    $gender.Add_SelectedIndexChanged({ & $filter })
    $work.Add_SelectedIndexChanged({ & $filter })
    $bodyType.Add_SelectedIndexChanged({ & $filter })
    $search.Add_TextChanged({ & $filter })
    & $filter
    $ok.Add_Click({ $dlg.Close() })
    $dlg.AcceptButton=$ok
    try { $null=$dlg.ShowDialog($form) } finally { $dlg.Dispose() }
}
$ldgCharacter.Add_Click({ Show-CharacterLibrary })
function Show-PromptLibrary {
    if (-not (Test-Path -LiteralPath $script:promptLibraryFile)) {
        [System.Windows.Forms.MessageBox]::Show('提示词库缺失：' + $script:promptLibraryFile, '提示词库')
        return
    }
    try {
        $lib = Get-Content -LiteralPath $script:promptLibraryFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        [System.Windows.Forms.MessageBox]::Show('提示词库读取失败：' + $_.Exception.Message, '提示词库')
        return
    }
    $script:promptRows = New-Object System.Collections.Generic.List[object]
    foreach ($prop in $lib.groups.PSObject.Properties) {
        foreach ($item in @($prop.Value)) {
            $script:promptRows.Add([pscustomobject]@{ Group=$prop.Name; Id=[string]$item.id; Text=[string]$item.text })
        }
    }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '提示词库（' + $script:promptRows.Count + ' 条）'
    $dlg.Size = New-Object System.Drawing.Size(900, 600)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $grp = New-Object System.Windows.Forms.ComboBox
    $grp.Location = New-Object System.Drawing.Point(12, 10); $grp.Width = 160
    $grp.DropDownStyle = 'DropDownList'
    $null = $grp.Items.Add('全部分类')
    foreach ($prop in $lib.groups.PSObject.Properties) { $null = $grp.Items.Add($prop.Name) }
    $grp.SelectedIndex = 0
    $dlg.Controls.Add($grp)
    $search = New-Object System.Windows.Forms.TextBox
    $search.Location = New-Object System.Drawing.Point(182, 10); $search.Width = 300
    $dlg.Controls.Add($search)
    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(12, 42); $list.Size = New-Object System.Drawing.Size(860, 460)
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.CheckBoxes = $true
    $list.MultiSelect = $true
    $list.HideSelection = $false
    $list.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    [void]$list.Columns.Add('编号', 60)
    [void]$list.Columns.Add('分类', 130)
    [void]$list.Columns.Add('提示词', 640)
    $dlg.Controls.Add($list)
    $hint = New-Object System.Windows.Forms.Label
    $hint.Location = New-Object System.Drawing.Point(12, 512); $hint.AutoSize = $true
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($hint)
    $clearBtn = New-Object System.Windows.Forms.Button
    $clearBtn.Text = '清空'; $clearBtn.Location = New-Object System.Drawing.Point(700, 506); $clearBtn.Width = 90
    $dlg.Controls.Add($clearBtn)
    $close = New-Object System.Windows.Forms.Button
    $close.Text = '关闭'; $close.Location = New-Object System.Drawing.Point(806, 506); $close.Width = 66
    $close.DialogResult = 'OK'
    $dlg.Controls.Add($close)
    $script:promptLibRebuilding = $false
    $filterP = {
        $g = [string]$grp.SelectedItem
        $q = $search.Text.Trim()
        $existing = @(Get-PromptSegments $prompt.Text)
        $script:promptLibRebuilding = $true
        $list.BeginUpdate()
        try {
            $list.Items.Clear()
            foreach ($row in $script:promptRows) {
                if ($g -ne '全部分类' -and $row.Group -ne $g) { continue }
                if ($q -and $row.Text -notlike ('*'+$q+'*') -and $row.Id -notlike ('*'+$q+'*')) { continue }
                $item = New-Object System.Windows.Forms.ListViewItem([string]$row.Id)
                [void]$item.SubItems.Add([string]$row.Group)
                [void]$item.SubItems.Add([string]$row.Text)
                $item.Tag = $row
                $item.Checked = ($existing -contains [string]$row.Text)
                [void]$list.Items.Add($item)
            }
        } finally { $list.EndUpdate(); $script:promptLibRebuilding = $false }
        $hint.Text = '共 ' + $list.Items.Count + ' 条 · 勾选加入提示词（多条之间自动空两行，等于多张图各用一段）'
    }
    $grp.Add_SelectedIndexChanged({ & $filterP })
    $search.Add_TextChanged({ & $filterP })
    $list.Add_ItemCheck({
        param($sender,$eventArgs)
        if ($script:promptLibRebuilding) { return }
        $row = $sender.Items[$eventArgs.Index].Tag
        if (-not $row) { return }
        $text = [string]$row.Text
        $cur = @(Get-PromptSegments $prompt.Text)
        if ($eventArgs.NewValue -eq [Windows.Forms.CheckState]::Checked) {
            if ($cur -notcontains $text) { $cur += $text }
        } else {
            $cur = @($cur | Where-Object { $_ -ne $text })
        }
        $prompt.Text = ($cur -join "`r`n`r`n")
        if ($script:autoSaveReady) { Queue-SettingsSave }
    })
    $clearBtn.Add_Click({
        $prompt.Text = ''
        $script:promptLibRebuilding = $true
        try { foreach ($item in $list.Items) { $item.Checked = $false } } finally { $script:promptLibRebuilding = $false }
        if ($script:autoSaveReady) { Queue-SettingsSave }
        $hint.Text = '已清空提示词栏与全部勾选'
    })
    & $filterP
    try { $null = $dlg.ShowDialog($form) } finally { $dlg.Dispose() }
}
$ldgPromptLib.Add_Click({ Show-PromptLibrary })
$modelLabel = New-Object System.Windows.Forms.Label
$modelLabel.Text = '选择模型'; $modelLabel.Location = New-Object System.Drawing.Point(700,8)
$modelLabel.AutoSize = $true; $modelLabel.Anchor = 'Top,Right'; $header.Controls.Add($modelLabel)
$model = New-Object System.Windows.Forms.ComboBox
$model.Location = New-Object System.Drawing.Point(700,34); $model.Width = 450
$model.DropDownStyle = 'DropDownList'; $model.DisplayMember = 'name'; $model.Anchor = 'Top,Right'
foreach ($entry in $models) { $null = $model.Items.Add($entry) }
$header.Controls.Add($model)
function Set-HeaderFooterLayout {
    $w = $form.ClientSize.Width
    $modelX = $body.Left + $right.Left
    $modelLabel.Location = New-Object System.Drawing.Point($modelX,8)
    $model.Location = New-Object System.Drawing.Point($modelX,34)
    $model.Width = [Math]::Floor([Math]::Max(200,$right.ClientSize.Width-$right.Padding.Right)/2)
    $btnRefresh.Location = New-Object Drawing.Point(($model.Right+30),$model.Top)
    $btnRefresh.Height = $model.Height
    if ($statusLabel) {
        foreach ($control in @($statusLabel,$progress,$elapsed)) { $control.Width=[Math]::Max(100,$w-354) }
    }
}

$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Bottom'; $footer.Height = 132; $footer.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F2F6FC')
$form.Controls.Add($footer)
$body = New-Object System.Windows.Forms.Panel
$body.Dock = 'Fill'; $form.Controls.Add($body); $body.BringToFront()
$left = New-Object System.Windows.Forms.Panel
$left.Dock = 'Left'; $left.Width = 520; $left.AutoScroll = $true; $body.Controls.Add($left)
$inputs = New-Object System.Windows.Forms.Panel
$inputs.Location = New-Object System.Drawing.Point(24,12); $inputs.Size = New-Object System.Drawing.Size(465,730)
$left.Controls.Add($inputs)
$right = New-Object System.Windows.Forms.Panel
$right.Dock = 'Fill'; $right.Padding = New-Object System.Windows.Forms.Padding(16,0,24,14); $body.Controls.Add($right); $right.BringToFront()

# ================= 右侧：提示词助手（与工作台合并） =================

$SystemDirectionText = @'
你是中文生图提示词扩写助手，当前是【文生图】模式。用户会给你一个粗略的提示词（可能只有一句话或几个词），你要把它的原意扩展得更详细、更具体，而不是改写或替换他的想法。

规则：
1. 全部用中文回答，简洁，总长度不超过 350 字。
2. 先准确理解用户想画的主体、动作、场景和意图。扩写只做补充和细化，绝不改变用户原本的意思。
3. 给出 2～3 个扩写方向，每个方向写成三行：
   「方向N：一句话名称」
   「扩写重点：列出要补充哪些维度（主体细节、服装、动作、表情、环境、光线、色彩、构图、镜头、画质）」
   「适合：说明这个方向适合什么用途（写实摄影、电影感、插画、强调某个细节）」
4. 最后单独一行：推荐：方向N（一句话理由）
5. 只输出方向，不要输出扩写后的提示词正文。
'@.Trim()

$SystemFinalText = @'
你是生图提示词扩写写手，当前是【文生图】模式。根据用户的粗略提示词和已确认的扩写方向，写一条详细、完整、可直接用于文生图的提示词。

要求：
1. 忠实保留用户原本想表达的主体、动作、场景和意图，只做补充和细化，不改变内容、不删减、不替用户换方向。
2. 从这些维度补充细节：主体外观与服装、动作与姿态、表情、环境与背景、光线与时间、色彩、构图与视角、镜头与画质。
3. 用自然、具体、可执行的中文，长度 120～260 字。
4. 不要添加与用户意图冲突的新元素；用户没提到的内容可以合理补全，但不能喧宾夺主。
5. 直接用一段话输出扩写后的提示词正文，不要解释、不要分点、不要加引号或标题。
'@.Trim()

$SystemDirectionEdit = @'
你是中文生图提示词助手，当前是【图生图 / 图片编辑】模式。用户已经有一张参考图，会给你一个粗略的修改要求，你要把它扩展成清晰、可执行的编辑提示词方向，同时明确哪些部分必须保持不变。

规则：
1. 全部用中文回答，简洁，总长度不超过 350 字。
2. 先理解要改什么、改成什么样、哪些必须保留。
3. 给出 2～3 个编辑方向，每个方向写成三行：
   「方向N：一句话名称」
   「改法：把修改要求写成最终画面（改哪里、改成什么样、改后什么效果）」
   「保留：列出必须保持不变的部分（面部、发型、身材、姿势、背景、镜头角度等）」
4. 最后单独一行：推荐：方向N（一句话理由）
5. 只输出方向，不要输出最终提示词正文。
'@.Trim()

$SystemFinalEdit = @'
你是图生图编辑提示词写手。根据用户的粗略修改要求和已确认的编辑方向，写一条最终编辑提示词。

要求：
1. 只描述用户要改的部分（改成什么样），并明确写出保持不变的部分。
2. 必须包含"面部、发型、身材、姿势、背景和镜头角度保持不变"这类约束（按用户实际需要保留的部分来写）。
3. 用自然、具体、可执行的中文，长度 60～150 字。
4. 不要添加与修改要求冲突的新元素，不要虚构原图里没有的内容。
5. 直接用一段话输出提示词正文，不要解释、不要分点、不要加引号或标题。
'@.Trim()

$SystemDirectionFeature = @'
你是中文生图提示词助手，当前是【图生图 · 特征参考】模式。用户有一张参考图，想参考其中的某些特征（人物长相、发型、服装风格、画风等）生成一张新图，新图的构图、姿势和场景可以重新设计。

规则：
1. 全部用中文回答，简洁，总长度不超过 350 字。
2. 先理解用户想保留参考图的哪些特征，以及想生成的新场景、新动作、新构图。
3. 给出 2～3 个方向，每个方向写成三行：
   「方向N：一句话名称」
   「保留特征：列出参考图里要保留的特征（脸、发型、服装、画风等）」
   「新画面：描述新图的场景、动作、构图、光线」
4. 最后单独一行：推荐：方向N（一句话理由）
5. 只输出方向，不要输出最终提示词正文。
'@.Trim()

$SystemFinalFeature = @'
你是生图提示词写手，当前是【图生图 · 特征参考】模式。根据用户想法和已确认的方向，写一条完整提示词，用于参考原图特征生成一张新图。

要求：
1. 描述最终新画面的全部内容：主体外观（沿用参考图的特征）、服装、动作、场景、光线、构图、镜头。
2. 新图的姿势、构图和场景可以完全重新设计，不要写"保持原图不变"或"保持不变"。
3. 保留用户明确想保留的特征（例如某个人物的长相、发型、服装风格），其余可以自由发挥。
4. 用自然、具体、可执行的中文，长度 80～180 字。
5. 直接用一段话输出提示词正文，不要解释、不要分点、不要加引号或标题。
'@.Trim()

$SystemDirectionStoryboard = @'
你是中文分镜提示词助手，当前是【文生图 · 分镜】模式。用户会给你一个粗略想法（可能包含角色、画面、格数），你要把它扩展成适合生图模型的分镜方案。

规则：
1. 全部用中文回答，简洁，总长度不超过 400 字。
2. 先理解：要几格分镜、每格画什么、角色外观和服装设定、整体画风。
3. 给出 2～3 个分镜方向，每个方向写成三行：
   「方向N：一句话名称」
   「布局：格数、排列方式（左右/上下/整页）、每格取景范围（半身/全身）、视角、画风」
   「重点：每格要表现的关键动作或情绪，以及角色和服装的要点」
4. 最后单独一行：推荐：方向N（一句话理由）
5. 只输出方向，不要输出完整分镜提示词。
'@.Trim()

$SystemFinalStoryboard = @'
你是分镜提示词写手，当前是【文生图 · 分镜】模式。根据用户想法和已确认的分镜方向，写一条完整的结构化分镜提示词，供生图模型使用。

必须按以下结构输出，段落标题原样保留：

【布局与画风】
说明格数、排列方式、分隔方式、每格取景范围、视角、画风（线条、上色、阴影方式）、背景处理，以及禁止出现的元素（文字、编号、对白、额外分镜等）。

【画面一：一句话标题】
服装：该格角色的完整服装描述。
姿态与动作：人物姿势、手部动作、表情、桌面或环境中的物品。

【画面二：一句话标题】
服装：……
姿态与动作：……

（按用户要求增减画面格数，每格都必须有服装和姿态与动作两段）

【肢体与空间要求】
说明每格角色数量、每人恰好两条手臂两只手、左右手分工、肩肘腕连接、手指数量、避免多余肢体或穿模。

【发型与角色外观】
发色、发型细节、脸型、眼睛、眉毛、鼻子嘴唇、肤色、配饰。

【服设】
汇总各格服装要点，与画面中的描述保持一致。

规则：
1. 基于用户想法扩展；角色设定和服装可以根据用户描述合理补全，前后保持一致。
2. 全部用中文，长度 600～1200 字。
3. 只输出提示词正文；除规定结构外不要额外解释。
4. 不写对白、标题文字、编号，不添加分镜格以外的画面。
'@.Trim()

function Get-OllamaModels {
    $script:ollamaLastError=$null
    try {
        $resp = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 6 -UseBasicParsing
        return @($resp.models | ForEach-Object { [string]$_.name } | Where-Object { $_ })
    } catch { $script:ollamaLastError=$_.Exception.Message; return @() }
}

function Invoke-ChatJob([string]$Model, [array]$Messages, [int]$MaxTokens) {
    if ($script:assistantBusy) { return @{error='已有助手请求正在进行。'} }
    $script:assistantBusy = $true
    $assistant.Enabled = $false; $btnRefresh.Enabled = $false; $generate.Enabled = $false
    try {
    $payload = [ordered]@{
        model = $Model; messages = $Messages; stream = $false
        options = @{ temperature = 0.7; top_p = 0.9; num_predict = $MaxTokens }
        keep_alive = '5m'
        think = $false
    }
    $json = $payload | ConvertTo-Json -Depth 10 -Compress
    $job = Start-Job -ScriptBlock {
        param($url, $body)
        $ErrorActionPreference = 'Stop'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $r = Invoke-WebRequest -Uri ($url + '/api/chat') -Method Post -Body $bytes -ContentType 'application/json' -UseBasicParsing -TimeoutSec 240
        [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    } -ArgumentList 'http://127.0.0.1:11434', $json
    $deadline = (Get-Date).AddSeconds(240)
    while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline -and -not $form.IsDisposed) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 120
    }
    $result = @{ text = $null; error = $null }
    try {
        if ($job.State -eq 'Completed') {
            $raw = [string](Receive-Job $job)
            $obj = $raw | ConvertFrom-Json
            if (-not $obj.message) { throw '模型没有返回内容。' }
            $content = [string]$obj.message.content
            if (-not $content.Trim()) {
                $thinking = [string]$obj.message.thinking
                if ($thinking.Trim()) { throw '当前模型是「先思考再作答」的类型，换 qwen2.5 或破甲版试试。' }
                throw '模型没有返回内容。'
            }
            $result.text = $content.Trim()
        } else {
            $reason = $job.ChildJobs[0].JobStateInfo.Reason
            $result.error = $(if ($reason) { $reason.Message } else { '请求超时或未完成。' })
        }
    } catch {
        $result.error = $_.Exception.Message
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    return $result
    } finally {
        $script:assistantBusy = $false
        if (-not $form.IsDisposed) {
            $assistant.Enabled = $true
            $btnRefresh.Enabled = -not [bool]$script:worker
            $generate.Enabled = -not [bool]$script:worker
            $asMode.Enabled = $true; $asFill.Enabled = $true
        }
    }
}

function Show-AssistantResult($result, [string]$Kind) {
    if ($result.error) {
        if ($result.error -match '404|not found|model') { $asStatus.Text = '这个模型不可用或还没下载完，换一个试试。' }
        else { $asStatus.Text = '出错了：' + $result.error }
        return
    }
    $asFinal.Text = $result.text
    $asStatus.Text = '详细提示词已生成。'
}

$assistant = New-Object System.Windows.Forms.Panel
$assistant.Dock='Fill'; $assistant.AutoScroll=$true
$assistant.BackColor=[System.Drawing.Color]::White

$asModelLabel = New-Object System.Windows.Forms.Label
$asModelLabel.Text = '文字模型'; $asModelLabel.Location = New-Object System.Drawing.Point(10, 14); $asModelLabel.AutoSize = $true
$assistant.Controls.Add($asModelLabel)
$asModel = New-Object System.Windows.Forms.ComboBox
$asModel.Location = New-Object System.Drawing.Point(66, 10); $asModel.Width = 150; $asModel.DropDownStyle = 'DropDownList'
$assistant.Controls.Add($asModel)
$asRefresh = New-Object System.Windows.Forms.Button
$asRefresh.Text = '刷新'; $asRefresh.Location = New-Object System.Drawing.Point(222, 9); $asRefresh.Size = New-Object System.Drawing.Size(44, 26)
$assistant.Controls.Add($asRefresh)
$asModeLabel = New-Object System.Windows.Forms.Label
$asModeLabel.Text = '模式'; $asModeLabel.Location = New-Object System.Drawing.Point(272, 14); $asModeLabel.AutoSize = $true
$assistant.Controls.Add($asModeLabel)
$asMode = New-Object System.Windows.Forms.ComboBox
$asMode.Location = New-Object System.Drawing.Point(304, 10); $asMode.Width = 100; $asMode.DropDownStyle = 'DropDownList'
$asMode.Items.AddRange(@('文生图', '文生图 · 分镜', '图生图 · 编辑', '图生图 · 特征参考')); $asMode.SelectedIndex = 0
$assistant.Controls.Add($asMode)
$asMode.Add_SelectedIndexChanged({
    # 助手模式反向同步工作台生成方式（只在不同时改，避免互相触发）
    $selectedAssistantMode = $asMode.SelectedIndex
    if ($selectedAssistantMode -ge 2) {
        if (-not (Test-ImageModel)) { $asMode.SelectedIndex=0; $asStatus.Text='当前模型仅支持文生图，请先切换生图模型。'; return }
        if ($mode.SelectedIndex -ne 1) { $mode.SelectedIndex = 1 }
        $refUsage.SelectedIndex = [int]($selectedAssistantMode -eq 3)
        if ($asMode.SelectedIndex -ne $selectedAssistantMode) { $asMode.SelectedIndex = $selectedAssistantMode }
    } else {
        if ($mode.SelectedIndex -ne 0) { $mode.SelectedIndex = 0 }
        $refUsage.SelectedIndex = 0
    }
})

$asCaption1 = New-Object System.Windows.Forms.Label
$asCaption1.Text = '① 你的粗略提示词（一句话或几个词）'
$asCaption1.Location = New-Object System.Drawing.Point(10, 44); $asCaption1.AutoSize = $true
$asCaption1.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$asCaption1.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#24405F')
$assistant.Controls.Add($asCaption1)
$asIdea = New-Object System.Windows.Forms.TextBox
$asIdea.Location = New-Object System.Drawing.Point(12, 68); $asIdea.Size = New-Object System.Drawing.Size(436, 108)
$asIdea.Multiline = $true; $asIdea.ScrollBars = 'Vertical'; $asIdea.AcceptsReturn = $true
$asIdea.Anchor = 'Top,Left,Right'
$assistant.Controls.Add($asIdea)

$asDirBtn = New-Object System.Windows.Forms.Button
$asDirBtn.Text = '生成详细提示词'; $asDirBtn.Location = New-Object System.Drawing.Point(12, 186); $asDirBtn.Size = New-Object System.Drawing.Size(150, 30)
$assistant.Controls.Add($asDirBtn)
$asStatus = New-Object System.Windows.Forms.Label
$asStatus.Text = '就绪'; $asStatus.Location = New-Object System.Drawing.Point(12, 222); $asStatus.AutoSize = $false; $asStatus.Size = New-Object System.Drawing.Size(420,36)
$asStatus.ForeColor = [System.Drawing.Color]::DimGray
$assistant.Controls.Add($asStatus)


$asCaption3 = New-Object System.Windows.Forms.Label
$asCaption3.Text = '② 详细提示词（可直接填入左侧工作台）'
$asCaption3.Location = New-Object System.Drawing.Point(10, 266); $asCaption3.AutoSize = $true
$asCaption3.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$asCaption3.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#24405F')
$assistant.Controls.Add($asCaption3)
$asFinal = New-Object System.Windows.Forms.TextBox
$asFinal.Location = New-Object System.Drawing.Point(12, 292); $asFinal.Size = New-Object System.Drawing.Size(436, 220)
$asFinal.Multiline = $true; $asFinal.ScrollBars = 'Vertical'; $asFinal.AcceptsReturn = $true
$asFinal.Anchor = 'Top,Left,Right'
$assistant.Controls.Add($asFinal)

$asCopy = New-Object System.Windows.Forms.Button
$asCopy.Text = '复制'; $asCopy.Location = New-Object System.Drawing.Point(12, 530); $asCopy.Size = New-Object System.Drawing.Size(56, 30)
$assistant.Controls.Add($asCopy)
$asRegenBtn = New-Object System.Windows.Forms.Button
$asRegenBtn.Text = '换一版'; $asRegenBtn.Location = New-Object System.Drawing.Point(170, 186); $asRegenBtn.Size = New-Object System.Drawing.Size(90, 30)
$assistant.Controls.Add($asRegenBtn)
$asFill = New-Object System.Windows.Forms.Button
$asFill.Text = '填入工作台'; $asFill.Location = New-Object System.Drawing.Point(72, 530); $asFill.Size = New-Object System.Drawing.Size(84, 30)
$assistant.Controls.Add($asFill)
$asSave = New-Object System.Windows.Forms.Button
$asSave.Text = '保存到文件'; $asSave.Location = New-Object System.Drawing.Point(160, 530); $asSave.Size = New-Object System.Drawing.Size(80, 30)
$assistant.Controls.Add($asSave)
$asClear = New-Object System.Windows.Forms.Button
$asClear.Text = '清空'; $asClear.Location = New-Object System.Drawing.Point(244, 530); $asClear.Size = New-Object System.Drawing.Size(52, 30)
$assistant.Controls.Add($asClear)
$asTranslate = New-Object System.Windows.Forms.Button
$asTranslate.Text = '翻译'; $asTranslate.Location = New-Object System.Drawing.Point(300, 530); $asTranslate.Size = New-Object System.Drawing.Size(82, 30)
$assistant.Controls.Add($asTranslate)
$asAnalyze = New-Object System.Windows.Forms.Button
$asAnalyze.Text = '解析图片'; $asAnalyze.Location = New-Object System.Drawing.Point(1348, 34); $asAnalyze.Size = New-Object System.Drawing.Size(88, 28)
$asAnalyze.Anchor = 'Top,Left'
$assistant.Controls.Add($asAnalyze)

function Refresh-AssistantModels {
    if ($script:assistantBusy) { return }
    $previous = [string]$asModel.SelectedItem
    $script:ollamaLastError=$null
    $names = @(Get-OllamaModels)
    $script:assistantModelsLoaded=$false
    if ($script:ollamaLastError) {
        $asStatus.Text = '暂时无法连接 Ollama；请确认它已启动，再点刷新或重新展开模型列表。'
        return
    }
    $asModel.Items.Clear()
    foreach ($name in $names) { [void]$asModel.Items.Add($name) }
    if ($names.Count -eq 0) { $asStatus.Text = '已连接 Ollama，但没有已安装的文字模型。'; return }
    $script:assistantModelsLoaded=$true
    $preferred = $names | Where-Object { $_ -like 'yi-9b-abliterated*' } | Select-Object -First 1
    if (-not $preferred) { $preferred = $names | Where-Object { $_ -like 'qwen2.5-14b-abliterated*' } | Select-Object -First 1 }
    if (-not $preferred) { $preferred = $names | Where-Object { $_ -like 'qwen2.5-abliterated*' } | Select-Object -First 1 }
    if (-not $preferred) { $preferred = $names | Where-Object { $_ -eq 'qwen2.5:7b' } | Select-Object -First 1 }
    if (-not $preferred) { $preferred = $names | Where-Object { $_ -like 'qwen2.5*' } | Select-Object -First 1 }
    if (-not $preferred) { $preferred = $names | Where-Object { $_ -like 'qwen3*' } | Select-Object -First 1 }
    if (-not $preferred) { $preferred = $names[0] }
    if ($names -contains $previous) { $preferred=$previous }
    $asModel.SelectedItem = $preferred
    $asStatus.Text = ('已连接文字模型，共 ' + $names.Count + ' 个。')
}

$asRefresh.Add_Click({ Refresh-AssistantModels })
$asModel.Add_DropDown({
    if (-not $script:assistantModelsLoaded -or $asModel.Items.Count -eq 0) { Refresh-AssistantModels }
})

function Invoke-AssistantGenerate {
    $idea = $asIdea.Text.Trim()
    $modeIndex = $asMode.SelectedIndex
    if (-not $idea) { $asStatus.Text = '先写一句粗略提示词。'; return }
    if (-not $asModel.SelectedItem) { $asStatus.Text = '还没有文字模型，点「刷新」。'; return }
    $tokens = 500
    switch ($modeIndex) {
        3 {
            $messages = @(
                @{ role = 'system'; content = $SystemFinalFeature },
                @{ role = 'user'; content = "参考图想保留的特征和新画面要求：`n$idea`n`n请给出最终提示词。" }
            )
            $asStatus.Text = '正在写特征参考提示词…'
        }
        2 {
            $messages = @(
                @{ role = 'system'; content = $SystemFinalEdit },
                @{ role = 'user'; content = "修改要求：`n$idea`n`n请给出最终编辑提示词。" }
            )
            $asStatus.Text = '正在写编辑提示词…'
        }
        1 {
            $messages = @(
                @{ role = 'system'; content = $SystemFinalStoryboard },
                @{ role = 'user'; content = "分镜想法：`n$idea`n`n请给出完整的分镜提示词。" }
            )
            $asStatus.Text = '正在写分镜提示词…'
            $tokens = 2200
        }
        default {
            $messages = @(
                @{ role = 'system'; content = $SystemFinalText },
                @{ role = 'user'; content = "我的粗略提示词：`n$idea`n`n请给出扩写后的详细提示词。" }
            )
            $asStatus.Text = '正在扩写提示词…'
        }
    }
    $result = Invoke-ChatJob ([string]$asModel.SelectedItem) $messages $tokens
    Show-AssistantResult $result 'final'
}
$asDirBtn.Add_Click({ Invoke-AssistantGenerate })
$asRegenBtn.Add_Click({ Invoke-AssistantGenerate })

$asCopy.Add_Click({
    if (-not $asFinal.Text.Trim()) { $asStatus.Text = '详细提示词还是空的。'; return }
    [System.Windows.Forms.Clipboard]::SetText($asFinal.Text.Trim())
    $asStatus.Text = '已复制到剪贴板。'
})

$asFill.Add_Click({
    $text = $asFinal.Text.Trim()
    if (-not $text) { $asStatus.Text = '详细提示词还是空的。'; return }
    $prompt.Text = $text
    $prompt.SelectionStart = $prompt.TextLength
    $prompt.ScrollToCaret()
    switch ($asMode.SelectedIndex) {
        2 { $mode.SelectedIndex = 1; $refUsage.SelectedIndex = 0; $modeText = '图生图 · 编辑' }
        3 { $mode.SelectedIndex = 1; $refUsage.SelectedIndex = 1; $modeText = '图生图 · 特征参考' }
        1 { $mode.SelectedIndex = 0; $refUsage.SelectedIndex = 0; $modeText = '文生图 · 分镜' }
        default { $mode.SelectedIndex = 0; $refUsage.SelectedIndex = 0; $modeText = '文生图' }
    }
    $tabs.SelectedTab=$creationPage
    $statusLabel.Text = '已从关键词助手填入（' + $modeText + ' 模式）。'
    [System.Windows.Forms.Clipboard]::SetText($text)
})

$asSave.Add_Click({
    $text = $asFinal.Text.Trim()
    if (-not $text) { $asStatus.Text = '详细提示词还是空的。'; return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = '文本文件 (*.txt)|*.txt'
    $dialog.FileName = '提示词.txt'
    if ($dialog.ShowDialog() -eq 'OK') {
        [System.IO.File]::WriteAllText($dialog.FileName, $text, (New-Object System.Text.UTF8Encoding($false)))
        $asStatus.Text = ('已保存：' + $dialog.FileName)
    }
})

$asClear.Add_Click({
    $asIdea.Clear(); $asFinal.Clear()
    $asStatus.Text = '已清空。'
})
function Get-TranslationTarget([string]$text) {
    $han=[regex]::Matches($text,'[\u3400-\u4DBF\u4E00-\u9FFF]').Count
    $english=[regex]::Matches($text,'[A-Za-z]+').Count
    if ($han -eq 0 -and $english -eq 0) { return $null }
    if ($han -gt 0 -and $han -ge $english) { return '英文' }
    return '中文'
}
$asTranslate.Add_Click({
    $text = $asFinal.Text.Trim()
    if (-not $text) { $text = $asIdea.Text.Trim() }
    if (-not $text) { $asStatus.Text = '先输入需要翻译的内容。'; return }
    $target=Get-TranslationTarget $text
    if (-not $target) { $asStatus.Text='没有检测到中文或英文，请输入需要翻译的文字。'; return }
    if (-not $asModel.SelectedItem) { $asStatus.Text = '还没有文字模型，点「刷新」。'; return }
    $messages = @(
        @{ role = 'system'; content = ('你是翻译器。将用户内容翻译成'+$target+'，只输出译文。保留原意、分段、标签、括号及权重写法，不增删画面内容，不添加解释、引号或编号。专有名称按通用译名处理。') },
        @{ role = 'user'; content = $text }
    )
    $asStatus.Text = '正在翻译成'+$target+'…'
    $result = Invoke-ChatJob ([string]$asModel.SelectedItem) $messages 800
    Show-AssistantResult $result 'final'
})

$asAnalyze.Add_Click({
    $img = $null
    $tmpImg = $null
    if ($preview.Image) {
        $tmpImg = Join-Path $env:TEMP ('dsh_analyze_' + [Guid]::NewGuid().ToString('N') + '.png')
        try { $preview.Image.Save($tmpImg, [System.Drawing.Imaging.ImageFormat]::Png); $img = $tmpImg } catch { $tmpImg = $null }
    }
    if (-not $img) {
        $img = $script:lastFile
        if (-not $img -or -not (Test-Path -LiteralPath $img -PathType Leaf)) { $asStatus.Text = '没有可解析的图片：先拖入/粘贴图片，或生成一张。'; return }
    }
    $asStatus.Text = '正在解析图片关键词…'
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $boundary = '----dsh' + [Guid]::NewGuid().ToString('N')
        $enc = [System.Text.Encoding]::UTF8
        $bytes = [System.IO.File]::ReadAllBytes($img)
        $ms = New-Object System.IO.MemoryStream
        $head = $enc.GetBytes(("--{0}`r`nContent-Disposition: form-data; name=`"image`"; filename=`"analyze.png`"`r`nContent-Type: image/png`r`n`r`n" -f $boundary))
        $ms.Write($head,0,$head.Length)
        $ms.Write($bytes,0,$bytes.Length)
        $tail = $enc.GetBytes(("`r`n--{0}--`r`n" -f $boundary))
        $ms.Write($tail,0,$tail.Length)
        $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:8189/upload/image')
        $req.Method = 'POST'
        $req.ContentType = 'multipart/form-data; boundary=' + $boundary
        $req.ContentLength = $ms.Length
        $stream = $req.GetRequestStream()
        $ms.WriteTo($stream)
        $stream.Close()
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $upJson = $reader.ReadToEnd()
        $reader.Close(); $resp.Close(); $ms.Dispose()
        $up = $upJson | ConvertFrom-Json
        $name = [string]$up.name
        if (-not $name) { throw '上传失败' }
        $body = @{
            prompt = @{
                '1' = @{ class_type='LoadImage'; inputs=@{ image=$name } }
                '2' = @{ class_type='WD14Tagger|pysssss'; inputs=@{ image=@('1',0); model='wd-eva02-large-tagger-v3'; threshold=0.35; character_threshold=0.85; replace_underscore=$true; trailing_comma=$false; exclude_tags='' } }
            }
        } | ConvertTo-Json -Depth 10
        $q = Invoke-RestMethod -Uri 'http://127.0.0.1:8189/prompt' -Method Post -Body $body -ContentType 'application/json'
        $promptId = [string]$q.prompt_id
        $tags = $null
        for ($i=0; $i -lt 120; $i++) {
            Start-Sleep -Seconds 1
            $h = Invoke-RestMethod -Uri ('http://127.0.0.1:8189/history/' + $promptId) -TimeoutSec 10
            $prop = $h.PSObject.Properties[$promptId]
            if ($prop) {
                $out = $prop.Value.outputs
                if ($out -and $out.'2' -and $out.'2'.tags) { $tags = @($out.'2'.tags); break }
                if ($prop.Value.status.status_str -eq 'error') { throw 'WD14 执行失败' }
            }
        }
        if (-not $tags) { throw '解析超时' }
        $asFinal.Text = ($tags -join ', ')
        $asStatus.Text = '解析完成：' + $tags.Count + ' 个关键词'
    } catch {
        $asStatus.Text = '解析失败：' + $_.Exception.Message
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        if ($tmpImg -and (Test-Path -LiteralPath $tmpImg)) { Remove-Item -LiteralPath $tmpImg -Force -ErrorAction SilentlyContinue }
    }
})

$asStatus.Text='进入关键词助手后自动连接本机文字模型；连接失败可点击刷新。'

function Add-Label($text,$x,$y) {
    $control = New-Object System.Windows.Forms.Label
    $control.Text = $text; $control.Location = New-Object System.Drawing.Point($x,$y); $control.AutoSize = $true
    $inputs.Controls.Add($control)
    return $control
}
function Add-Button($parent,$text,$x,$y,$width) {
    $control = New-Object System.Windows.Forms.Button
    $control.Text = $text; $control.Location = New-Object System.Drawing.Point($x,$y); $control.Size = New-Object System.Drawing.Size($width,32)
    $parent.Controls.Add($control)
    return $control
}
function Add-Number($x,$y,$min,$max,$value,$increment) {
    $control = New-Object System.Windows.Forms.NumericUpDown
    $control.Location = New-Object System.Drawing.Point($x,$y); $control.Size = New-Object System.Drawing.Size(135,30)
    $control.Minimum = $min; $control.Maximum = $max; $control.Increment = $increment; $control.Value = $value
    $inputs.Controls.Add($control)
    return $control
}
function Add-Section($text,$x,$y,$w) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text; $label.Location = New-Object System.Drawing.Point($x,$y); $label.AutoSize = $true
    $label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',10,[System.Drawing.FontStyle]::Bold)
    $label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#2B4A7A')
    $inputs.Controls.Add($label)
    $line = New-Object System.Windows.Forms.Panel
    $line.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#D5DCE8')
    $line.Location = New-Object System.Drawing.Point($x, ($y+20)); $line.Size = New-Object System.Drawing.Size($w, 1)
    $inputs.Controls.Add($line)
}
$null = Add-Section '生成设置' 12 2 445
$null = Add-Section '参考图（图生图）' 12 430 445
$null = Add-Section '高级参数' 12 558 445
$null = Add-Section '输出' 12 646 445
$null = Add-Label '生成方式' 12 24
$mode = New-Object System.Windows.Forms.ComboBox
$mode.Location = New-Object System.Drawing.Point(12,42); $mode.Width = 210; $mode.DropDownStyle = 'DropDownList'
$mode.Items.AddRange(@('文生图  /  用文字描述画面','图生图  /  上传图片并描述修改要求'))
$inputs.Controls.Add($mode)
$null = Add-Label '提示词 / 修改要求' 12 152
function Get-RandomRole {
    $hairColors = @('black','silver','blonde','brown','pink','purple','red','blue','white','orange')
    $hairStyles = @('long hair','short hair','twin tails','bob cut','ponytail','braid','wavy hair','straight hair','messy hair','hime cut')
    $eyeColors = @('red','blue','purple','green','amber','gray','gold','crimson','teal')
    $bodies = @('slender','petite','curvy','athletic','tall','mature woman','thick thighs','plump')
    $skins = @('pale skin','fair skin','tan skin','light skin')
    $ages = @('young adult','mature woman','25 years old','20s','30s')
    return '1girl, ' + $hairColors[(Get-Random -Maximum $hairColors.Count)] + ' hair, ' + $hairStyles[(Get-Random -Maximum $hairStyles.Count)] + ', ' + $eyeColors[(Get-Random -Maximum $eyeColors.Count)] + ' eyes, ' + $skins[(Get-Random -Maximum $skins.Count)] + ', ' + $bodies[(Get-Random -Maximum $bodies.Count)] + ', ' + $ages[(Get-Random -Maximum $ages.Count)] + ', '
}
$prompt = New-Object System.Windows.Forms.TextBox
$prompt.Location = New-Object System.Drawing.Point(12,174); $prompt.Size = New-Object System.Drawing.Size(440,70)
$prompt.Multiline = $true; $prompt.ScrollBars = 'Vertical'; $prompt.AcceptsReturn = $true
$inputs.Controls.Add($prompt)
$prompt.Add_TextChanged({
    $block = Split-PromptBlock $prompt.Text
    if ($block) {
        if ($block.Negative -and $negPrompt.Text -ne $block.Negative) { $negPrompt.Text = $block.Negative }
        $statusLabel.Text = '检测到提示词块格式：生成时会自动用 [编号] 后的正面词和 NEG 后的负面词。'
    }
})
$null = Add-Label '预设' 12 254
$fixedPrompt = New-Object System.Windows.Forms.TextBox
$fixedPrompt.Location = New-Object System.Drawing.Point(12,298); $fixedPrompt.Size = New-Object System.Drawing.Size(440,44)
$fixedPrompt.Multiline = $true; $fixedPrompt.ScrollBars = 'Vertical'
$inputs.Controls.Add($fixedPrompt)
$presetStyle = New-Object System.Windows.Forms.ComboBox
$presetStyle.Location = New-Object System.Drawing.Point(250, 276); $presetStyle.Width = 200; $presetStyle.DropDownStyle = 'DropDownList'
$legacyFixedPresets = @(
        '',
        'high key lighting, soft lighting, bright background, soft shading, airbrush shading, pale skin, pastel colors, low saturation, detailed eyes, gradient eyes, eye highlights, translucent hair, rim light, delicate lineart, smooth rendering, wet skin, glossy sheen, specular highlights, subsurface scattering, shiny thighs, masterpiece, best quality',
        'soft lighting, soft shading, airbrush shading, pastel colors, delicate lineart, soft edges, smooth rendering, gentle atmosphere, masterpiece, best quality, ultra-detailed',
        'thick painting, detailed illustration, rich colors, cinematic lighting, painterly, textured brushstrokes, volumetric light, masterpiece, best quality, ultra-detailed',
        '1girl, whale girl, blue violet hair, indigo hair, violet blue hair, deep blue purple hair, solid hair color, uniform hair color, long wavy hair, ahoge, blue eyes, whale fin ears, white frilled headband, blue hair ribbon, dark blue and white maid dress, white apron with whale pattern, gold trim, white socks, dark blue shoes, whale tail, cute, petite, small stature, round face, large eyes, moe, kawaii, bright smile, cheerful, sparkling eyes, playful, head tilt, high key lighting, soft lighting, bright background, soft shading, airbrush shading, pale skin, pastel colors, low saturation, detailed eyes, gradient eyes, eye highlights, translucent hair, rim light, delicate lineart, smooth rendering, wet skin, glossy sheen, specular highlights, subsurface scattering, shiny thighs, masterpiece, best quality',
        '1girl, whale girl, blue violet hair, indigo hair, violet blue hair, deep blue purple hair, solid hair color, uniform hair color, long wavy hair, ahoge, blue eyes, whale fin ears, white frilled headband, blue hair ribbon, dark blue and white maid dress, white apron with whale pattern, gold trim, white socks, dark blue shoes, whale tail, cute, petite, small stature, round face, large eyes, moe, kawaii, bright smile, cheerful, sparkling eyes, playful, head tilt, high key lighting, soft lighting, bright background, soft shading, airbrush shading, pale skin, pastel colors, low saturation, detailed eyes, gradient eyes, eye highlights, translucent hair, rim light, delicate lineart, smooth rendering, wet skin, glossy sheen, specular highlights, subsurface scattering, shiny thighs, masterpiece, best quality',
        '1girl, dragon girl, silver-white long hair, pale lavender eyes, two ridged curved dragon horns, pointed ears, pale lavender membranous dragon wings, long overlapping-scaled silver dragon tail, white high-neck gown, cascading ruffle sleeves, silver chain ornaments, silver knot medallion, elegant, high key lighting, soft lighting, bright background, soft shading, airbrush shading, pale skin, pastel colors, low saturation, detailed eyes, gradient eyes, eye highlights, translucent hair, rim light, delicate lineart, smooth rendering, wet skin, glossy sheen, specular highlights, subsurface scattering, shiny thighs, masterpiece, best quality'
    )
$stylePresetTexts = @($legacyFixedPresets[0], $legacyFixedPresets[1], $legacyFixedPresets[2], $legacyFixedPresets[3])
$characterPresetTexts = @('')
foreach ($index in @(4,6)) {
    $characterText = $legacyFixedPresets[$index]
    $suffix = ', ' + $legacyFixedPresets[1]
    if ($characterText.EndsWith($suffix)) { $characterText = $characterText.Substring(0,$characterText.Length - $suffix.Length) }
$characterPresetTexts += $characterText
}
$presetStyle.Items.AddRange(@('（不使用）', '林檎猫画风', '柔和空气感', '厚涂质感'))
$inputs.Controls.Add($presetStyle)
$presetCharacter = New-Object System.Windows.Forms.ComboBox
$presetCharacter.Location = New-Object System.Drawing.Point(232,276)
$presetCharacter.Width = 166; $presetCharacter.DropDownWidth = 200; $presetCharacter.DropDownStyle = 'DropDownList'
$presetCharacter.Items.AddRange(@('（不使用）', '大肥鱼', 'GPT龙娘'))
$expressionPresetTexts = @(
    '',
    'smile, gentle smile, soft expression',
    'bright smile, open mouth, cheerful, sparkling eyes',
    'blush, embarrassed, shy look, looking away',
    'pouty lips, puffed cheeks, tsundere expression, looking away',
    'gentle gaze, soft eyes, calm expression',
    'playful smile, light laugh, cheerful',
    'closed eyes, peaceful expression, serene',
    'surprised, wide eyes, open mouth',
    'angry, frown, glaring at viewer',
    'sad expression, teary eyes, downcast',
    'wink, one eye closed, playful',
    'kiss expression, puckered lips, eyes closed',
    'dazed expression, unfocused eyes, soft',
    'delighted expression, bright eyes, joyful',
    'confident smile, raised eyebrow, composed',
    'playful wink, slight smile',
    'relaxed sigh, calm expression',
    'intense gaze, sharp eyes, focused',
    'dreamy expression, soft smile, distant look',
    'pained expression, grimace, clenched teeth',
    'commanding look, dominant, smirk',
    'respectful look, calm eyes, polite',
    'pleading, begging look, teary eyes',
    'mockery, looking down, smirk',
    'content smile, relaxed, satisfied',
    'thoughtful, lips slightly parted',
    ''
    )
$presetExpression = New-Object System.Windows.Forms.ComboBox
$presetExpression.Location = New-Object System.Drawing.Point(348,222)
$presetExpression.Width = 140; $presetExpression.DropDownWidth = 180; $presetExpression.DropDownStyle = 'DropDownList'
$presetExpression.Items.AddRange(@('（不使用）','温柔微笑','元气笑','害羞','傲娇','柔和','俏皮','闭眼安静','惊讶','生气','悲伤','眨眼睛','亲吻','恍惚','欣喜','自信笑','俏皮眨眼','轻叹','锐利','出神','痛苦','命令','恭敬','哀求','嘲弄','满足','沉思','随机表情'))
$presetExpression.SelectedIndex = 0
$inputs.Controls.Add($presetExpression)
$inputs.Controls.Add($presetCharacter)
$script:appliedStylePreset = ''
$script:appliedCharacterPreset = ''
function Refresh-FixedPresets {
    if ($script:suppressRefresh) { return }
    $role = $(if ($presetCharacter.SelectedIndex -ge 0) { $characterPresetTexts[$presetCharacter.SelectedIndex] } else { '' })
    $style = $(if ($presetStyle.SelectedIndex -ge 0) { $stylePresetTexts[$presetStyle.SelectedIndex] } else { '' })
    $expr = ''
    if ($presetExpression.SelectedIndex -ge 0) {
        if ($presetExpression.SelectedIndex -eq ($expressionPresetTexts.Count - 1)) {
            $choices = @($expressionPresetTexts | Select-Object -Skip 1 | Where-Object { $_ })
            if ($choices.Count) { $expr = $choices[(Get-Random -Maximum $choices.Count)] }
        } else {
            $expr = $expressionPresetTexts[$presetExpression.SelectedIndex]
        }
    }
    $parts = @()
    if ($role) { $parts += $role }
    if ($style) { $parts += $style }
    if ($expr) { $parts += $expr }
    $fixedPrompt.Text = ($parts -join ', ')
}
$presetStyle.Add_SelectedIndexChanged({ Refresh-FixedPresets })
$presetCharacter.Add_SelectedIndexChanged({ Refresh-FixedPresets })
$presetExpression.Add_SelectedIndexChanged({ Refresh-FixedPresets })
$presetCharacter.SelectedIndex = 0
$presetStyle.SelectedIndex = 1
$null = Add-Label '负面提示词（可选）' 12 350
$negPrompt = New-Object System.Windows.Forms.TextBox
$negPrompt.Location = New-Object System.Drawing.Point(12,370); $negPrompt.Size = New-Object System.Drawing.Size(440,44)
$negPrompt.Multiline = $true; $negPrompt.ScrollBars = 'Vertical'
$negPrompt.Text = 'bad anatomy, bad composition, bad hands, blurry, camera shake, caption, censor, compression artifacts, extra digits, jpeg artifacts, logo, low quality, lowres, motion blur, out of focus, pixelated, signature, text, username, watermark, worst quality, bad shading, messy lineart, speech bubble, duplicate limbs, headshot, cropped, out of frame, zoomed in, face focus'
$inputs.Controls.Add($negPrompt)
$negPreset = New-Object System.Windows.Forms.ComboBox
$negPreset.Location = New-Object System.Drawing.Point(250, 348); $negPreset.Width = 200; $negPreset.DropDownStyle = 'DropDownList'
$negPreset.Items.AddRange(@('默认（动漫通用）', '（清空）', '明亮保护'))
$inputs.Controls.Add($negPreset)
$negPreset.Add_SelectedIndexChanged({
    $negTexts = @(
        'bad anatomy, bad composition, bad hands, blurry, camera shake, caption, censor, compression artifacts, extra digits, jpeg artifacts, logo, low quality, lowres, motion blur, out of focus, pixelated, signature, text, username, watermark, worst quality, bad shading, messy lineart, speech bubble, duplicate limbs, headshot, cropped, out of frame, zoomed in, face focus',
        '',
        'dark, dim lighting, heavy shadows, harsh shadows, hard shading, flat color, sketch, rough lines, muddy colors, bad anatomy, bad hands, blurry, low quality, worst quality, watermark, text'
    )
    if ($negPreset.SelectedIndex -ge 0) { $negPrompt.Text = $negTexts[$negPreset.SelectedIndex] }
})
$negPreset.SelectedIndex = 0
$imageLabel = Add-Label '参考图片（可直接拖入）' 12 450
$imagePath = New-Object System.Windows.Forms.TextBox
$imagePath.Location = New-Object System.Drawing.Point(12,472); $imagePath.Size = New-Object System.Drawing.Size(290,30); $imagePath.ReadOnly = $true
$inputs.Controls.Add($imagePath)
$chooseImage = Add-Button $inputs '选择图片' 310 470 130
$refUsageLabel = Add-Label '图片用途' 12 448
$refUsage = New-Object System.Windows.Forms.ComboBox
$refUsage.DropDownStyle = 'DropDownList'; $refUsage.Width = 440; $refUsage.Top = 470
$refUsage.Items.AddRange(@('修改原图', '参考元素，重新生成'))
$inputs.Controls.Add($refUsage)
$refStrengthLabel = Add-Label '修改幅度' 12 448
$refPreset = New-Object System.Windows.Forms.ComboBox
$refPreset.DropDownStyle = 'DropDownList'; $refPreset.Width = 210; $refPreset.Top = 470
$inputs.Controls.Add($refPreset)
$refElementLabel = Add-Label '参考元素' 242 448
$refElement = New-Object System.Windows.Forms.ComboBox
$refElement.DropDownStyle = 'DropDownList'; $refElement.Width = 210; $refElement.Top = 470
$refElement.Items.AddRange(@('人物外观', '动作姿态', '画风', '综合参考'))
$refElement.SelectedIndex = 0
$inputs.Controls.Add($refElement)
$refHint = Add-Label '请选择参考图用途。' 12 500
$refHint.AutoSize = $false; $refHint.Size = New-Object System.Drawing.Size(440,48)
function Update-ReferenceHint {
    if ($refUsage.SelectedIndex -eq 1) {
        $refHint.Text = @('以提示词为主，从新画面开始；仅用图片辅助理解。', '兼顾文字与图片，部分沿用原图布局。', '更接近原图，也更容易沿用原图布局。')[[Math]::Max(0,$refPreset.SelectedIndex)] + "`n元素选择通过指令表达，不保证锁脸或精确复刻动作。"
    } else {
        $refHint.Text = @('轻微修改：尽量保留原图，适合小幅调整。', '常规修改：兼顾保留与改动，建议从这里开始。', '大幅重绘：允许明显变化，人物和细节也可能改变。')[[Math]::Max(0,$refPreset.SelectedIndex)]
    }
}
$refPreset.Add_SelectedIndexChanged({ Update-ReferenceHint })
$refUsage.Add_SelectedIndexChanged({
    $feature = $refUsage.SelectedIndex -eq 1
    $refPreset.Items.Clear()
    if ($feature) { $refPreset.Items.AddRange(@('自由发挥', '平衡参考', '贴近参考')); $refPreset.SelectedIndex = 0 }
    else { $refPreset.Items.AddRange(@('轻微修改', '常规修改', '大幅重绘')); $refPreset.SelectedIndex = 1 }
    $refStrengthLabel.Text = $(if ($feature) {'参考档位'} else {'修改幅度'})
    $refElement.Enabled = $feature -and ($mode.SelectedIndex -eq 1)
    if ($mode.SelectedIndex -eq 1) {
        $target = $(if ($feature) {3} else {2})
        if ($asMode.SelectedIndex -ne $target) { $asMode.SelectedIndex = $target }
    }
    Update-ReferenceHint
})
$refUsage.SelectedIndex = 0
$null = Add-Label '画面尺寸 / 清晰度' 242 24
$preset = New-Object System.Windows.Forms.ComboBox
$preset.Location = New-Object System.Drawing.Point(242,42); $preset.Width = 210; $preset.DropDownStyle = 'DropDownList'
$inputs.Controls.Add($preset)
$sizePresets = @(foreach ($dimensions in @(
    '256x256','512x512','768x768','1024x576','576x1024','1024x768','768x1024',
    '1216x832','832x1216','1024x1024','1536x864','864x1536',
    '1536x1536','1920x1088','1088x1920','2048x2048'
)) {
    $parts = $dimensions.Split('x'); $w = [int]$parts[0]; $h = [int]$parts[1]
    $shape = $(if ($w -eq $h) {'方形'} elseif ($w -gt $h) {'横图'} else {'竖图'})
    $suffix = $(if ($w -eq 1024 -and $h -eq 1024) {'（推荐）'} elseif ($w -eq 2048 -and $h -eq 2048) {'（2K，显存需求高）'} elseif ($w -eq 1920 -or $h -eq 1920) {'（近 1080p）'} else {''})
    [pscustomobject]@{Width=$w; Height=$h; Name=($shape+' '+$w+' × '+$h+$suffix)}
}) | Sort-Object @{Expression={$_.Width * $_.Height}},@{Expression={$_.Width};Descending=$true}
$defaultSizeIndex = 0
for ($index=0; $index -lt $sizePresets.Count; $index++) {
    if ($sizePresets[$index].Width -eq 1024 -and $sizePresets[$index].Height -eq 1024) { $defaultSizeIndex=$index; break }
}
$preset.MaxDropDownItems = 18
$preset.IntegralHeight = $false
$preset.DropDownHeight = 410

$null = Add-Label '宽' 12 74
$null = Add-Label '高' 110 74
$width = Add-Number 12 92 256 2048 1024 32; $width.Width = 90
$height = Add-Number 110 92 256 2048 1024 32; $height.Width = 90
$stepsLabel = Add-Label '步数' 12 578
$null = Add-Label '引导强度' 115 578
$steps = Add-Number 12 598 1 100 25 1; $steps.Width = 90
$cfg = Add-Number 115 598 1 10 1 0.1; $cfg.Width = 90
$cfg.DecimalPlaces = 1
$countLabel = Add-Label '数量（每段）' 210 74
$batchCount = Add-Number 210 92 1 ([int]::MaxValue) 1 1; $batchCount.Width = 90
$batchCount.Width = 90
$batchCount.Add_ValueChanged({ if ($mode.SelectedIndex -eq 0) { $script:textCount = [int]$batchCount.Value } })

$null = Add-Label '种子(-1 随机)' 218 578
$seed = New-Object System.Windows.Forms.TextBox
$seed.Location = New-Object System.Drawing.Point(218,598); $seed.Size = New-Object System.Drawing.Size(140,30); $seed.Text = '-1'
$inputs.Controls.Add($seed)
$random = Add-Button $inputs '随机' 365 596 80
$random.Add_Click({ $seed.Text = '-1' })
$null = Add-Label '输出文件夹' 12 668
$output = New-Object System.Windows.Forms.TextBox
$output.Location = New-Object System.Drawing.Point(12,688); $output.Size = New-Object System.Drawing.Size(290,30)
$output.Text = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Qwen生图'
$inputs.Controls.Add($output)
$chooseOutput = Add-Button $inputs '选择位置' 310 686 130

$resultTitle = New-Object System.Windows.Forms.Label
$resultTitle.Dock = 'Top'; $resultTitle.Height = 33; $resultTitle.Text = '图片预览（可拖入参考图）'
$resultTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',12,[System.Drawing.FontStyle]::Bold)
$right.Controls.Add($resultTitle)
$resultBottom = New-Object System.Windows.Forms.Panel
$resultBottom.Dock = 'Bottom'; $resultBottom.Height = 180; $right.Controls.Add($resultBottom)
$openImage = Add-Button $resultBottom '打开图片' 0 4 115
$openFolder = Add-Button $resultBottom '打开文件夹' 126 4 130
$openImage.Enabled = $false; $openFolder.Enabled = $false
$previousResult=Add-Button $resultBottom '上一张' 0 42 80
$nextResult=Add-Button $resultBottom '下一张' 90 42 80
$deleteResult=Add-Button $resultBottom '删除' 266 4 64
$returnLatest=Add-Button $resultBottom '回到当前' 180 42 100
$returnLatest.Enabled=$false
$returnLatest.Add_Click({ Resume-LatestPreview })
$deleteResult.Enabled=$false
$deleteResult.Add_Click({ Remove-CurrentResult })
$resultPosition=New-Object System.Windows.Forms.Label
$resultPosition.Location=New-Object System.Drawing.Point(290,48); $resultPosition.Size=New-Object System.Drawing.Size(150,24)
$latestPreview=New-Object Windows.Forms.PictureBox
$latestPreview.Size=New-Object Drawing.Size(128,128)
$latestPreview.Location=New-Object Drawing.Point(($resultBottom.ClientSize.Width-132),38)
$latestPreview.Anchor='Top,Right'; $latestPreview.SizeMode='Zoom'
$latestPreview.BackColor=[Drawing.ColorTranslator]::FromHtml('#EDF1F7')
$latestPreview.BorderStyle='FixedSingle'; $latestPreview.Cursor='Hand'; $latestPreview.Visible=$false
$resultBottom.Controls.Add($latestPreview)
$latestPreviewTip=New-Object Windows.Forms.ToolTip
$latestPreviewTip.SetToolTip($latestPreview,'最新生成的图片；点击切回并恢复自动跟随')
$latestPreview.Add_Click({ Resume-LatestPreview })
$resultPosition.Text='暂无结果'; $resultBottom.Controls.Add($resultPosition)
$previousResult.Enabled=$false; $nextResult.Enabled=$false
$previousResult.Add_Click({ Move-Result -1 })
$nextResult.Add_Click({ Move-Result 1 })
$resultPath = New-Object System.Windows.Forms.TextBox
$resultPath.Location = New-Object System.Drawing.Point(0,82); $resultPath.Width = 570; $resultPath.Height = 45
$resultPath.Multiline = $true; $resultPath.ReadOnly = $true; $resultPath.BorderStyle = 'None'; $resultPath.BackColor = [System.Drawing.Color]::White
$resultPath.Anchor = 'Top,Left,Right'; $resultPath.Width-=80; $resultBottom.Controls.Add($resultPath)
$resultBottom.Add_Resize({ $resultPath.Width=[Math]::Max(100,$resultBottom.ClientSize.Width-144); $resultPosition.Width=[Math]::Max(0,$latestPreview.Left-$resultPosition.Left-8) })
$resultPath.Width=[Math]::Max(100,$resultBottom.ClientSize.Width-144)
$preview = New-Object System.Windows.Forms.PictureBox
$preview.Dock = 'Fill'; $preview.SizeMode = 'Zoom'; $preview.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#E9EEF5')
$right.Controls.Add($preview); $preview.BringToFront()

$generate = Add-Button $footer '开始生成' 24 18 170
$generate.Height = 45; $generate.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#2463CC')
$generate.ForeColor = [System.Drawing.Color]::White; $generate.FlatStyle = 'Flat'; $generate.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',12,[System.Drawing.FontStyle]::Bold)
$stop = Add-Button $footer '停止' 202 18 100
$stop.Height = 45
$stop.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#C0504D')
$stop.ForeColor = [System.Drawing.Color]::White
$stop.FlatStyle = 'Flat'
$stop.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',11,[System.Drawing.FontStyle]::Bold)
$stop.Enabled = $false
$addQueue=Add-Button $footer '加入队列' 24 70 170
$manageQueue=Add-Button $footer '任务队列' 202 70 100
$queueStatus=New-Object Windows.Forms.Label
$queueStatus.Location=New-Object Drawing.Point(330,86); $queueStatus.Size=New-Object Drawing.Size(600,22)
$queueStatus.Anchor='Top,Left,Right'; $queueStatus.AutoEllipsis=$true; $footer.Controls.Add($queueStatus)
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '准备就绪。填写提示词，然后点击开始生成。'; $statusLabel.Location = New-Object System.Drawing.Point(330,12)
$statusLabel.Size = New-Object System.Drawing.Size(760,25); $statusLabel.Anchor = 'Top,Left,Right'; $footer.Controls.Add($statusLabel)
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(330,42); $progress.Size = New-Object System.Drawing.Size(760,12)
$progress.Anchor = 'Top,Left,Right'; $footer.Controls.Add($progress)
$elapsed = New-Object System.Windows.Forms.Label
$elapsed.Text = '模型自动连接；未启动时会自动启动。'; $elapsed.Location = New-Object System.Drawing.Point(330,60)
$elapsed.Size = New-Object System.Drawing.Size(760,22); $elapsed.ForeColor = [System.Drawing.Color]::DimGray
$elapsed.Anchor = 'Top,Left,Right'; $footer.Controls.Add($elapsed)

$batchSummary=New-Object System.Windows.Forms.Label
$batchSummary.Location=New-Object System.Drawing.Point(24,106); $batchSummary.Size=New-Object System.Drawing.Size(1120,22)
$batchSummary.Anchor='Left,Right,Bottom'; $batchSummary.AutoEllipsis=$true; $footer.Controls.Add($batchSummary)

function Show-Preview($path) {
    try {
        $original = [System.Drawing.Image]::FromFile($path)
        try { $bitmap = New-Object System.Drawing.Bitmap($original) } finally { $original.Dispose() }
        $old=$preview.Image
        $preview.Image=$bitmap; $script:loadedPreviewPath=[string]$path
        if ($old) { $old.Dispose() }
        return $true
    } catch { $statusLabel.Text='图片读取失败：'+[IO.Path]::GetFileName($path)+' · '+$_.Exception.Message; return $false }
}

function Set-LargeImageLayout {
    if (-not $script:imageViewer -or $script:imageViewer.IsDisposed) { return }
    $state=$script:imageViewer.Tag
    $state.Picture.ApplyZoom($state.Zoom,[Drawing.Point]::Empty,$false)
    $state.ScaleLabel.Text=('{0:0.#}%' -f (100*$state.Picture.ImageScale))
}
function Zoom-LargeImage([int]$delta,[Drawing.Point]$anchor) {
    if (-not $script:imageViewer -or $script:imageViewer.IsDisposed) { return }
    $state=$script:imageViewer.Tag
    if (-not $state.Picture.Image -or $delta -eq 0) { return }
    $state.Zoom=[Math]::Max(0.1,[Math]::Min(16.0,$state.Zoom*[Math]::Pow(1.2,$delta/120.0)))
    $state.Picture.ApplyZoom($state.Zoom,$anchor,$true)
    $state.ScaleLabel.Text=('{0:0.#}%' -f (100*$state.Picture.ImageScale))
}
function Set-LargeImageSize([bool]$originalSize) {
    if (-not $script:imageViewer -or -not $script:imageViewer.Tag.Picture.Image) { return }
    $state=$script:imageViewer.Tag
    $state.Zoom=$(if($originalSize){1.0/$state.Picture.FitScale}else{1.0})
    $state.Pane.AutoScrollPosition=[Drawing.Point]::Empty
    Set-LargeImageLayout
}
function Get-GalleryImages([string]$folder,[switch]$Refresh) {
    $key=([IO.Path]::GetFullPath($folder).TrimEnd('\','/')+'\')
    $directory=Get-Item -LiteralPath $key -ErrorAction Stop
    if (-not $directory.PSIsContainer) { throw '图片文件夹不存在。' }
    $stamp=$directory.LastWriteTimeUtc.Ticks
    $cached=$script:galleryCache[$key]
    if (-not $Refresh -and $cached -and $cached.Stamp -eq $stamp) { return $cached.Files }
    $files=@(Get-ChildItem -LiteralPath $key -File -ErrorAction Stop |
        Where-Object { $_.Extension.ToLowerInvariant() -in @('.png','.jpg','.jpeg','.bmp','.gif','.tif','.tiff') } |
        Sort-Object @{Expression={ $_.LastWriteTimeUtc }}, @{Expression={ if ($_.BaseName -match '^\d+$') { [double]$_.BaseName } else { [double]::PositiveInfinity } }}, Name |
        ForEach-Object { $_.FullName })
    $script:galleryCache[$key]=@{Stamp=$stamp; Files=$files}
    return $files
}
function Update-LargeImageViewer {
    if (-not $script:imageViewer -or $script:imageViewer.IsDisposed) { return }
    $viewer=$script:imageViewer; $state=$viewer.Tag; $picture=$state.Picture
    $path=$null
    if ($state.Index -ge 0 -and $state.Index -lt $state.Files.Count) { $path=$state.Files[$state.Index] }
    if ($state.ImagePath -ne $path) {
        $image=$null
        if ($path) {
            try {
                $source=[Drawing.Image]::FromFile($path)
                try { $image=New-Object Drawing.Bitmap($source) } finally { $source.Dispose() }
            } catch {
                $state.Index=[Array]::IndexOf($state.Files,[string]$state.ImagePath)
                $state.Previous.Enabled=$state.Index -gt 0
                $state.Next.Enabled=$state.Index -ge 0 -and $state.Index -lt $state.Files.Count-1
                $viewer.Text='图片读取失败：'+[IO.Path]::GetFileName($path)+' · '+$_.Exception.Message
                return
            }
        }
        if ($picture.Image) { $picture.Image.Dispose() }
        $picture.Image=$image; $state.ImagePath=$path; $state.Zoom=1.0
        $state.Pane.AutoScrollPosition=[Drawing.Point]::Empty
    }
    $viewer.Text=$(if($path){'图片浏览 · '+[IO.Path]::GetFileName($path)+' · '+($state.Index+1)+' / '+$state.Files.Count}else{'图片浏览 · 暂无图片'})
    $state.Previous.Enabled=$state.Index -gt 0
    $state.Next.Enabled=$state.Index -ge 0 -and $state.Index -lt $state.Files.Count-1
    $state.Delete.Enabled=[bool]$path
    Set-LargeImageLayout
}
function Move-LargeImage([int]$direction) {
    if (-not $script:imageViewer) { return }
    $state=$script:imageViewer.Tag
    try { $files=@(Get-GalleryImages $state.Folder) } catch { $script:imageViewer.Text='读取文件夹失败：'+$_.Exception.Message; return }
    $index=[Array]::IndexOf($files,[string]$state.ImagePath)
    if ($index -lt 0) { $index=[Math]::Min($state.Index,$files.Count-1); $direction=0 }
    $state.Files=$files; $state.Index=[Math]::Max(-1,[Math]::Min([Math]::Max(0,$index+$direction),$files.Count-1))
    Update-LargeImageViewer
}
function Remove-LargeImage {
    if (-not $script:imageViewer -or -not $script:imageViewer.Tag.ImagePath) { return }
    $state=$script:imageViewer.Tag
    try { Move-ImageToRecycleBin $state.ImagePath } catch { $script:imageViewer.Text='删除失败：'+$_.Exception.Message; return }
    Move-LargeImage 0
}
function Show-LargeImageViewer {
    if (-not $script:lastFile -or $script:previewingReference) { return }
    if ($script:imageViewer -and -not $script:imageViewer.IsDisposed) {
        if ($script:imageViewer.WindowState -eq 'Minimized') { $script:imageViewer.WindowState='Normal' }
        $script:imageViewer.Activate(); return
    }
    $folder=Split-Path $script:lastFile -Parent
    try { $files=@(Get-GalleryImages $folder) } catch { $statusLabel.Text='读取图片文件夹失败：'+$_.Exception.Message; return }
    $index=[Array]::IndexOf($files,[string]$script:lastFile)
    if ($index -lt 0) { return }
    $viewer=New-Object Windows.Forms.Form
    $viewer.Text='图片浏览'; $viewer.StartPosition='CenterParent'; $viewer.Font=$form.Font; $viewer.Icon=$form.Icon
    $area=[Windows.Forms.Screen]::FromControl($form).WorkingArea
    $viewer.Size=New-Object Drawing.Size(([Math]::Min(1040,$area.Width)),([Math]::Min(820,$area.Height)))
    $viewer.MinimumSize=New-Object Drawing.Size(640,480); $viewer.KeyPreview=$true
    $viewer.BackColor=[Drawing.ColorTranslator]::FromHtml('#EDF1F7')
    $bar=New-Object Windows.Forms.Panel
    $bar.Dock='Bottom'; $bar.Height=92; $bar.BackColor=[Drawing.Color]::White
    $viewer.Controls.Add($bar)
    $back=Add-Button $bar '上一张' 16 12 80
    $forward=Add-Button $bar '下一张' 106 12 80
    $remove=Add-Button $bar '删除' 196 12 64
    $fitButton=Add-Button $bar '适应窗口' 280 12 94
    $originalButton=Add-Button $bar '原始大小' 384 12 94
    $scaleLabel=New-Object Windows.Forms.Label
    $scaleLabel.Location=New-Object Drawing.Point(490,18); $scaleLabel.Size=New-Object Drawing.Size(110,24)
    $bar.Controls.Add($scaleLabel)
    $fitButton.Add_Click({ Set-LargeImageSize $false })
    $originalButton.Add_Click({ Set-LargeImageSize $true })
    $hint=New-Object Windows.Forms.Label
    $hint.Text='点击左右或 ← → 翻页 · 滚轮缩放 · 按住拖动 · Delete 删除 · Esc 关闭'
    $hint.AutoSize=$true; $hint.Location=New-Object Drawing.Point(16,58); $bar.Controls.Add($hint)
    $picture=New-Object WorkbenchImageCanvas
    $pane=$picture
    $picture.Dock='Fill'; $picture.BackColor=$viewer.BackColor
    $viewer.Controls.Add($picture); $picture.BringToFront()
    $picture.Add_SizeChanged({ Set-LargeImageLayout })
    $picture.Add_MouseEnter({ $this.Focus() | Out-Null })
    $picture.Add_MouseClick({
        param($sender,$eventArgs)
        if ($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Left -or -not $sender.Image) { return }
        if ($eventArgs.X -lt $sender.ClientSize.Width/2) { Move-LargeImage -1 } else { Move-LargeImage 1 }
    })
    $picture.Add_ZoomWheel({
        param($sender,$eventArgs)
        Zoom-LargeImage $eventArgs.Delta $eventArgs.Location
    })
    $viewer.Tag=@{Picture=$picture; Pane=$pane; Zoom=1.0; ImagePath=$null; Previous=$back; Next=$forward; Delete=$remove; Folder=$folder; Files=$files; Index=$index; ScaleLabel=$scaleLabel; FitButton=$fitButton; OriginalButton=$originalButton}
    $back.Add_Click({ Move-LargeImage -1 })
    $forward.Add_Click({ Move-LargeImage 1 })
    $remove.Add_Click({ Remove-LargeImage })
    foreach ($button in @($picture,$back,$forward,$remove,$fitButton,$originalButton)) {
        $button.Add_PreviewKeyDown({
            param($sender,$eventArgs)
            if ($eventArgs.KeyCode -in @('Left','Right')) { $eventArgs.IsInputKey=$true }
        })
    }
    $viewer.Add_KeyDown({
        param($sender,$eventArgs)
        switch ($eventArgs.KeyCode) {
            'Left' { Move-LargeImage -1; $eventArgs.SuppressKeyPress=$true }
            'Right' { Move-LargeImage 1; $eventArgs.SuppressKeyPress=$true }
            'Delete' { Remove-LargeImage; $eventArgs.SuppressKeyPress=$true }
            'Escape' { $sender.Close(); $eventArgs.SuppressKeyPress=$true }
        }
    })
    $viewer.Add_FormClosed({
        param($sender,$eventArgs)
        if ($sender.Tag.Picture.Image) { $sender.Tag.Picture.Image.Dispose(); $sender.Tag.Picture.Image=$null }
        $script:imageViewer=$null
    })
    $script:imageViewer=$viewer
    Update-LargeImageViewer
    $viewer.Show($form)
}
function Show-Result([int]$index) {
    if ($index -lt 0 -or $index -ge $script:resultFiles.Count) { return }
    $path=$script:resultFiles[$index]
    if ($script:loadedPreviewPath -ne $path -or -not $preview.Image) {
        if (-not (Show-Preview $path)) { return }
    }
    $script:previewingReference=$false
    $script:resultIndex=$index; $script:lastFile=$path
    $resultPath.Text=$script:lastFile
    $resultPosition.Text=('{0} / {1}' -f ($index+1),$script:resultFiles.Count)
    $resultTitle.Text='图片预览 · '+$resultPosition.Text
    $previousResult.Enabled=$index -gt 0; $nextResult.Enabled=$index -lt $script:resultFiles.Count-1
    $openImage.Enabled=$true; $openFolder.Enabled=$true; $deleteResult.Enabled=$true; $returnLatest.Enabled=$true
}
function Move-ImageToRecycleBin([string]$path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    $script:galleryCache.Remove(([IO.Path]::GetFullPath((Split-Path $path -Parent)).TrimEnd('\','/')+'\'))
}
function Remove-CurrentResult {
    if ($script:previewingReference -or -not $script:lastFile) { return }
    $path=$script:lastFile
    $index=$script:resultIndex
    try { Move-ImageToRecycleBin $path } catch { $statusLabel.Text='删除失败：'+$_.Exception.Message; return }
    $script:manualGalleryBrowse=$true
    if ($latestPreview.Tag -eq $path) {
        $latestPreview.Visible=$false; $latestPreview.Tag=$null
        if ($latestPreview.Image) { $latestPreview.Image.Dispose(); $latestPreview.Image=$null }
    }
    if (-not (Update-FolderGallery (Split-Path $path -Parent))) { return }
    if ($script:resultFiles.Count) { Show-Result ([Math]::Max(0,[Math]::Min($index,$script:resultFiles.Count-1))) }
    else {
        if ($preview.Image) { $preview.Image.Dispose(); $preview.Image=$null }
        $script:lastFile=$null; $script:resultIndex=-1
        $resultPath.Text=''; $resultPosition.Text='暂无图片'; $resultTitle.Text='图片预览 · 支持拖放与粘贴'
        foreach ($button in @($previousResult,$nextResult,$deleteResult,$openImage,$returnLatest)) { $button.Enabled=$false }
        $preview.Invalidate()
    }
    $statusLabel.Text='已将图片移到回收站：'+[IO.Path]::GetFileName($path)
}
function Update-FolderGallery([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return $false }
    try {
        $files=@(Get-GalleryImages $folder)
    } catch { $statusLabel.Text='读取图片文件夹失败：'+$_.Exception.Message; return $false }
    $script:resultFiles=$files
    $script:resultIndex=[Array]::IndexOf($files,[string]$script:lastFile)
    return $true
}
function Resume-LatestPreview {
    $path=$script:latestGeneratedFile
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { $path=$script:lastFile }
    $folder=$output.Text
    if ($path) { $folder=Split-Path $path -Parent }
    if (-not (Update-FolderGallery $folder) -or -not $script:resultFiles.Count) { return }
    $index=[Array]::IndexOf($script:resultFiles,[string]$path)
    if ($index -lt 0) { $index=$script:resultFiles.Count-1 }
    $script:manualGalleryBrowse=$false
    Show-Result $index
    $latestPreview.Visible=$false
}
function Move-Result([int]$direction) {
    $script:manualGalleryBrowse=$true
    $folder=$output.Text
    if ($script:lastFile -and -not $script:previewingReference) { $folder=Split-Path $script:lastFile -Parent }
    if (-not (Update-FolderGallery $folder)) { return }
    if ($script:resultFiles.Count -eq 0) { return }
    $index=$script:resultIndex
    if ($index -lt 0) { $index=$(if($direction -lt 0){$script:resultFiles.Count}else{-1}) }
    Show-Result ([Math]::Max(0,[Math]::Min($index+$direction,$script:resultFiles.Count-1)))
}
function Open-OutputGallery {
    if ($script:worker -or $script:previewingReference) { return }
    if ((Update-FolderGallery $output.Text) -and $script:resultFiles.Count) {
        $index=$script:resultIndex
        if ($index -lt 0) { $index=$script:resultFiles.Count-1 }
        Show-Result $index
    } else { $previousResult.Enabled=$false; $nextResult.Enabled=$false }
}
function Add-ResultFiles($paths) {
    $incoming=@($paths | Where-Object { $_ -and -not $script:seenGeneratedFiles.ContainsKey([string]$_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique)
    if (-not $incoming.Count) { return }
    $script:latestGeneratedFile=[string]$incoming[-1]
    $returnLatest.Enabled=$true
    $followLatest=-not $script:manualGalleryBrowse
    $current=$script:lastFile
    $folder=Split-Path $incoming[-1] -Parent
    $script:galleryCache.Remove(([IO.Path]::GetFullPath($folder).TrimEnd('\','/')+'\'))
    if (-not (Update-FolderGallery $folder)) { return }
    foreach ($file in $incoming) { $script:seenGeneratedFiles[[string]$file]=$true }
    if ($script:manualGalleryBrowse) {
        try {
            $source=[Drawing.Image]::FromFile($incoming[-1])
            try { $thumbnail=New-Object Drawing.Bitmap($source) } finally { $source.Dispose() }
            if ($latestPreview.Image) { $latestPreview.Image.Dispose() }
            $latestPreview.Image=$thumbnail; $latestPreview.Tag=[string]$incoming[-1]; $latestPreview.Visible=$true
        } catch { $statusLabel.Text='新图片已保存，小预览读取失败：'+$_.Exception.Message }
    }
    if ($script:previewingReference) {
        $script:resultIndex=$script:resultFiles.Count
        $previousResult.Enabled=$true; $nextResult.Enabled=$true
    } elseif ($followLatest) {
        Show-Result ([Array]::IndexOf($script:resultFiles,[string]$incoming[-1]))
    } else {
        $index=[Array]::IndexOf($script:resultFiles,[string]$current)
        if ($index -lt 0) { $index=$script:resultFiles.Count-1 }
        Show-Result $index
    }
}
function Get-DroppedReferenceImages($data) {
    if (-not $data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { return }
    $files = @($data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    if ($files.Count -lt 1) { return }
    foreach ($path in $files) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        if ([System.IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp','.bmp','.tif','.tiff')) { return }
    }
    return $files
}
function Set-ReferenceImages([string[]]$paths) {
    if (-not (Test-ImageModel)) { $statusLabel.Text='当前模型仅支持文生图；添加参考图请先切换 Qwen 标准版或 Turbo。'; return }
    if ($paths.Count -lt 1) { throw '请至少选择一张参考图片。' }
    $script:referenceFiles = @($paths)
    if ($mode.SelectedIndex -ne 1) { $mode.SelectedIndex = 1 }
    $batchCount.Value = 1
    $imagePath.Text = $(if ($paths.Count -eq 1) {$paths[0]} else {'已选 '+$paths.Count+' 张 · '+$paths[0]})
    if ($preview.Image) { $preview.Image.Dispose(); $preview.Image = $null }
    $resultPath.Text = ($paths -join [Environment]::NewLine)
    $null=Show-Preview $paths[0]
    $resultTitle.Text = '参考图片预览（已选 '+$paths.Count+' 张）'
    $openImage.Enabled = $false; $openFolder.Enabled = $false
    $script:previewingReference=$true
    $deleteResult.Enabled=$false
    $previousResult.Enabled=$script:resultFiles.Count -gt 0; $nextResult.Enabled=$script:resultFiles.Count -gt 0
    $script:resultIndex=$script:resultFiles.Count; $resultPosition.Text='参考图预览'
    $statusLabel.Text = '已选择 '+$paths.Count+' 张图片，将使用同一修改要求逐张处理。'
    Update-BatchSummary
}
$script:pasteDir = Join-Path $env:TEMP 'qwen_paste'
function Get-ClipboardImages {
    $paths = @()
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
            foreach ($file in @([System.Windows.Forms.Clipboard]::GetFileDropList())) {
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
                $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
                if ($ext -in @('.png','.jpg','.jpeg','.webp','.bmp','.tif','.tiff')) { $paths += $file }
            }
        }
        if ($paths.Count -eq 0 -and [System.Windows.Forms.Clipboard]::ContainsImage()) {
            $image = [System.Windows.Forms.Clipboard]::GetImage()
            if ($image) {
                New-Item -ItemType Directory -Force -Path $script:pasteDir | Out-Null
                $dest = Join-Path $script:pasteDir ('paste_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.png')
                $image.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
                $image.Dispose()
                $paths += $dest
            }
        }
    } catch { }
    return $paths
}
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $eventArgs)
    if (-not ($eventArgs.Control -and $eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::V)) { return }
    $paths = @(Get-ClipboardImages)
    if ($paths.Count -eq 0) { return }
    Set-ReferenceImages $paths
    $statusLabel.Text = '已从剪贴板粘贴 ' + $paths.Count + ' 张图片。'
    $eventArgs.Handled = $true
    $eventArgs.SuppressKeyPress = $true
})
if ($TestPaste) {
    $bmp = New-Object System.Drawing.Bitmap(64, 64)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    $graphics.Clear([System.Drawing.Color]::Red)
    $graphics.Dispose()
    [System.Windows.Forms.Clipboard]::SetImage($bmp)
    $paths = @(Get-ClipboardImages)
    Write-Host ('PASTE_COUNT=' + $paths.Count)
    if ($paths.Count) {
        Write-Host ('PASTE_EXISTS=' + (Test-Path -LiteralPath $paths[0]))
        Set-ReferenceImages $paths
        Write-Host ('PASTE_MODE=' + $mode.SelectedIndex)
        Write-Host ('PASTE_PREVIEW=' + [bool]$preview.Image)
    }
    $bmp.Dispose()
    exit 0
}
$imageDragEnterHandler = {
    param($sender,$eventArgs)
    $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None
    if (Get-DroppedReferenceImages $eventArgs.Data) {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
}
$imageDropHandler = {
    param($sender,$eventArgs)
    $paths = @(Get-DroppedReferenceImages $eventArgs.Data)
    if ($paths.Count) { Set-ReferenceImages $paths }
}
foreach ($dropTarget in @($form,$preview,$imagePath,$imageLabel)) {
    $dropTarget.AllowDrop = $true
    $dropTarget.Add_DragEnter($imageDragEnterHandler)
    $dropTarget.Add_DragDrop($imageDropHandler)
}

$chooseImage.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Title = '选择参考图片（可多选）'; $dialog.Filter = '图片|*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.tif;*.tiff|所有文件|*.*'
    if ($dialog.ShowDialog($form) -eq 'OK') {
        Set-ReferenceImages $dialog.FileNames
    }
    $dialog.Dispose()
})
$chooseOutput.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择生成图片保存位置'; $dialog.ShowNewFolderButton = $true
    if (Test-Path -LiteralPath $output.Text -PathType Container) { $dialog.SelectedPath = $output.Text }
    if ($dialog.ShowDialog($form) -eq 'OK') { $output.Text = $dialog.SelectedPath; Open-OutputGallery }
    $dialog.Dispose()
})
$openImage.Add_Click({ Show-LargeImageViewer })
$preview.Add_MouseClick({
    param($sender,$eventArgs)
    if ($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Left -or -not $openImage.Enabled -or -not $sender.Image) { return }
    $scale=[Math]::Min($sender.ClientSize.Width/[double]$sender.Image.Width,$sender.ClientSize.Height/[double]$sender.Image.Height)
    $w=$sender.Image.Width*$scale; $h=$sender.Image.Height*$scale
    $bounds=New-Object Drawing.RectangleF(([single](($sender.ClientSize.Width-$w)/2)),([single](($sender.ClientSize.Height-$h)/2)),([single]$w),([single]$h))
    if ($bounds.Contains([single]$eventArgs.X,[single]$eventArgs.Y)) { Show-LargeImageViewer }
})
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WorkbenchFolderWindow {
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
}
public class WorkbenchImageCanvas : System.Windows.Forms.ScrollableControl {
    public System.Drawing.Image Image { get; set; }
    private double zoom = 1.0;
    private System.Drawing.Size imageSize;
    private bool dragging, pressed, updating;
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool RedrawWindow(IntPtr hwnd, IntPtr rect, IntPtr region, uint flags);
    private void UpdateView(Action change) {
        if (updating) return;
        updating = true;
        bool freeze = IsHandleCreated && Visible;
        try {
            // Native scrollbar updates copy pixels before OnPaint; hide that intermediate frame.
            if (freeze) SendMessage(Handle, 0x000B, IntPtr.Zero, IntPtr.Zero);
            change();
        } finally {
            updating = false;
            if (freeze && !IsDisposed) {
                SendMessage(Handle, 0x000B, new IntPtr(1), IntPtr.Zero);
                RedrawWindow(Handle, IntPtr.Zero, IntPtr.Zero, 0x0001 | 0x0400 | 0x0080);
            } else if (!IsDisposed) Invalidate();
        }
    }
    private System.Drawing.Point dragStart, scrollStart;
    public event System.Windows.Forms.MouseEventHandler ZoomWheel;
    public WorkbenchImageCanvas() {
        SetStyle(System.Windows.Forms.ControlStyles.UserPaint | System.Windows.Forms.ControlStyles.AllPaintingInWmPaint |
            System.Windows.Forms.ControlStyles.OptimizedDoubleBuffer | System.Windows.Forms.ControlStyles.ResizeRedraw |
            System.Windows.Forms.ControlStyles.Selectable, true);
        AutoScroll = true; TabStop = true;
    }
    public double FitScale {
        get { return Image == null ? 1.0 : Math.Min(Math.Max(1,Width-20)/(double)Image.Width, Math.Max(1,Height-20)/(double)Image.Height); }
    }
    public double ImageScale { get { return Image == null ? 0.0 : imageSize.Width/(double)Image.Width; } }
    public System.Drawing.Rectangle ImageBounds {
        get { return new System.Drawing.Rectangle(Math.Max(0, (ClientSize.Width-imageSize.Width)/2)+AutoScrollPosition.X,
            Math.Max(0, (ClientSize.Height-imageSize.Height)/2)+AutoScrollPosition.Y, imageSize.Width, imageSize.Height); }
    }
    public void ApplyZoom(double factor, System.Drawing.Point anchor, bool keepAnchor) {
        UpdateView(delegate { ApplyZoomCore(factor, anchor, keepAnchor); });
    }
    private void ApplyZoomCore(double factor, System.Drawing.Point anchor, bool keepAnchor) {
        var before = ImageBounds;
        double x = before.Width > 0 ? (anchor.X-before.X)/(double)before.Width : 0.5;
        double y = before.Height > 0 ? (anchor.Y-before.Y)/(double)before.Height : 0.5;
        zoom = factor;
        if (Image == null) { imageSize = System.Drawing.Size.Empty; AutoScrollMinSize = imageSize; Invalidate(); return; }
        double fit = FitScale;
        imageSize = new System.Drawing.Size(Math.Max(1,(int)Math.Round(Image.Width*fit*zoom)), Math.Max(1,(int)Math.Round(Image.Height*fit*zoom)));
        AutoScrollMinSize = imageSize;
        // Refresh scroll limits before positioning the image beneath the cursor.
        PerformLayout();
        if (keepAnchor) AutoScrollPosition = new System.Drawing.Point(Math.Max(0,(int)Math.Round(x*imageSize.Width-anchor.X)), Math.Max(0,(int)Math.Round(y*imageSize.Height-anchor.Y)));
        Invalidate();
    }
    protected override void OnPaint(System.Windows.Forms.PaintEventArgs e) {
        if (Image != null) {
            e.Graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBilinear;
            e.Graphics.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
            e.Graphics.DrawImage(Image, ImageBounds);
        }
        base.OnPaint(e);
    }
    protected override void OnScroll(System.Windows.Forms.ScrollEventArgs se) { base.OnScroll(se); Invalidate(); }
    protected override void OnMouseDown(System.Windows.Forms.MouseEventArgs e) {
        if (e.Button == System.Windows.Forms.MouseButtons.Left) {
            dragging=false; pressed=Image != null;
            dragStart=e.Location; scrollStart=AutoScrollPosition;
            if (pressed) { Focus(); Capture=true; }
        }
        base.OnMouseDown(e);
    }
    protected override void OnMouseMove(System.Windows.Forms.MouseEventArgs e) {
        if (pressed && Capture && (imageSize.Width>ClientSize.Width || imageSize.Height>ClientSize.Height)) {
            int dx=e.X-dragStart.X, dy=e.Y-dragStart.Y;
            if (!dragging && (Math.Abs(dx)>=System.Windows.Forms.SystemInformation.DragSize.Width/2 || Math.Abs(dy)>=System.Windows.Forms.SystemInformation.DragSize.Height/2)) dragging=true;
            if (dragging) {
                Cursor=System.Windows.Forms.Cursors.SizeAll;
                UpdateView(delegate { AutoScrollPosition=new System.Drawing.Point(Math.Max(0,-scrollStart.X-dx),Math.Max(0,-scrollStart.Y-dy)); });
            }
        }
        base.OnMouseMove(e);
    }
    protected override void OnMouseUp(System.Windows.Forms.MouseEventArgs e) {
        if (e.Button == System.Windows.Forms.MouseButtons.Left) { pressed=false; Capture=false; Cursor=System.Windows.Forms.Cursors.Default; }
        base.OnMouseUp(e);
    }
    protected override void OnMouseCaptureChanged(EventArgs e) {
        if (!Capture) { pressed=false; Cursor=System.Windows.Forms.Cursors.Default; }
        base.OnMouseCaptureChanged(e);
    }
    protected override void OnMouseClick(System.Windows.Forms.MouseEventArgs e) {
        if (dragging) return;
        base.OnMouseClick(e);
    }
    protected override void OnMouseWheel(System.Windows.Forms.MouseEventArgs e) {
        // Wheel input is zoom only; skip ScrollableControl's separate scrolling pass.
        var handler = ZoomWheel; if (handler != null) handler(this,e);
    }
}
public class WorkbenchTabs : System.Windows.Forms.TabControl {
    // Clear ODS_FOCUS in reflected DRAWITEMSTRUCT; keep input focus and selection intact.
    protected override void WndProc(ref System.Windows.Forms.Message m) { if (m.Msg == 0x202B) Marshal.WriteInt32(m.LParam, 16, Marshal.ReadInt32(m.LParam, 16) & ~0x10); base.WndProc(ref m); }
}
'@ -ReferencedAssemblies System.Windows.Forms,System.Drawing
function Get-FolderPathKey([string]$path) {
    return [IO.Path]::GetFullPath($path).TrimEnd('\','/')
}
function Find-OpenFolderWindow([string]$folder) {
    $target=Get-FolderPathKey $folder
    $shell=$null; $windows=$null
    try {
        $shell=New-Object -ComObject Shell.Application
        $windows=$shell.Windows()
        for ($index=0; $index -lt $windows.Count; $index++) {
            $window=$null
            try {
                $window=$windows.Item($index)
                if ([IO.Path]::GetFileName($window.FullName) -ine 'explorer.exe') { continue }
                $candidate=Get-FolderPathKey ([string]$window.Document.Folder.Self.Path)
                if ([string]::Equals($target,$candidate,[StringComparison]::OrdinalIgnoreCase)) {
                    return [IntPtr]([long]$window.HWND)
                }
            } catch { continue }
            finally { if ($window) { $null=[Runtime.InteropServices.Marshal]::ReleaseComObject($window) } }
        }
    } catch { return [IntPtr]::Zero }
    finally {
        if ($windows) { $null=[Runtime.InteropServices.Marshal]::ReleaseComObject($windows) }
        if ($shell) { $null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    return [IntPtr]::Zero
}
function Open-WorkbenchFolder([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return }
    $handle=Find-OpenFolderWindow $folder
    if ($handle -ne [IntPtr]::Zero) {
        if ([WorkbenchFolderWindow]::IsIconic($handle)) { $null=[WorkbenchFolderWindow]::ShowWindowAsync($handle,9) }
        $null=[WorkbenchFolderWindow]::SetForegroundWindow($handle)
    } else {
        Start-Process explorer.exe -ArgumentList ('"'+$folder+'"')
    }
}

$openFolder.Add_Click({
    if ($script:lastFile) { $folder = Split-Path $script:lastFile -Parent } else { $folder = $output.Text }
    Open-WorkbenchFolder $folder
})
$preset.Add_SelectedIndexChanged({
    if ($mode.SelectedIndex -eq 0) {
        if ($preset.SelectedIndex -ge 0 -and $preset.SelectedIndex -lt $sizePresets.Count) {
            $choice = $sizePresets[$preset.SelectedIndex]
            $width.Value = $choice.Width; $height.Value = $choice.Height
        }
        $width.Enabled = $preset.SelectedIndex -eq $sizePresets.Count; $height.Enabled = $width.Enabled
    }
})
function Test-ImageModel {
    return ($model.SelectedIndex -ge 0 -and $models[$model.SelectedIndex].id -in @('qwen21','qwen21_turbo'))
}
function Apply-ModelDefaults {
    if ($model.SelectedIndex -lt 0) { return }
    $profile = $models[$model.SelectedIndex]
    $fixed = -not [string]::IsNullOrWhiteSpace([string]$profile.fixed_sigmas)
    $steps.Value = $(if ($mode.SelectedIndex -eq 1) {$profile.edit_steps} else {$profile.text_steps})
    $steps.Enabled = -not $fixed
    $cfg.Enabled = $true
    $cfg.Value = $(if ($mode.SelectedIndex -eq 1) {5} elseif ($profile.text_cfg) {[double]$profile.text_cfg} else {1})
    $stepsLabel.Text = $(if ($fixed) {'步数（Turbo 固定 8 步）'} else {'步数'})
}
$model.Add_SelectedIndexChanged({
    $canEdit=Test-ImageModel
    $mode.Enabled=$canEdit
    if (-not $canEdit -and $mode.SelectedIndex -eq 1) { $mode.SelectedIndex=0 }
    $modelLabel.Text=$(if ($canEdit) {'选择模型 · 支持文生图 / 图生图'} else {'选择模型 · 当前仅支持文生图'})
    Apply-ModelDefaults
})
$mode.Add_SelectedIndexChanged({
    if ($mode.SelectedIndex -eq 1 -and -not (Test-ImageModel)) {
        $mode.SelectedIndex=0
        $statusLabel.Text='当前模型仅支持文生图；图生图请选择 Qwen 标准版或 Turbo。'
        return
    }
    $editing = $mode.SelectedIndex -eq 1
    $imagePath.Enabled = $editing; $chooseImage.Enabled = $editing
    $refUsage.Enabled = $editing
    $refPreset.Enabled = $editing; $refElement.Enabled = $editing -and ($refUsage.SelectedIndex -eq 1)
    $batchCount.Enabled = $true
    $countLabel.Text = $(if ($editing) {'数量（每图）'} else {'数量（每段）'})
    $batchCount.Value = $(if ($editing) {1} else {$script:textCount})
    $preset.Items.Clear()
    if ($editing) {
        $preset.Items.AddRange(@('保留原图比例 · 轻量（512）','保留原图比例 · 标准（1024）','保留原图比例 · 精细（1536，显存需求较高）'))
        $preset.SelectedIndex = 1; $steps.Value = 40; $width.Enabled = $false; $height.Enabled = $false
    } else {
        foreach ($choice in $sizePresets) { $null = $preset.Items.Add($choice.Name) }
        $null = $preset.Items.Add('自定义尺寸')
        $preset.SelectedIndex = $defaultSizeIndex; $steps.Value = 25
    }
    Apply-ModelDefaults
    # 助手模式跟随工作台的生成方式
    if ($editing) {
        $referenceAssistantMode = $(if ($refUsage.SelectedIndex -eq 1) {3} else {2})
        if ($asMode.SelectedIndex -ne $referenceAssistantMode) { $asMode.SelectedIndex = $referenceAssistantMode }
    } else {
        $selectedAssistantMode = $asMode.SelectedIndex
    if ($selectedAssistantMode -ge 2) { $asMode.SelectedIndex = 0 }
    }
})
$mode.SelectedIndex = 0
$model.SelectedIndex = 0

function Split-PromptBlock([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $positive = $null; $negative = $null
    foreach ($line in ($text -split "`r?`n")) {
        $trim = $line.Trim()
        if (-not $positive -and $trim -match '^\[\d+\]\s*(.+)$') { $positive = $Matches[1].Trim(); continue }
        if ($trim -match '^NEG:\s*(.+)$') { $negative = $Matches[1].Trim() }
    }
    if (-not $positive) { return $null }
    return [pscustomobject]@{ Positive = $positive; Negative = $negative }
}
function Get-PromptSegments([string]$text) {
    return @($text -split "`r?`n\s*`r?`n" | Where-Object { $_.Trim() })
}
function Update-BatchSummary {
    $segments=@(Get-PromptSegments $prompt.Text).Count
    $editing=$mode.SelectedIndex -eq 1
    $units=$(if ($editing) {$script:referenceFiles.Count} else {[Math]::Max(1,$segments)})
    $total=[long]$units*[long]$batchCount.Value
    $description=$(if ($editing) {"$units 张参考图 × 每图 $($batchCount.Value) 张"} else {"$units 段提示词 × 每段 $($batchCount.Value) 张"})
    $batchSummary.Text="待提交：$description = $total 张（逐张排队）"
    if ($editing -and $segments -gt 1) { $batchSummary.Text='待提交：图生图只接受一段修改要求，请合并多段文字。' }
    $batchSummary.ForeColor=$(if ($editing -and $segments -gt 1) {[Drawing.Color]::Firebrick} else {[Drawing.Color]::FromArgb(82,100,122)})
}
function Get-RandomPresetConfig {
    foreach ($category in $script:randomPresetGroups) {
        $choices=@($fixedChoices | Where-Object { $_.Key.StartsWith($category+':') -and -not $_.Random -and $_.Text.Trim() } | ForEach-Object { $_.Text.Trim() } | Select-Object -Unique)
        if (-not $choices.Count) { throw ('每张随机的分类没有可用选项：'+$category) }
        [ordered]@{key=$category; choices=$choices}
    }
}
function Get-OutputCharacterPresets([string]$fixedText,$randomPresets) {
    $candidateText=(@($fixedText)+@($randomPresets | ForEach-Object { $_.choices })) -join "`r`n"
    if (Test-Path -LiteralPath $characterLibraryFile) {
        $library=Get-Content -LiteralPath $characterLibraryFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($gender in @($library.female,$library.male)) {
            foreach ($work in $gender.PSObject.Properties) {
                foreach ($role in $work.Value) {
                    if (Test-PromptFragment $candidateText ([string]$role.en)) { @{name=[string]$role.cn; text=[string]$role.en} }
                }
            }
        }
    }
    foreach ($choice in $fixedChoices) {
        if ($choice.Key -like 'character:*' -and -not $choice.Random -and (Test-PromptFragment $candidateText $choice.Text)) {
            @{name=($choice.Name -split ' · ',2)[-1]; text=$choice.Text}
        }
    }
}
function Get-Config {
    $seedValue = [long]0
    if (-not [long]::TryParse($seed.Text,[ref]$seedValue) -or $seedValue -lt -1) { throw '种子应为 -1 或非负整数。' }
    $randomPresets=@(Get-RandomPresetConfig)
    $finalNegative = $negPrompt.Text
    $fixedAppend = ''
    $fixedText = $fixedPrompt.Text.Trim()
    if ($fixedText) {
        $fixedBlock = Split-PromptBlock $fixedText
        if ($fixedBlock) {
            $fixedAppend = $fixedBlock.Positive
            if ($fixedBlock.Negative) { $finalNegative = $finalNegative.TrimEnd() + ', ' + $fixedBlock.Negative }
        } else {
            $fixedAppend = $fixedText
        }
    }
    # 先按空行拆多段：多段时不走 [编号] 块解析，避免第二段被当成 NEG 吞掉
    $rawSegments = @(Get-PromptSegments $prompt.Text)
    if (-not $rawSegments.Count) { $rawSegments = @($prompt.Text) }
    $cleanSegments = @($rawSegments | ForEach-Object { ($_.Trim() -replace '^\[\d+\]\s*', '') } | Where-Object { $_.Trim() })
    if ($cleanSegments.Count -gt 1) {
        $joined = @($cleanSegments | ForEach-Object { $s = $_.Trim(); $(if ($fixedAppend) { if ($s) { $s + ', ' + $fixedAppend } else { $fixedAppend } } else { $s }) })
        $prompts = $joined
        $finalPrompt = $joined[0]
    } else {
        $block = Split-PromptBlock $prompt.Text
        $finalPrompt = $(if ($block) { $block.Positive } else { $prompt.Text })
        if ($block -and $block.Negative) { $finalNegative = $block.Negative }
        $joined = @(@($finalPrompt) | ForEach-Object { $s = $_.Trim(); $(if ($fixedAppend) { if ($s) { $s + ', ' + $fixedAppend } else { $fixedAppend } } else { $s }) })
        $prompts = $null
        $finalPrompt = $joined[0]
    }
    if ([string]::IsNullOrWhiteSpace($finalPrompt) -and -not $randomPresets.Count) { throw '请填写预设或提示词，至少一处需要有内容。' }
    if ([string]::IsNullOrWhiteSpace($output.Text) -or -not [System.IO.Path]::IsPathRooted($output.Text)) { throw '请选择完整的输出文件夹路径。' }
    $editing = $mode.SelectedIndex -eq 1
    if ($editing -and $cleanSegments.Count -gt 1) { throw '图生图请合并为一段修改要求；多张参考图将使用同一段要求。' }
    if ($editing) {
        if ($models[$model.SelectedIndex].id -notin @('qwen21','qwen21_turbo')) { throw '当前模型尚未接入图片输入，请选择 Qwen 标准版或 Turbo。' }
        if (-not $script:referenceFiles.Count) { throw '请先选择参考图片。' }
        foreach ($file in $script:referenceFiles) { if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw ('参考图片不存在：'+$file) } }
    }
    $resolution = 1024
    if ($editing) { $resolution = @(512,1024,1536)[$preset.SelectedIndex] }
    return [ordered]@{
        model = $models[$model.SelectedIndex].id; mode = $(if ($editing) {'edit'} else {'text'}); prompt = $finalPrompt; prompts = $prompts; image = $(if ($script:referenceFiles.Count) {$script:referenceFiles[0]} else {''}); images = @($script:referenceFiles); count = [int]$batchCount.Value
        width = [int]$width.Value; height = [int]$height.Value; resolution = $resolution
        ref_mode = $(if ($editing -and ($refUsage.SelectedIndex -eq 1)) { 'feature' } else { 'structure' }); ref_preset = $(if ($refUsage.SelectedIndex -eq 1) { @('free','balanced','close')[$refPreset.SelectedIndex] } else { @('subtle','normal','redraw')[$refPreset.SelectedIndex] }); ref_element = @('character','pose','style','all')[$refElement.SelectedIndex]; reference_count = [int]$batchCount.Value
        steps = [int]$steps.Value; seed = $seedValue; cfg = [double]$cfg.Value; negative_prompt = $finalNegative; random_presets=$randomPresets; output_characters=@(Get-OutputCharacterPresets $fixedAppend $randomPresets); output = $output.Text
    }
}
function Write-SettingsFile([string]$path,$settings) {
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($settings | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,$path) }
    } catch { throw ('设置未保存：'+$_.Exception.Message) }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Save-Settings {
    $settings = @{model=$models[$model.SelectedIndex].id;prompt=$prompt.Text; output=$output.Text; image=$(if ($script:referenceFiles.Count) {$script:referenceFiles[0]} else {''}); images=@($script:referenceFiles); count=$script:textCount; referenceCount=[int]$batchCount.Value; refUsage=$refUsage.SelectedIndex; refPreset=$refPreset.SelectedIndex; refElement=$refElement.SelectedIndex; seed=$seed.Text; fixedPrompt=$fixedPrompt.Text; negPrompt=$negPrompt.Text; presetStyleIndex=$presetStyle.SelectedIndex; presetCharacterIndex=$presetCharacter.SelectedIndex; presetExpressionIndex=$presetExpression.SelectedIndex; fixedPresetVersion=3; randomPresetGroups=@($script:randomPresetGroups); selectedFixedKeys=@($script:selectedFixedKeys); fixedAppliedTexts=$script:fixedAppliedTexts; negPresetIndex=$negPreset.SelectedIndex; mode=$mode.SelectedIndex; sizePreset=$preset.SelectedIndex; width=[int]$width.Value; height=[int]$height.Value; steps=[int]$steps.Value; cfg=[double]$cfg.Value}
    Write-SettingsFile $settingsFile $settings
}
function Restore-Settings($saved) {
    try {
        $script:suppressRefresh = $true
        for ($index=0; $index -lt $models.Count; $index++) { if ($models[$index].id -eq $saved.model) { $model.SelectedIndex=$index; break } }
        if ($null -ne $saved.mode -and [int]$saved.mode -in 0,1) { $mode.SelectedIndex = [int]$saved.mode }
        if ($null -ne $saved.sizePreset -and [int]$saved.sizePreset -ge 0 -and [int]$saved.sizePreset -lt $preset.Items.Count) { $preset.SelectedIndex = [int]$saved.sizePreset }
        $prompt.Text = $saved.prompt; $output.Text = $saved.output; $seed.Text = $saved.seed
        if ($saved.images) { $script:referenceFiles=@($saved.images) } elseif ($saved.image) { $script:referenceFiles=@($saved.image) }
        $imagePath.Text = $(if ($script:referenceFiles.Count -gt 1) {'已选 '+$script:referenceFiles.Count+' 张 · '+$script:referenceFiles[0]} elseif ($script:referenceFiles.Count) {$script:referenceFiles[0]} else {''})
        if ($saved.count -ge 1 -and $saved.count -le $batchCount.Maximum) { $script:textCount=[int]$saved.count }
        $restoredCount = $(if ($mode.SelectedIndex -eq 1 -and $saved.referenceCount) {$saved.referenceCount} else {$script:textCount})
        if ($restoredCount -ge 1 -and $restoredCount -le $batchCount.Maximum) { $batchCount.Value=[int]$restoredCount }
        if ($saved.fixedPresetVersion -in 2,3) {
            if ($null -ne $saved.presetStyleIndex -and [int]$saved.presetStyleIndex -in 0,1,2,3) { $presetStyle.SelectedIndex = [int]$saved.presetStyleIndex }
            if ($null -ne $saved.presetCharacterIndex -and [int]$saved.presetCharacterIndex -in 0,1,2) { $presetCharacter.SelectedIndex = [int]$saved.presetCharacterIndex }
        } elseif ($null -ne $saved.presetStyleIndex) {
            $legacyIndex = [int]$saved.presetStyleIndex
            if ($legacyIndex -in 4,5,6) {
                $presetStyle.SelectedIndex = 1
                $presetCharacter.SelectedIndex = $(if ($legacyIndex -eq 6) {2} else {1})
            } elseif ($legacyIndex -in 0,1,2,3) { $presetStyle.SelectedIndex = $legacyIndex }
        }
        if ($null -ne $saved.presetExpressionIndex -and [int]$saved.presetExpressionIndex -ge 0 -and [int]$saved.presetExpressionIndex -lt $presetExpression.Items.Count) { $presetExpression.SelectedIndex = [int]$saved.presetExpressionIndex }
        if ($null -ne $saved.fixedPrompt) { $fixedPrompt.Text = [string]$saved.fixedPrompt }
        if ($null -ne $saved.width) { $width.Value = [int]$saved.width }
        if ($null -ne $saved.height) { $height.Value = [int]$saved.height }
        if ($null -ne $saved.steps) { $steps.Value = [int]$saved.steps }
        if ($null -ne $saved.cfg) { $cfg.Value = [decimal]$saved.cfg }
        if ($null -ne $saved.negPresetIndex -and [int]$saved.negPresetIndex -ge 0 -and [int]$saved.negPresetIndex -lt $negPreset.Items.Count) { $negPreset.SelectedIndex = [int]$saved.negPresetIndex }
        if ($null -ne $saved.negPrompt) { $negPrompt.Text = [string]$saved.negPrompt }
        if ($null -ne $saved.refUsage -and [int]$saved.refUsage -in 0,1) { $refUsage.SelectedIndex = [int]$saved.refUsage }
        if ($null -ne $saved.refPreset -and [int]$saved.refPreset -in 0,1,2) { $refPreset.SelectedIndex = [int]$saved.refPreset }
        if ($null -ne $saved.refElement -and [int]$saved.refElement -in 0,1,2,3) { $refElement.SelectedIndex = [int]$saved.refElement }

    } finally { $script:suppressRefresh = $false }
}
if (Test-Path -LiteralPath $settingsFile) {
    try {
        $saved = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Restore-Settings $saved
    } catch { [System.Windows.Forms.MessageBox]::Show($form,('读取设置失败：'+$_.Exception.Message),'设置读取失败','OK','Warning') | Out-Null }
}
function New-QueueTask($config) {
    $json=$config | ConvertTo-Json -Depth 12
    $snapshot=$json | ConvertFrom-Json
    $script:queueSequence++
    $segments=$(if($snapshot.mode -eq 'edit'){@($snapshot.images).Count}else{@($snapshot.prompts).Count})
    $total=[long]$snapshot.count*[Math]::Max(1,$segments)
    $modelName=@($models | Where-Object { $_.id -eq $snapshot.model })[0].name
    $summary=[regex]::Replace([string]$snapshot.prompt,'\s+',' ').Trim()
    $summary=$summary.Substring(0,[Math]::Min(60,$summary.Length))
    $entry=[pscustomobject]@{Number=$script:queueSequence; Status='waiting'; Model=$modelName; Total=$total; Summary=$summary; Output=[string]$snapshot.output; ConfigJson=[string]$json; Source='人工'; AgentJobId=$null}
    $script:queueItems.Add($entry)
    return $entry
}
function Update-QueueUi {
    if ($script:agentLock) { Publish-AgentQueueStates }
    $waiting=@($script:queueItems | Where-Object { $_.Status -eq 'waiting' }).Count
    $manageQueue.Text='任务队列'
    $queueStatus.Text='队列：待执行 '+$waiting+' 项 · '+$(if($script:queuePaused){'已暂停'}else{'自动执行'})+$(if($script:currentQueueTask){' · 当前任务 '+$script:currentQueueTask.Number}else{''})
    if (-not $script:queueDialog -or $script:queueDialog.IsDisposed) { return }
    $list=$script:queueDialog.Tag.List
    $selected=$(if($list.SelectedItems.Count){$list.SelectedItems[0].Tag}else{$null})
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        $labels=@{waiting='等待';running='执行中';done='已完成';error='失败';cancelled='已停止'}
        foreach ($entry in $script:queueItems) {
            $row=New-Object Windows.Forms.ListViewItem([string]$entry.Number)
            foreach ($value in @($labels[$entry.Status],$entry.Source,$entry.Model,[string]$entry.Total,$entry.Summary,$entry.Output)) { $null=$row.SubItems.Add([string]$value) }
            $row.Tag=$entry; $null=$list.Items.Add($row)
            if ($selected -eq $entry) { $row.Selected=$true }
        }
    } finally { $list.EndUpdate() }
    $script:queueDialog.Tag.Pause.Text=$(if($script:queuePaused){'继续队列'}else{'暂停队列'})
}
function Start-WorkbenchTask($entry) {
    if ($script:worker -or $script:assistantBusy) { throw '请等待当前任务结束。' }
    $job=Join-Path $AppDirectory ('jobs\'+$(if($entry.AgentJobId){$entry.AgentJobId}else{[guid]::NewGuid().ToString('N')}))
    $null=New-Item -ItemType Directory -Path $job -Force
    $request=Join-Path $job 'request.json'
    [IO.File]::WriteAllText($request,$entry.ConfigJson,[Text.UTF8Encoding]::new($false))
    $process=Start-Process -FilePath $python -ArgumentList @('-s','-u',('"'+$workerFile+'"'),('"'+$request+'"')) -WorkingDirectory $AppDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $job 'worker.stdout.log') -RedirectStandardError (Join-Path $job 'worker.stderr.log') -PassThru
    $script:job=$job; $script:worker=$process; $script:currentQueueTask=$entry; $entry.Status='running'
    $script:seenGeneratedFiles=@{}; $script:previewingReference=$false
    $script:started=Get-Date; $script:stopped=$false
    Set-GenerationBusy $true; $progress.Value=0
    $statusLabel.Text=$entry.Source+' · 任务 '+$entry.Number+' · 正在连接生图引擎…'
    Update-QueueUi; $timer.Start()
}
function Start-NextQueuedTask {
    if ($script:worker -or $script:assistantBusy -or $script:queuePaused -or $IntegrationTest) { return }
    $entry=$script:queueItems | Where-Object { $_.Status -eq 'waiting' } | Select-Object -First 1
    if (-not $entry) { $timer.Stop(); return }
    try { Start-WorkbenchTask $entry }
    catch { $entry.Status='error'; $script:queuePaused=$true; $statusLabel.Text='队列启动失败：'+$_.Exception.Message; Update-QueueUi; $timer.Stop() }
}
function Add-QueuedTask($config) {
    $entry=New-QueueTask $config
    Update-QueueUi; $timer.Start(); Start-NextQueuedTask
    return $entry
}
function Complete-QueuedTask([string]$state) {
    if ($script:currentQueueTask) { $script:currentQueueTask.Status=$state; $script:currentQueueTask=$null }
    if ($state -ne 'done') { $script:queuePaused=$true }
    Update-QueueUi
    if (-not $IntegrationTest) { $timer.Start(); Start-NextQueuedTask }
}
function Move-QueuedTask($entry,[int]$direction) {
    if (-not $entry -or $entry.Status -ne 'waiting') { return }
    $waiting=@($script:queueItems | Where-Object { $_.Status -eq 'waiting' })
    $position=[Array]::IndexOf($waiting,$entry)
    $target=$position+$direction
    if ($target -lt 0 -or $target -ge $waiting.Count) { return }
    $from=$script:queueItems.IndexOf($entry); $to=$script:queueItems.IndexOf($waiting[$target])
    $script:queueItems.RemoveAt($from); $script:queueItems.Insert($to,$entry)
    Update-QueueUi
}
function Show-TaskQueue {
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='任务队列'; $dialog.Font=$form.Font; $dialog.Icon=$form.Icon; $dialog.StartPosition='CenterParent'
    $dialog.ClientSize=New-Object Drawing.Size(920,450); $dialog.MinimumSize=New-Object Drawing.Size(760,360)
    $list=New-Object Windows.Forms.ListView
    $list.SetBounds(12,12,896,354); $list.Anchor='Top,Bottom,Left,Right'; $list.View='Details'; $list.FullRowSelect=$true; $list.MultiSelect=$false; $list.HideSelection=$false
    foreach ($column in @(@('编号',50),@('状态',70),@('来源',80),@('模型',180),@('张数',60),@('内容',260),@('输出文件夹',260))) { $null=$list.Columns.Add($column[0],$column[1]) }
    $dialog.Controls.Add($list)
    $pause=Add-Button $dialog '暂停队列' 12 378 110
    $up=Add-Button $dialog '上移' 132 378 70; $down=Add-Button $dialog '下移' 212 378 70
    $remove=Add-Button $dialog '移除' 292 378 80; $clear=Add-Button $dialog '清空待执行' 382 378 120
    foreach ($button in @($pause,$up,$down,$remove,$clear)) { $button.Anchor='Bottom,Left' }
    $hint=New-Object Windows.Forms.Label
    $hint.Text='暂停不打断当前任务；停止会终止当前任务。队列仅本次窗口有效。'
    $hint.Location=New-Object Drawing.Point(12,420); $hint.AutoSize=$true; $hint.Anchor='Bottom,Left'; $dialog.Controls.Add($hint)
    $dialog.Tag=@{List=$list; Pause=$pause}
    $pause.Add_Click({ $script:queuePaused=-not $script:queuePaused; Update-QueueUi; if (-not $script:queuePaused) { $timer.Start(); Start-NextQueuedTask } })
    $up.Add_Click({ if ($list.SelectedItems.Count) { Move-QueuedTask $list.SelectedItems[0].Tag -1 } })
    $down.Add_Click({ if ($list.SelectedItems.Count) { Move-QueuedTask $list.SelectedItems[0].Tag 1 } })
    $remove.Add_Click({ if ($list.SelectedItems.Count -and $list.SelectedItems[0].Tag.Status -eq 'waiting') { $null=$script:queueItems.Remove($list.SelectedItems[0].Tag); Update-QueueUi } })
    $clear.Add_Click({ foreach ($entry in @($script:queueItems | Where-Object { $_.Status -eq 'waiting' })) { $null=$script:queueItems.Remove($entry) }; Update-QueueUi })
    $script:queueDialog=$dialog
    try { Update-QueueUi; $null=$dialog.ShowDialog($form) } finally { $script:queueDialog=$null; $dialog.Dispose() }
}

function Set-GenerationBusy([bool]$busy) {
    $inputs.Enabled = $true; $model.Enabled = $true
    $asMode.Enabled = $true; $asFill.Enabled = $true
    $generate.Enabled = -not ($busy -or $script:assistantBusy)
    $generate.Text = $(if ($busy) {'正在生成…'} else {'开始生成'})
    $stop.Enabled = $busy
    $btnRefresh.Enabled = -not ($busy -or $script:assistantBusy)
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    if (-not $script:worker) { Start-NextQueuedTask; return }
    $seconds = [int]((Get-Date) - $script:started).TotalSeconds
    $elapsed.Text = "已用 $seconds 秒 · 当前使用提交时配置；修改仅用于下次生成。"
    $status = $null
    try { $status = Get-Content -LiteralPath (Join-Path $script:job 'status.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if ($script:worker.HasExited -and (-not $status -or $status.state -notin @('done','error','cancelled'))) {
        try { $status=Get-Content -LiteralPath (Join-Path $script:job 'status.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    if ($status) {
        $statusLabel.Text = $(if ($script:stopped -and $status.state -eq 'running') {'正在终止当前任务，等待引擎确认…'} else {$status.message})
        if ($status.outputs) { Add-ResultFiles @($status.outputs | ForEach-Object { $_.output }) }
        elseif ($status.output) { Add-ResultFiles @($status.output) }
        $progress.Value = [Math]::Max(0,[Math]::Min(100,[int]$status.progress))
        if ($status.state -in @('done','error','cancelled')) {
            $timer.Stop(); Set-GenerationBusy $false
            if ($status.state -eq 'done') {
                Add-ResultFiles @($status.outputs | ForEach-Object { $_.output })
                $openImage.Enabled = $true; $openFolder.Enabled = $true
                $elapsed.Text = "完成 $($status.completed) 张 · 用时 $seconds 秒 · 最后一张种子 $($status.seed)"
            } elseif ($status.state -eq 'cancelled') {
                $elapsed.Text = '已终止 · 用时 ' + $seconds + ' 秒 · 已完成图片已保留。'
                $script:stopped = $false
            } else {
                $elapsed.Text = '生成未完成，可调整后重试。'
                if (-not $IntegrationTest -and -not $SelfTest) { [System.Windows.Forms.MessageBox]::Show($form,$status.message,'生成失败','OK','Error') | Out-Null }
            }
            $script:worker.Dispose(); $script:worker = $null
            Complete-QueuedTask $status.state
            if ($IntegrationTest) {
                $script:integrationPassed = $status.state -eq 'done'
                if ($ScreenshotPath -and $script:integrationPassed) {
                    [System.Windows.Forms.Application]::DoEvents()
                    $snapshot = New-Object System.Drawing.Bitmap($form.Width,$form.Height)
                    $form.DrawToBitmap($snapshot,(New-Object System.Drawing.Rectangle(0,0,$form.Width,$form.Height)))
                    $snapshot.Save($ScreenshotPath,[System.Drawing.Imaging.ImageFormat]::Png); $snapshot.Dispose()
                }
                $form.Close()
            }
        }
    }
    if ($script:worker -and $script:worker.HasExited) {
        $wasStopped=$script:stopped
        $timer.Stop(); Set-GenerationBusy $false
        if ($script:stopped) {
            $script:stopped = $false
            $statusLabel.Text = '已手动停止（当前这张未保存）。'
            $elapsed.Text = '已停止 · 用时 ' + $seconds + ' 秒'
        } else {
            $statusLabel.Text = '任务异常退出，请查看任务日志。'
            [System.Windows.Forms.MessageBox]::Show($form,('任务未能完成，日志位于：' + (Join-Path $script:job 'worker.stderr.log')),'运行错误','OK','Error') | Out-Null
        }
        $script:worker.Dispose(); $script:worker = $null
            Complete-QueuedTask $(if($wasStopped){'cancelled'}else{'error'})
            if ($IntegrationTest) {
                $script:integrationPassed = $status.state -eq 'done'
                if ($ScreenshotPath -and $script:integrationPassed) {
                    [System.Windows.Forms.Application]::DoEvents()
                    $snapshot = New-Object System.Drawing.Bitmap($form.Width,$form.Height)
                    $form.DrawToBitmap($snapshot,(New-Object System.Drawing.Rectangle(0,0,$form.Width,$form.Height)))
                    $snapshot.Save($ScreenshotPath,[System.Drawing.Imaging.ImageFormat]::Png); $snapshot.Dispose()
                }
                $form.Close()
            }
    }
})
$generate.Add_Click({
    if ($script:worker -or $script:assistantBusy) { return }
    $entry=$null
    try {
        $config=Get-Config
        if (-not $IntegrationTest) { Save-Settings }
        $entry=New-QueueTask $config
        Start-WorkbenchTask $entry
    } catch {
        if ($entry) { $entry.Status='error'; $script:queuePaused=$true; Update-QueueUi }
        [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'请检查输入','OK','Warning') | Out-Null
    }
})
$addQueue.Add_Click({
    try { $config=Get-Config; Save-Settings; $null=Add-QueuedTask $config }
    catch { [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'无法加入队列','OK','Warning') | Out-Null }
})
$manageQueue.Add_Click({ Show-TaskQueue })
Update-QueueUi
$stop.Add_Click({
    if (-not $script:worker -or $script:worker.HasExited -or $script:stopped) { return }
    try {
        [IO.File]::WriteAllText((Join-Path $script:job 'stop'), '')
        $script:queuePaused=$true; Update-QueueUi
        $script:stopped = $true
        $stop.Enabled = $false
        $statusLabel.Text = '正在终止当前任务，等待引擎确认…'
    } catch { $statusLabel.Text = '无法发送停止请求：' + $_.Exception.Message }
})
$form.Add_FormClosing({
    param($sender,$eventArgs)
    $pending=@($script:queueItems | Where-Object { $_.Status -eq 'waiting' }).Count
    if (($script:worker -and -not $script:worker.HasExited) -or $pending) {
        $message='关闭工作台后，已经开始的生成任务会继续保存图片。'
        if ($pending) { $message+="`n尚有 $pending 个待执行任务，关闭后不会执行，队列也不会保留。" }
        $answer=[Windows.Forms.MessageBox]::Show($form,($message+"`n是否关闭？"),'任务队列','YesNo','Question')
        if ($answer -ne 'Yes') { $eventArgs.Cancel=$true; return }
    }
    if (-not $IntegrationTest -and -not $SelfTest) {
        try { Save-Settings }
        catch { $eventArgs.Cancel=$true; [System.Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'设置保存失败','OK','Warning') | Out-Null }
    }
})

$tip = New-Object System.Windows.Forms.ToolTip
$tip.InitialDelay = 500
$tip.ReshowDelay = 500
$tip.AutoPopDelay = 30000
$tip.ShowAlways = $true
$tip.SetToolTip($presetStyle, '画风与人物共用下方输入框，生成时追加到每段提示词。切换只替换对应的完整预设片段；手动改写过的内容会保留。')
$tip.SetToolTip($presetCharacter, '只切换人物描述，保留画风和补充内容。选择不使用可移除对应的完整预设片段。')

$tip.SetToolTip($refUsage, '修改原图：按要求改动现有图片。参考元素：以文字为主重新生成。当前仅 Qwen 模型支持图片输入。')
$tip.SetToolTip($refPreset, '档位从小到大表示修改幅度或参考程度；下方说明会随选择变化。')
$tip.SetToolTip($refElement, '选择希望借鉴的元素，通过模型指令表达，不保证人物身份或姿态精确一致。')
$helpItems = @(
    @{Name='选择模型'; Controls=@($model); Text="决定使用哪一个已部署模型。`n标准版：默认文生图 25 步、图生图 40 步，可花更多时间细化。`nTurbo：使用官方固定 8 步，适合快速试图。`n切换模型会自动更新步数和引导强度。"},
    @{Name='生成方式'; Controls=@($mode); Text="文生图：根据文字生成新图片，不需要参考图。`n图生图：根据参考图片和修改要求生成结果。`n编辑时请同时说明「要改什么」和「要保留什么」。"},
    @{Name='提示词'; Controls=@($prompt); Text="描述主体、场景、构图、风格、光线，以及需要出现的文字。`n建议先写清楚主要内容，再补充细节；中英文都可以输入。`n文生图时可以用空行分隔多段提示词：每段各生成「数量」张，图片按目标文件夹中的最大数字编号接续保存，如 1.png、2.png、3.png。`n图生图示例：屋顶和石阶覆盖厚雪，保留建筑与视角。"},
    @{Name='参考图片'; Controls=@($imagePath,$chooseImage); Text="可从文件夹拖入一张或多张图片到预览区或参考图片栏。`n拖入后自动切换到图生图模式，不会移动原文件。`n建议选择清晰、主体完整的 PNG 或 JPG。`n多张图会使用同一修改要求逐张处理；每张保留自己的比例。"},
    @{Name='画面尺寸'; Controls=@($preset); Text="文生图：列表按总像素数从小到大排列，自定义放在最后。`n推荐 1024×1024；16:9 可选 1024×576 或 1536×864。`n近 1080p 使用 1920×1088，以满足 32 倍数要求。`n图生图：保留原图比例，512 为轻量，1024 为推荐档。`n1536 档和更大尺寸更耗显存，12GB 显存先用 1024。"},
    @{Name='宽'; Controls=@($width); Text="图片水平方向的像素数，只在文生图「自定义尺寸」中可改。`n范围 256～2048，必须是 32 的倍数。`n建议先用 1024；像素总量越大，生成越慢、显存占用越高。`n图生图由参考图比例和所选清晰度决定尺寸。"},
    @{Name='高'; Controls=@($height); Text="图片垂直方向的像素数，只在文生图「自定义尺寸」中可改。`n范围 256～2048，必须是 32 的倍数。`n宽小于高是竖图；宽大于高是横图。`n推荐方图 1024×1024，竖图 832×1216。"},
    @{Name='步数'; Controls=@($steps); Text="控制生成时迭代计算的次数，增加通常更慢，不保证效果更好。`n标准版文生图：25 步先看效果，复杂画面可试 40 步。`n标准版图生图：推荐 40 步。`nTurbo：必须使用专用 8 步时间表，因此固定为 8，不可调。"},
    @{Name='引导强度'; Controls=@($cfg); Text="控制提示词约束的强度。`n文生图默认 1；图生图（编辑/特征参考）建议 5，否则提示词容易被参考图完全压住、几乎不起作用。`n过高可能让画面色彩偏艳，可在 4～6 之间微调。`nTurbo 的 8 步不变，但引导强度可以调。"},
    @{Name='数量'; Controls=@($batchCount); Text="文生图：每段提示词的生成数量，填写正整数，默认 1 张。`n多段提示词（用空行分隔）时，每段各生成这个数量。`n总张数 = 提示词段数 × 每段数量，任务逐张执行，可随时停止。`n图片统一按目标文件夹中的最大数字编号接续保存。`n图生图：每张参考图各生成这个数量，任务逐张执行。种子 -1 时逐张随机抽卡。"},
    @{Name='种子(-1 随机)'; Controls=@($seed,$random); Text="决定生成时使用的随机起点。`n-1：每次随机，适合探索不同画面；右侧「随机」也是设为 -1。`n固定整数（例如 42）：批量时从此数依次递增，得到不同图片。`n复现时还需保持模型、尺寸、步数等设置一致。"},
    @{Name='输出文件夹'; Controls=@($output,$chooseOutput); Text="选择生成图片最终保存到哪里，也可以直接输入完整路径。`n不存在的文件夹会自动创建。`n建议选择空间充足的本地文件夹。`n普通图片按数字编号；使用角色预设时按「角色名_编号」保存，各角色独立从最大编号加 1，不覆盖旧图片；此位置会自动记住。"}
)
$helpLabels = @($inputs.Controls | Where-Object {$_ -is [System.Windows.Forms.Label]}) + @($modelLabel)
foreach ($item in $helpItems) {
    foreach ($label in $helpLabels) {
        if ($label.Text.StartsWith($item.Name)) { $tip.SetToolTip($label,$item.Text) }
    }
    foreach ($control in $item.Controls) { $tip.SetToolTip($control,$item.Text) }
}


$left.Width = 500
$left.AutoScroll = $false
$inputs.Dock = 'Fill'
$tabs = New-Object WorkbenchTabs
$tabs.Dock = 'Fill'; $tabs.Padding = New-Object System.Drawing.Point(16,9)
$creationPage = New-Object System.Windows.Forms.TabPage
$creationPage.Text = '提示词'; $creationPage.AutoScroll = $true; $creationPage.BackColor = [System.Drawing.Color]::White
$optionsPage = New-Object System.Windows.Forms.TabPage
$optionsPage.Text = '参数与保存'; $optionsPage.AutoScroll = $true; $optionsPage.BackColor = [System.Drawing.Color]::White
foreach ($control in @($inputs.Controls)) {
    $y = $control.Top
    if ($y -lt 132) { $optionsPage.Controls.Add($control) }
    elseif ($y -ge 558) { $optionsPage.Controls.Add($control); $control.Top = $y - 250 }
    elseif ($y -ge 430) { $optionsPage.Controls.Add($control); $control.Top = $y - 280 }
    else {
        $creationPage.Controls.Add($control)
        if ($y -le 174) { $control.Top = $y - 120 }
        elseif ($y -le 278) { $control.Top = $y - 40 }
        elseif ($y -le 342) { $control.Top = $y - 10 }
        elseif ($y -le 414) { $control.Top = $y + 20 }
        else { $control.Top = $y + 62 }
    }
}
$prompt.Top = 54; $prompt.Height = 150
$fixedPrompt.Top = 258; $fixedPrompt.Height = $prompt.Height
$presetStyle.Top = 222; $presetStyle.Left = 116; $presetStyle.Width = 104; $presetStyle.DropDownWidth = 180; $presetCharacter.Left = 232; $presetCharacter.Width = 104; $presetCharacter.Top = 222; $presetExpression.Left = 348; $presetExpression.Width = 104; $presetExpression.Top = 222
$negPrompt.Top = 462; $negPrompt.Height = $prompt.Height
$negPreset.Top = 426; $negPreset.Left = 260; $negPreset.Width = 192
foreach ($label in $creationPage.Controls) {
    if ($label -isnot [System.Windows.Forms.Label]) { continue }
    if ($label.Text -like '提示词 / 修改要求*') { $label.Top = 22 }
    elseif ($label.Text -like '固定片段*') { $label.Top = 226 }
    elseif ($label.Text -like '负面提示词*') { $label.Top = 430 }
}
$fixedExtraGroups = @(
    @{Key='count'; Name='人数'; Items=@(
        @{Label='单人'; Text='1girl, solo'},
        @{Label='双人'; Text='2girls'},
        @{Label='三人'; Text='3girls'},
        @{Label='多人'; Text='multiple girls'},
        @{Label='群像'; Text='group'},
        @{Label='男女'; Text='1girl, 1boy'},
        @{Label='百合'; Text='yuri, 2girls'},
        @{Label='后宫'; Text='harem, multiple girls, 1boy'}
    )},
    @{Key='haircolor'; Name='发色'; Items=@(
        @{Label='黑发'; Text='black hair'},
        @{Label='棕发'; Text='brown hair'},
        @{Label='金发'; Text='blonde hair'},
        @{Label='白发'; Text='white hair'},
        @{Label='银发'; Text='silver hair'},
        @{Label='红发'; Text='red hair'},
        @{Label='粉发'; Text='pink hair'},
        @{Label='紫发'; Text='purple hair'},
        @{Label='蓝发'; Text='blue hair'},
        @{Label='绿发'; Text='green hair'},
        @{Label='橙发'; Text='orange hair'},
        @{Label='渐变发'; Text='gradient hair'}
    )},
    @{Key='hairstyle'; Name='发型'; Items=@(
        @{Label='长发'; Text='long hair'},
        @{Label='短发'; Text='short hair'},
        @{Label='中长发'; Text='medium hair'},
        @{Label='双马尾'; Text='twintails'},
        @{Label='马尾'; Text='ponytail'},
        @{Label='丸子头'; Text='hair bun'},
        @{Label='麻花辫'; Text='braid'},
        @{Label='卷发'; Text='wavy hair, curly hair'},
        @{Label='直发'; Text='straight hair'},
        @{Label='齐刘海'; Text='blunt bangs'},
        @{Label='空气刘海'; Text='see-through bangs'}
    )},
    @{Key='eyecolor'; Name='瞳色'; Items=@(
        @{Label='红瞳'; Text='red eyes'},
        @{Label='蓝瞳'; Text='blue eyes'},
        @{Label='绿瞳'; Text='green eyes'},
        @{Label='紫瞳'; Text='purple eyes'},
        @{Label='金瞳'; Text='yellow eyes'},
        @{Label='异色瞳'; Text='heterochromia'},
        @{Label='渐变瞳'; Text='gradient eyes'}
    )},
    @{Key='pose'; Name='姿势'; Items=@(
        @{Label='站立'; Text='standing'},
        @{Label='坐着'; Text='sitting'},
        @{Label='躺着'; Text='lying, on back'},
        @{Label='跪着'; Text='kneeling'},
        @{Label='趴着'; Text='on stomach'},
        @{Label='蹲着'; Text='squatting'},
        @{Label='叉腰'; Text='hand on hip'},
        @{Label='抱臂'; Text='crossed arms'},
        @{Label='回头'; Text='looking back'},
        @{Label='伸展'; Text='stretching'}
    )},
    @{Key='scene'; Name='场景'; Items=@(
        @{Label='室内'; Text='indoors'},
        @{Label='室外'; Text='outdoors'},
        @{Label='白背景'; Text='white background, simple background'},
        @{Label='床上'; Text='on bed'},
        @{Label='浴室'; Text='bathroom, shower'},
        @{Label='海滩'; Text='beach, ocean'},
        @{Label='森林'; Text='forest, trees'},
        @{Label='城市'; Text='city, street'},
        @{Label='教室'; Text='classroom'},
        @{Label='夜空'; Text='night sky, starry sky'}
    )},
    @{Key='lighting'; Name='光线镜头'; Items=@(
        @{Label='逆光'; Text='backlighting'},
        @{Label='侧光'; Text='side lighting'},
        @{Label='柔光'; Text='soft lighting'},
        @{Label='霓虹'; Text='neon lights'},
        @{Label='烛光'; Text='candlelight'},
        @{Label='日落'; Text='sunset'},
        @{Label='黄金时刻'; Text='golden hour'},
        @{Label='电影光'; Text='cinematic lighting'},
        @{Label='景深'; Text='depth of field, blurry background'},
        @{Label='广角'; Text='wide angle'},
        @{Label='长焦'; Text='telephoto'}
    )},
    @{Key='body'; Name='体型'; Items=@(
        @{Label='熟女'; Text='adult woman, mature appearance'},
        @{Label='筋肉'; Text='muscular, toned, abs, strong'},
        @{Label='丰满'; Text='curvy, thick thighs, wide hips'},
        @{Label='纤细'; Text='slim, slender, thin'},
        @{Label='高挑'; Text='tall, long legs'},
        @{Label='微胖'; Text='chubby, plump, soft body'},
        @{Label='肌肉女'; Text='muscular female, abs, toned'},
        @{Label='兽人'; Text='kemonomimi, animal ears, fangs'},
        @{Label='鳞片'; Text='scales, dragon tail, claws'}
    )},
    @{Key='clothes'; Name='服装'; Items=@(
        @{Label='丝袜'; Text='stockings, thighhighs'},
        @{Label='泳装'; Text='swimsuit, bikini'},
        @{Label='兽耳'; Text='animal ears, cat ears, tail'},
        @{Label='婚纱'; Text='wedding dress, veil'},
        @{Label='护士'; Text='nurse uniform, nurse cap'},
        @{Label='修女'; Text='nun, nun habit'},
        @{Label='长手套'; Text='long gloves, elbow gloves'}
    )},
    @{Key='composition'; Name='构图'; Items=@(
        @{Label='特写'; Text='close-up, face focus'},
        @{Label='全身'; Text='full body, standing'},
        @{Label='俯视'; Text='from above, looking up'},
        @{Label='仰视'; Text='from below, looking down'},
        @{Label='背影'; Text='from behind, back view'},
        @{Label='自拍'; Text='selfie, phone'},
        @{Label='躺卧'; Text='lying, on back, on side'},
        @{Label='侧面'; Text='side view, profile'}
    )},
    @{Key='race'; Name='种族'; Items=@(
        @{Label='猫娘'; Text='catgirl, cat ears, cat tail, claws, kemonomimi'},
        @{Label='狼娘'; Text='wolf girl, wolf ears, wolf tail, fangs, kemonomimi'},
        @{Label='狐娘'; Text='fox girl, fox ears, fox tail, multiple tails, kemonomimi'},
        @{Label='兔娘'; Text='bunny girl, rabbit ears, rabbit tail, kemonomimi'},
        @{Label='羊娘'; Text='sheep girl, sheep ears, horns, fluffy'},
        @{Label='史莱姆'; Text='slime girl, slime body, translucent body, liquid body'},
        @{Label='人马'; Text='centaur, horse body, hooves'},
        @{Label='恶魔'; Text='demon, demon horns, demon tail, bat wings'},
        @{Label='天使'; Text='angel, angel wings, halo, white feathers'},
        @{Label='幽灵'; Text='ghost, transparent body, floating, pale'},
        @{Label='AI娘'; Text='android, holographic, digital, glowing'},
        @{Label='人鱼'; Text='mermaid, mermaid tail, fish tail, scales'}
    )}
)
foreach ($group in $fixedExtraGroups) {
    $group.Items = @($group.Items | Sort-Object { $_.Text })
}
$fixedChoices = @()
foreach ($group in @(
    @{Key='style'; Name='画风'; Control=$presetStyle; Texts=$stylePresetTexts},
    @{Key='character'; Name='人物'; Control=$presetCharacter; Texts=$characterPresetTexts},
    @{Key='expression'; Name='表情'; Control=$presetExpression; Texts=$expressionPresetTexts}
)) {
    for ($i=1; $i -lt $group.Control.Items.Count; $i++) {
        $fixedChoices += [pscustomobject]@{Key=($group.Key+':'+$i); Name=($group.Name+' · '+$group.Control.Items[$i]); Text=$group.Texts[$i]; Random=($group.Key -eq 'expression' -and $i -eq $group.Control.Items.Count-1)}
    }
    $group.Control.Visible = $false
}
foreach ($group in $fixedExtraGroups) {
    for ($i=0; $i -lt $group.Items.Count; $i++) {
        $item = $group.Items[$i]
        $fixedChoices += [pscustomobject]@{Key=($group.Key+':'+($i+1)); Name=($group.Name+' · '+$item.Label); Text=$item.Text; Random=$false}
    }
}
$script:builtinFixedChoices=@($fixedChoices)
$script:presetOverrides=@()
$presetLibraryFile = Join-Path $AppDirectory 'preset_library_changes.json'
$script:presetDeletedKeys=@()
$script:presetCustomItems=@()
if (Test-Path -LiteralPath $presetLibraryFile) {
    try {
        $library=Get-Content -LiteralPath $presetLibraryFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:presetDeletedKeys=@($library.deleted)
        $script:presetCustomItems=@($library.custom | Where-Object { $_ -and $_.Key -match '^[a-z]+:custom_[a-f0-9]+$' -and $_.Name -and $_.Text })
        $script:presetOverrides=@($library.overrides | Where-Object { $_ -and $_.Key -in $script:builtinFixedChoices.Key -and $_.Name -and $_.Text })
        $fixedChoices=@(foreach ($choice in $fixedChoices) {
            if ($choice.Key -in $script:presetDeletedKeys) { continue }
            $override=$script:presetOverrides | Where-Object { $_.Key -eq $choice.Key } | Select-Object -Last 1
            if ($override) { $override } else { $choice }
        }) + $script:presetCustomItems
    } catch { [System.Windows.Forms.MessageBox]::Show('自定义预设读取失败：'+$_.Exception.Message,'预设管理') | Out-Null }
}
function New-CustomPresetItem([string]$prefix,[string]$title,[string]$name,[string]$text) {
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($text)) { throw '名称和提示词都需要填写。' }
    return [pscustomobject]@{Key=($prefix+':custom_'+[guid]::NewGuid().ToString('N')); Name=($title+' · '+$name.Trim()); Text=$text.Trim(); Random=$false}
}
function Save-PresetGroupItems($section,$items) {
    $prefix=$section.CategoryKey+':'
    $removed=@($section.Choices | Where-Object { $_.Key -notin @($items.Key) -and $_.Key -notlike '*:custom_*' } | ForEach-Object { $_.Key })
    $deleted=@(@($script:presetDeletedKeys)+$removed | Select-Object -Unique)
    $custom=@($script:presetCustomItems | Where-Object { -not $_.Key.StartsWith($prefix) }) + @($items | Where-Object { $_.Key -like '*:custom_*' })
    $overrides=@($script:presetOverrides | Where-Object { -not $_.Key.StartsWith($prefix) })
    foreach ($item in $items) {
        $builtin=$script:builtinFixedChoices | Where-Object { $_.Key -eq $item.Key } | Select-Object -First 1
        if ($builtin -and ($builtin.Name -ne $item.Name -or $builtin.Text -ne $item.Text -or $builtin.Random -ne $item.Random)) { $overrides+= $item }
    }
    $json=@{version=2; deleted=$deleted; custom=$custom; overrides=$overrides} | ConvertTo-Json -Depth 8
    $temporary=$presetLibraryFile+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $presetLibraryFile -Force -ErrorAction Stop
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    $script:presetDeletedKeys=$deleted; $script:presetCustomItems=$custom; $script:presetOverrides=$overrides
    $script:fixedChoices=@($fixedChoices | Where-Object { -not $_.Key.StartsWith($prefix) }) + @($items)
    $section.Choices=@($items)
    foreach ($key in @($section.Checked.Keys)) { if ($key -notin @($items.Key)) { $section.Checked.Remove($key) } }
    foreach ($item in $items) { if (-not $section.Checked.ContainsKey($item.Key)) { $section.Checked[$item.Key]=$false } }
    Search-FixedPresetGroups @($section) $section.SearchQuery
    Sync-FixedPresetGroups $section
}
function Show-PresetGroupManager($section) {
    $manager=New-Object System.Windows.Forms.Form
    $manager.Text='管理预设 · '+$section.Title; $manager.Font=$form.Font
    $manager.ClientSize=New-Object System.Drawing.Size(520,520)
    $manager.StartPosition='CenterParent'; $manager.FormBorderStyle='FixedDialog'; $manager.MaximizeBox=$false; $manager.MinimizeBox=$false
    $items=New-Object System.Collections.ArrayList
    foreach ($item in $section.Choices) { $null=$items.Add($item) }
    $list=New-Object System.Windows.Forms.ListBox
    $list.Location=New-Object System.Drawing.Point(16,16); $list.Size=New-Object System.Drawing.Size(488,220)
    $list.SelectionMode='MultiExtended'; $manager.Controls.Add($list)
    foreach ($item in $items) { $null=$list.Items.Add(($item.Name -split ' · ',2)[1]) }
    $delete=Add-Button $manager '删除选中项' 16 246 130
    $delete.Tag=@{List=$list; Items=$items}
    $delete.Add_Click({
        param($sender,$eventArgs)
        $state=$sender.Tag
        foreach ($index in @($state.List.SelectedIndices | Sort-Object -Descending)) { $state.Items.RemoveAt([int]$index); $state.List.Items.RemoveAt([int]$index) }
    })
    $label=New-Object System.Windows.Forms.Label
    $label.Text='项目名称'; $label.AutoSize=$true; $label.Location=New-Object System.Drawing.Point(16,290); $manager.Controls.Add($label)
    $name=New-Object System.Windows.Forms.TextBox
    $name.Location=New-Object System.Drawing.Point(110,286); $name.Width=394; $manager.Controls.Add($name)
    $label=New-Object System.Windows.Forms.Label
    $label.Text='对应提示词'; $label.AutoSize=$true; $label.Location=New-Object System.Drawing.Point(16,328); $manager.Controls.Add($label)
    $text=New-Object System.Windows.Forms.TextBox
    $text.Multiline=$true; $text.ScrollBars='Vertical'; $text.Location=New-Object System.Drawing.Point(110,324); $text.Size=New-Object System.Drawing.Size(394,100); $manager.Controls.Add($text)
    $add=Add-Button $manager '添加到列表' 16 434 130
    $add.Tag=@{List=$list; Items=$items; Name=$name; Text=$text; Section=$section; Owner=$manager}
    $add.Add_Click({
        param($sender,$eventArgs)
        $state=$sender.Tag
        try {
            $item=New-CustomPresetItem $state.Section.CategoryKey $state.Section.Title $state.Name.Text $state.Text.Text
            $null=$state.Items.Add($item); $null=$state.List.Items.Add(($item.Name -split ' · ',2)[1])
            $state.Name.Clear(); $state.Text.Clear()
        } catch { [System.Windows.Forms.MessageBox]::Show($state.Owner,$_.Exception.Message,'请检查输入') | Out-Null }
    })
    $update=Add-Button $manager '更新选中项' 158 434 130
    $update.Enabled=$false
    $editState=@{List=$list; Items=$items; Name=$name; Text=$text; Section=$section; Owner=$manager; Update=$update}
    $list.Tag=$editState; $update.Tag=$editState
    $list.Add_SelectedIndexChanged({
        param($sender,$eventArgs)
        $state=$sender.Tag; $single=$state.List.SelectedIndices.Count -eq 1
        $state.Update.Enabled=$single
        if ($single) {
            $item=$state.Items[$state.List.SelectedIndex]
            $state.Name.Text=($item.Name -split ' · ',2)[1]; $state.Text.Text=$item.Text
        }
    })
    $update.Add_Click({
        param($sender,$eventArgs)
        $state=$sender.Tag
        if ($state.List.SelectedIndices.Count -ne 1) { return }
        try {
            $index=$state.List.SelectedIndex
            $item=New-CustomPresetItem $state.Section.CategoryKey $state.Section.Title $state.Name.Text $state.Text.Text
            $item.Key=$state.Items[$index].Key
            $state.Items[$index]=$item
            $state.List.Items[$index]=($item.Name -split ' · ',2)[1]
        } catch { [System.Windows.Forms.MessageBox]::Show($state.Owner,$_.Exception.Message,'请检查输入') | Out-Null }
    })
    $save=Add-Button $manager '保存修改'  284 474 104
    $cancel=Add-Button $manager '取消' 400 474 104
    $cancel.DialogResult='Cancel'; $manager.CancelButton=$cancel
    $save.Tag=@{Items=$items; Section=$section; Owner=$manager}
    $save.Add_Click({
        param($sender,$eventArgs)
        $state=$sender.Tag
        try { Save-PresetGroupItems $state.Section @($state.Items.ToArray()); $state.Owner.DialogResult='OK' }
        catch { [System.Windows.Forms.MessageBox]::Show($state.Owner,$_.Exception.Message,'保存失败') | Out-Null }
    })
    try { $null=$manager.ShowDialog($section.Panel.FindForm()) } finally { $manager.Dispose() }
}

$script:randomPresetGroups=@($saved.randomPresetGroups | Where-Object { $_ -and $_ -in @($fixedChoices | ForEach-Object { ($_.Key -split ':',2)[0] }) } | Select-Object -Unique)
$script:selectedFixedKeys = @()
foreach ($entry in @(@('style',$presetStyle.SelectedIndex),@('character',$presetCharacter.SelectedIndex),@('expression',$presetExpression.SelectedIndex))) {
    if ($entry[1] -gt 0) { $script:selectedFixedKeys += ($entry[0]+':'+$entry[1]) }
}
if ($saved -and $saved.fixedPresetVersion -eq 3) {
    $script:selectedFixedKeys = @($saved.selectedFixedKeys | Where-Object { $_ -in $fixedChoices.Key })
}
$script:fixedAppliedTexts = @{}
foreach ($choice in $fixedChoices) {
    if ($choice.Key -notin $script:selectedFixedKeys) { continue }
    if ($saved -and $saved.fixedPresetVersion -eq 3 -and $saved.fixedAppliedTexts) {
        $property = $saved.fixedAppliedTexts.PSObject.Properties[$choice.Key]
        if ($property) { $script:fixedAppliedTexts[$choice.Key] = [string]$property.Value }
        elseif (-not $choice.Random) { $script:fixedAppliedTexts[$choice.Key]=$choice.Text }
    } elseif (-not $choice.Random) { $script:fixedAppliedTexts[$choice.Key] = $choice.Text }
}
$chooseFixedPresets = New-Object System.Windows.Forms.Button
$chooseFixedPresets.Location = New-Object System.Drawing.Point($negPreset.Left,222)
$chooseFixedPresets.Width = 92
$chooseFixedPresets.Height=28
$chooseFixedPresets.Text='标签'
$chooseFixedPresets.Anchor='Top,Right'
$ldgCharacter.Anchor='Top,Right'
$ldgPromptLib.Anchor='Top,Right'
$creationPage.Controls.Add($ldgCharacter)
$creationPage.Controls.Add($ldgPromptLib)
$creationPage.Controls.Add($chooseFixedPresets)
function Update-FixedPresetCaption {
    if ($script:autoSaveReady) { Queue-SettingsSave }
    $chooseFixedPresets.Text = '标签（'+$script:selectedFixedKeys.Count+'）'+$(if ($script:randomPresetGroups.Count) {' · 逐张随机 '+$script:randomPresetGroups.Count+' 类'} else {''})
}
function Remove-FixedPresetText([string]$text,[string]$value) {
    if (-not $value) { return $text }
    $normalized=$text.Replace("`r`n","`n")
    $escaped=[regex]::Escape($value.Replace("`r`n","`n"))
    $block=[regex]::new('(?m)^[ \t]*'+$escaped+'[ \t]*$')
    if ($block.IsMatch($normalized)) { return $block.Replace($normalized,'',1).Replace("`n","`r`n") }
    $inline=[regex]::new('(?m)(^|,[ \t]*|\n[ \t]*)'+$escaped+'[ \t]*(?=,|$)')
    $updated=$inline.Replace($normalized,'',1)
    if ($updated -eq $normalized) { return $text }
    $updated=[regex]::Replace($updated,'(?m)^[ \t]*,[ \t]*','')
    $updated=[regex]::Replace($updated,'(?m),[ \t]*$','')
    return $updated.Replace("`n","`r`n")
}
function Set-FixedPresetSelection([string[]]$keys) {
    $keys = @($keys | Select-Object -Unique)
    foreach ($key in $keys) { if ($key -notin $fixedChoices.Key) { throw '未知固定片段预设。' } }
    $text = $fixedPrompt.Text
    foreach ($key in @($script:selectedFixedKeys)) {
        if ($script:fixedAppliedTexts.ContainsKey($key)) { continue }
        $choice=$fixedChoices | Where-Object { $_.Key -eq $key } | Select-Object -First 1
        if ($choice -and -not $choice.Random -and (Test-PromptFragment $text $choice.Text)) { $script:fixedAppliedTexts[$key]=$choice.Text }
    }
    foreach ($key in @($script:fixedAppliedTexts.Keys)) {
        if ($key -in $keys) { continue }
        $old = [string]$script:fixedAppliedTexts[$key]
        if ($old) { $text = Remove-FixedPresetText $text $old }
        $script:fixedAppliedTexts.Remove($key)
    }
    foreach ($key in $keys) {
        $choice = $fixedChoices | Where-Object { $_.Key -eq $key } | Select-Object -First 1
        if ($key -in $script:selectedFixedKeys) {
            $applied = [string]$script:fixedAppliedTexts[$key]
            $intact = $applied -and (Test-PromptFragment $fixedPrompt.Text $applied)
            if ($choice.Random -or ($applied -eq $choice.Text -and $intact)) { continue }
            $text=Remove-FixedPresetText $text $applied
        }
        $value = $choice.Text
        if ($choice.Random) { $value = ($fixedChoices | Where-Object { $_.Key -like 'expression:*' -and -not $_.Random } | Get-Random).Text }
        if ($value) { $text = (@($text.Trim(" `r`n,"),$value) | Where-Object { $_ }) -join "`r`n" }
        $script:fixedAppliedTexts[$key] = $value
    }
    $fixedPrompt.Text = $text.Trim(" `r`n,")
    $script:selectedFixedKeys = @($keys)
    Update-FixedPresetCaption
}
foreach ($choice in @($fixedChoices | Where-Object { $_.Random -and $_.Key -in $script:selectedFixedKeys })) {
    $fixedPrompt.Text=(Remove-FixedPresetText $fixedPrompt.Text ([string]$script:fixedAppliedTexts[$choice.Key])).Trim(" `r`n,")
    $script:fixedAppliedTexts.Remove($choice.Key)
    $script:selectedFixedKeys=@($script:selectedFixedKeys | Where-Object { $_ -ne $choice.Key })
    $script:randomPresetGroups=@(@($script:randomPresetGroups)+(($choice.Key -split ':',2)[0]) | Select-Object -Unique)
}
Update-FixedPresetCaption
$tip.SetToolTip($chooseFixedPresets,'可同时勾选多个画风、人物或表情。勾选立即加入输入框；取消勾选立即移除对应的完整预设片段（包括旧版逗号拼接）；手动改写过的内容保留。各类随机菜单：每张随机会逐张重新抽取；统一随机只抽一次，整批固定。')
function Update-PresetGroupCaption($section, [int]$count) {
    $arrow = $(if ($section.Expanded) {'▼'} else {'▶'})
    $section.Header.Text = $arrow+'  '+$section.Title+'    已选 '+$count+' / '+$section.Choices.Count
    $section.UnifiedMenu.Enabled = $count -lt $section.Choices.Count
    $section.RandomButton.Text=$(if ($section.RandomEach) {'随机✓'} else {'随机'})
}
function Sync-FixedPresetGroups($section) {
    $sections=$section.Panel.Parent.Tag
    if (-not $sections) { return }
    Set-FixedPresetSelection @(Get-FixedGroupKeys $sections)
    $script:randomPresetGroups=@($sections | Where-Object { $_.RandomEach } | ForEach-Object { $_.CategoryKey })
    Update-FixedPresetCaption
}
function Add-RandomPresetChoice($section) {
    $available=@($section.Choices | Where-Object { -not $section.Checked[$_.Key] })
    if (-not $available.Count) { return }
    $choice=$available | Get-Random
    $section.Checked[$choice.Key]=$true
    $index=[Array]::IndexOf($section.VisibleChoices,$choice)
    if ($index -ge 0) { $section.List.SetItemChecked($index,$true) }
    Sync-FixedPresetGroups $section
    Update-PresetGroupCaption $section (@($section.Checked.Values | Where-Object { $_ }).Count)
}
function Set-PresetGroupExpanded($section, [bool]$expanded) {
    $section.Expanded = $expanded
    $section.List.Visible = $expanded
    $section.Panel.Height = $(if ($expanded) {$section.List.Bottom+4} else {40})
    Update-PresetGroupCaption $section (@($section.Checked.Values | Where-Object { $_ }).Count)
}
function New-FixedPresetGroups($hostPanel) {
    $hostPanel.ColumnCount=3; $hostPanel.RowCount=0
    $hostPanel.AutoSize=$true; $hostPanel.AutoSizeMode='GrowAndShrink'; $hostPanel.Dock='Top'
    $hostPanel.ColumnStyles.Clear()
    for ($columnIndex=0; $columnIndex -lt 3; $columnIndex++) {
        $null=$hostPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',(100.0/3))))
    }
    $sections = @()
foreach ($group in @(@('style','画风'),@('character','人物'),@('expression','表情'),@('race','种族'),@('body','体型'),@('clothes','服装'),@('composition','构图'))) {
        $choices = @($fixedChoices | Where-Object { $_.Key.StartsWith($group[0]+':') -and -not $_.Random })
        $panel = New-Object System.Windows.Forms.Panel
        $panel.Size = New-Object System.Drawing.Size(370,40)
        $panel.Margin = New-Object System.Windows.Forms.Padding(4,0,4,10)
        $panel.Anchor='Top,Left,Right'
        $header = Add-Button $panel '' 0 0 242
        $header.AutoEllipsis=$true
        $header.Anchor='Top,Left,Right'
        $header.Height=36; $header.TextAlign='MiddleLeft'; $header.FlatStyle='Flat'
        $header.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#EEF2FA')
        $header.ForeColor=[System.Drawing.ColorTranslator]::FromHtml('#22324A')
        $header.FlatAppearance.BorderColor=[System.Drawing.ColorTranslator]::FromHtml('#CAD4E3')
        $manageButton = Add-Button $panel '管理' 246 0 60
        $manageButton.Height=36; $manageButton.Anchor='Top,Right'; $manageButton.FlatStyle='Flat'
        $manageButton.BackColor=$header.BackColor; $manageButton.ForeColor=$header.ForeColor
        $manageButton.FlatAppearance.BorderColor=$header.FlatAppearance.BorderColor
        $randomButton = Add-Button $panel '随机' 310 0 60
        $randomButton.Height=36; $randomButton.Anchor='Top,Right'; $randomButton.FlatStyle='Flat'
        $randomButton.BackColor=$header.BackColor; $randomButton.ForeColor=$header.ForeColor
        $randomButton.FlatAppearance.BorderColor=$header.FlatAppearance.BorderColor
        $list = New-Object System.Windows.Forms.CheckedListBox
        $list.Location = New-Object System.Drawing.Point(0,40)
        $list.Size = New-Object System.Drawing.Size(370,(10*$list.ItemHeight+8))
        $list.CheckOnClick=$true; $list.IntegralHeight=$false; $list.Visible=$false
        $list.BorderStyle='FixedSingle'; $list.Anchor='Top,Left,Right'
        foreach ($choice in $choices) {
            $name = ($choice.Name -split ' · ',2)[1]
            $null = $list.Items.Add($name,($choice.Key -in $script:selectedFixedKeys))
        }
        $panel.Controls.Add($list)
        $section = [pscustomobject]@{Title=$group[1]; CategoryKey=$group[0]; SearchQuery=''; Panel=$panel; ManageButton=$manageButton; Header=$header; RandomButton=$randomButton; List=$list; Choices=$choices; VisibleChoices=$choices; Checked=@{}; Filtering=$false; Expanded=$false; RandomEach=($group[0] -in $script:randomPresetGroups); EachMenu=$null; UnifiedMenu=$null}
        foreach ($choice in $choices) { $section.Checked[$choice.Key]=($choice.Key -in $script:selectedFixedKeys) }
        $header.Tag=$section; $list.Tag=$section
        $manageButton.Tag=$section
        $manageButton.Add_Click({ param($sender,$eventArgs) Show-PresetGroupManager $sender.Tag })
        $randomButton.Tag=$section
        $menu=New-Object System.Windows.Forms.ContextMenuStrip
        $eachItem=New-Object System.Windows.Forms.ToolStripMenuItem('每张随机')
        $eachItem.CheckOnClick=$true; $eachItem.Checked=$section.RandomEach; $eachItem.Tag=$section
        $unifiedItem=New-Object System.Windows.Forms.ToolStripMenuItem('统一随机'); $unifiedItem.Tag=$section
        $null=$menu.Items.Add($eachItem); $null=$menu.Items.Add($unifiedItem)
        $section.EachMenu=$eachItem; $section.UnifiedMenu=$unifiedItem
        $randomButton.ContextMenuStrip=$menu
        $eachItem.Add_CheckedChanged({
            param($sender,$eventArgs)
            $section=$sender.Tag; $section.RandomEach=$sender.Checked
            Sync-FixedPresetGroups $section
            Update-PresetGroupCaption $section @($section.Checked.Values | Where-Object { $_ }).Count
        })
        $unifiedItem.Add_Click({
            param($sender,$eventArgs)
            $section=$sender.Tag; $section.EachMenu.Checked=$false
            Add-RandomPresetChoice $section
        })
        $randomButton.Add_Click({ param($sender,$eventArgs) $sender.ContextMenuStrip.Show($sender,(New-Object System.Drawing.Point(0,$sender.Height))) })
        Update-PresetGroupCaption $section $list.CheckedItems.Count
        Update-PresetGroupCaption $section $list.CheckedItems.Count
        $header.Add_Click({
            param($sender,$eventArgs)
            $section=$sender.Tag
            $section.Expanded = -not $section.Expanded
            $section.List.Visible=$section.Expanded
            $section.Panel.Height = $(if ($section.Expanded) {$section.List.Bottom+4} else {40})
            Update-PresetGroupCaption $section (@($section.Checked.Values | Where-Object { $_ }).Count)
        })
        $list.Add_ItemCheck({
            param($sender,$eventArgs)
            $section=$sender.Tag
            if ($section.Filtering) { return }
            $key=$section.VisibleChoices[$eventArgs.Index].Key
            $section.Checked[$key]=($eventArgs.NewValue -eq 'Checked')
            $count=@($section.Checked.Values | Where-Object { $_ }).Count
            Update-PresetGroupCaption $section $count
            Sync-FixedPresetGroups $section
        })
        $column = $sections.Count % 3
        $row = [int][Math]::Floor($sections.Count / 3)
        if ($column -eq 0) {
            $hostPanel.RowCount = $row+1
            $null=$hostPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
        }
        $hostPanel.Controls.Add($panel,$column,$row)
        $sections += $section
    }
    return $sections
}
function Get-FixedGroupKeys($sections) {
    foreach ($section in $sections) {
        foreach ($choice in $section.Choices) { if ($section.Checked[$choice.Key]) { $choice.Key } }
    }
}

function Expand-AllPresetGroups($sections, [switch]$SelectedOnly) {
    foreach ($section in $sections) {
        if ((-not $SelectedOnly -or ($section.List.CheckedItems.Count -gt 0 -or $section.RandomEach)) -and -not $section.Expanded) { Set-PresetGroupExpanded $section $true }
    }
}
function Clear-FixedGroupSelections($sections) {
    foreach ($section in $sections) {
        $section.EachMenu.Checked=$false
        foreach ($key in @($section.Checked.Keys)) { $section.Checked[$key]=$false }
        for ($index=0; $index -lt $section.List.Items.Count; $index++) { $section.List.SetItemChecked($index,$false) }
        Update-PresetGroupCaption $section 0
    }
    if ($sections.Count) { Sync-FixedPresetGroups $sections[0] }
}
function Search-FixedPresetGroups($sections, [string]$query) {
    $query=$query.Trim()
    foreach ($section in $sections) {
        $section.SearchQuery=$query
        $matches=@($section.Choices | Where-Object { -not $query -or $_.Name.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
        $section.Filtering=$true
        $section.List.BeginUpdate()
        try {
            $section.List.Items.Clear()
            $section.VisibleChoices=$matches
            foreach ($choice in $matches) {
                $name=($choice.Name -split ' · ',2)[1]
                $null=$section.List.Items.Add($name,[bool]$section.Checked[$choice.Key])
            }
        } finally { $section.List.EndUpdate(); $section.Filtering=$false }
        $section.Panel.Visible=(-not $query -or $matches.Count -gt 0)
        $checkedCount=@($section.Checked.Values | Where-Object { $_ }).Count
        Set-PresetGroupExpanded $section ($matches.Count -gt 0 -and ($query.Length -gt 0 -or $checkedCount -gt 0 -or $section.RandomEach))
        Update-PresetGroupCaption $section $checkedCount
    }
}

$openFixedPresets = {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '组合预设'; $dialog.StartPosition = 'CenterParent'
    $workArea = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $dialog.ClientSize = New-Object System.Drawing.Size(914,[Math]::Min(800,$workArea.Height-100))
    $dialog.MinimumSize = New-Object System.Drawing.Size(930,400)
    $dialog.Font = $form.Font; $dialog.FormBorderStyle = 'Sizable'; $dialog.MaximizeBox=$true; $dialog.MinimizeBox=$false
    $groupsPanel = New-Object System.Windows.Forms.Panel
    $groupsPanel.Location = New-Object System.Drawing.Point(16,16)
    $groupsPanel.Size = New-Object System.Drawing.Size(($dialog.ClientSize.Width-32),($dialog.ClientSize.Height-80))
    $groupsPanel.Anchor = 'Top,Bottom,Left,Right' 
    $groupsPanel.AutoScroll=$true
    $dialog.Controls.Add($groupsPanel)
    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $groupsPanel.Controls.Add($grid)
    $sections = @(New-FixedPresetGroups $grid)
    $grid.Tag=$sections
    Expand-AllPresetGroups $sections -SelectedOnly
    $searchLabel = New-Object System.Windows.Forms.Label
    $searchLabel.Text='搜索'; $searchLabel.AutoSize=$true
    $searchLabel.Location=New-Object System.Drawing.Point(($dialog.ClientSize.Width-680),($dialog.ClientSize.Height-42))
    $searchLabel.Anchor='Bottom,Right'; $dialog.Controls.Add($searchLabel)
    $search = New-Object System.Windows.Forms.TextBox
    $search.Location=New-Object System.Drawing.Point(($dialog.ClientSize.Width-640),($dialog.ClientSize.Height-46))
    $search.Width=190; $search.Anchor='Bottom,Right'; $search.Tag=$sections
    $dialog.Controls.Add($search)
    $search.Add_TextChanged({ param($sender,$eventArgs) Search-FixedPresetGroups $sender.Tag $sender.Text })
    $clearPresets = Add-Button $dialog '清空' ($dialog.ClientSize.Width-440) ($dialog.ClientSize.Height-48) 100
    $clearPresets.Anchor='Bottom,Right'; $clearPresets.Tag=$sections
    $clearPresets.Add_Click({ param($sender,$eventArgs) Clear-FixedGroupSelections $sender.Tag })
    $expandAll = Add-Button $dialog '全展开' ($dialog.ClientSize.Width-330) ($dialog.ClientSize.Height-48) 100
    $expandAll.Anchor='Bottom,Right'; $expandAll.Tag=$sections
    $expandAll.Add_Click({ param($sender,$eventArgs) Expand-AllPresetGroups $sender.Tag })
    $ok = Add-Button $dialog '完成' ($dialog.ClientSize.Width-110) ($dialog.ClientSize.Height-48) 94
    $ok.Anchor='Bottom,Right'; $ok.DialogResult='OK'
    $dialog.AcceptButton=$ok; $dialog.CancelButton=$ok
    try { $null=$dialog.ShowDialog($form) } finally { $dialog.Dispose() }
}
$chooseFixedPresets.Add_Click({ & $openFixedPresets })

function Set-PromptPanelLayout {
    foreach ($box in @($fixedPrompt,$prompt,$negPrompt)) { $box.Left=12; $box.Width=[Math]::Max(200,$creationPage.ClientSize.Width-24) }
    $negPreset.Left=$negPrompt.Right-$negPreset.Width
    $chooseFixedPresets.Left=$fixedPrompt.Right-$chooseFixedPresets.Width
    $ldgCharacter.Left=$chooseFixedPresets.Left-$ldgCharacter.Width-8
    $ldgCharacter.Top=18
    $ldgPromptLib.Left=$ldgCharacter.Left-$ldgPromptLib.Width-8
    $ldgPromptLib.Top=18
    $boxHeight = [Math]::Max(100, [Math]::Floor(($creationPage.ClientSize.Height - 180) / 3))
    $boxes = @($fixedPrompt, $prompt, $negPrompt)
    $presets = @($presetStyle, $null, $negPreset)
    $labelPrefixes = @('预设', '提示词 / 修改要求', '负面提示词')
    for ($i = 0; $i -lt 3; $i++) {
        $offset = $i * ($boxHeight + 54)
        if ($i -gt 0) { $offset += $boxHeight - [Math]::Floor($boxHeight / 2) }
        $boxes[$i].SetBounds($boxes[$i].Left, 54 + $offset, $boxes[$i].Width, $boxHeight)
        if ($i -eq 2) { $boxes[$i].Height = [Math]::Floor($boxHeight / 2) }
        if ($i -eq 0) { $chooseFixedPresets.Top = 18 + $offset; $boxes[$i].Height = 2 * $boxHeight - [Math]::Floor($boxHeight / 2) }
        if ($presets[$i]) { $presets[$i].Top = 18 + $offset }
        if ($i -eq 0) { $presetCharacter.Top = $presetStyle.Top; $presetExpression.Top = $presetStyle.Top }
        foreach ($label in $creationPage.Controls) {
            if ($label -is [System.Windows.Forms.Label] -and $label.Text.StartsWith($labelPrefixes[$i])) {
                if ($i -eq 0) { $label.Top = $presetStyle.Top + 3; $label.Left = 12 } else { $label.Top = 22 + $offset }
            }
        }
    }
}
$creationPage.Add_Resize({ Set-PromptPanelLayout })
$form.Add_Shown({ Set-PromptPanelLayout })
$imageLabel.Top = 180
$refUsageLabel.Location = New-Object System.Drawing.Point(12,204)
$refUsage.Location = New-Object System.Drawing.Point(12,228)
$refStrengthLabel.Location = New-Object System.Drawing.Point(12,264)
$refPreset.Location = New-Object System.Drawing.Point(12,288)
$refElementLabel.Location = New-Object System.Drawing.Point(242,264)
$refElement.Location = New-Object System.Drawing.Point(242,288)
$imagePath.Top = 330; $chooseImage.Top = 328
$refHint.Location = New-Object System.Drawing.Point(12,368)
foreach ($control in $optionsPage.Controls) {
    if ($control -ne $imagePath -and $control -ne $chooseImage -and $control -ne $refHint -and $control.Top -ge 308) { $control.Top += 128 }
}
$stepsLabel.Text = '步数'
$stepsLabel.AutoSize = $false; $stepsLabel.Width = 100; $stepsLabel.AutoEllipsis = $true
$assistantPage=New-Object System.Windows.Forms.TabPage
$assistantPage.Text='关键词助手'
$assistantPage.Controls.Add($assistant)
$tabs.TabPages.AddRange(@($creationPage,$optionsPage,$assistantPage)); $inputs.Controls.Add($tabs)
$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $assistantPage) {
        Set-AssistantTabLayout
        if (-not $script:assistantModelsLoaded) { $assistant.Refresh(); Refresh-AssistantModels }
    }
})
function Set-AssistantTabLayout {
    $w=[Math]::Max(420,$assistant.ClientSize.Width)
    $h=[Math]::Max(600,$assistant.ClientSize.Height)
    $assistant.SuspendLayout()
    try {
        $asModelLabel.Location=New-Object Drawing.Point(12,14)
        $asModel.Location=New-Object Drawing.Point(56,10); $asModel.Width=$w-124
        $asRefresh.Location=New-Object Drawing.Point(($w-56),9)
        $asModeLabel.Location=New-Object Drawing.Point(12,50)
        $asMode.Location=New-Object Drawing.Point(56,46); $asMode.Width=$w-68
        $asCaption1.Location=New-Object Drawing.Point(12,86)
        $ideaHeight=[Math]::Max(80,[Math]::Floor(($h-420)*0.45))
        $asIdea.Location=New-Object Drawing.Point(12,110); $asIdea.Size=New-Object Drawing.Size(($w-24),$ideaHeight)
        $asDirBtn.Location=New-Object Drawing.Point(12,($asIdea.Bottom+10))
        $asRegenBtn.Location=New-Object Drawing.Point(172,$asDirBtn.Top)
        $asStatus.Location=New-Object Drawing.Point(12,($asDirBtn.Bottom+8)); $asStatus.Size=New-Object Drawing.Size(($w-24),40)
        $asCaption3.Location=New-Object Drawing.Point(12,($asStatus.Bottom+8))
        $finalTop=$asCaption3.Bottom+8
        $asFinal.Location=New-Object Drawing.Point(12,$finalTop)
        $asFinal.Size=New-Object Drawing.Size(($w-24),[Math]::Max(100,$h-92-$finalTop))
        $buttons=@($asCopy,$asFill,$asSave,$asClear,$asTranslate,$asAnalyze)
        $buttonWidth=[Math]::Floor(($w-40)/3)
        for ($i=0; $i -lt $buttons.Count; $i++) {
            $buttons[$i].Location=New-Object Drawing.Point((12+($i%3)*($buttonWidth+8)),($asFinal.Bottom+12+[Math]::Floor($i/3)*38))
            $buttons[$i].Size=New-Object Drawing.Size($buttonWidth,30)
        }
        $assistant.AutoScrollMinSize=New-Object Drawing.Size(0,($asAnalyze.Bottom+12))
    } finally { $assistant.ResumeLayout() }
}
$assistant.Add_Resize({ if ($asAnalyze) { Set-AssistantTabLayout } })
$asCaption1.Text = '① 写下你的想法'
$asCaption3.Text = '② 编辑结果，再填入工作台'
$asModelLabel.Text = '模型'
Set-AssistantTabLayout
$asStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#52647A')
$subtitle.Text = '创作 · 编辑 · 批量生成'
$header.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EDF2FA')
$footer.BackColor = $header.BackColor
$resultTitle.Text = '图片预览 · 支持拖放与粘贴'
$resultPath.Width = [Math]::Max(100,$right.ClientSize.Width - 40)
$uiInk = [System.Drawing.ColorTranslator]::FromHtml('#22324A')
$uiMuted = [System.Drawing.ColorTranslator]::FromHtml('#52647A')
$uiAccent = [System.Drawing.ColorTranslator]::FromHtml('#315ED7')
$uiSurface = [System.Drawing.ColorTranslator]::FromHtml('#F5F7FB')
$uiBorder = [System.Drawing.ColorTranslator]::FromHtml('#CAD4E3')
$uiInputFont = New-Object System.Drawing.Font('Microsoft YaHei UI',11)
$uiLabelFont = New-Object System.Drawing.Font('Microsoft YaHei UI',10,[System.Drawing.FontStyle]::Bold)
function Style-WorkbenchControls($parent) {
    foreach ($control in $parent.Controls) {
        if ($control -is [System.Windows.Forms.Label]) { $control.ForeColor = $uiInk }
        if ($control -is [System.Windows.Forms.TextBox]) {
            $control.ForeColor = $uiInk
            if ($control -ne $resultPath) {
                $control.BackColor = $(if ($control.ReadOnly) {$uiSurface} else {[System.Drawing.Color]::White})
                if ($control.Multiline) { $control.Font = $uiInputFont }
                $control.BorderStyle = 'FixedSingle'
            }
        }
        if ($control -is [System.Windows.Forms.ComboBox]) {
            $control.ForeColor = $uiInk
            $control.BackColor = [System.Drawing.Color]::White
            $control.FlatStyle = 'Standard'
        }
        if ($control -is [System.Windows.Forms.Button] -and $control -ne $generate -and $control -ne $stop) {
            $control.FlatStyle = 'Flat'; $control.FlatAppearance.BorderColor = $uiBorder
            $control.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#E9EFFD')
            $control.FlatAppearance.MouseDownBackColor = [System.Drawing.ColorTranslator]::FromHtml('#DCE6FD')
            $control.BackColor = [System.Drawing.Color]::White; $control.ForeColor = $uiInk
            $control.Cursor = [System.Windows.Forms.Cursors]::Hand
        }
        if ($control.HasChildren) { Style-WorkbenchControls $control }
    }
}
Style-WorkbenchControls $form
foreach ($page in @($creationPage,$optionsPage)) {
    $page.BackColor = $uiSurface
    foreach ($label in $page.Controls) {
        if ($label -is [System.Windows.Forms.Label]) { $label.Font = $uiLabelFont }
    }
}
foreach ($label in @($subtitle,$elapsed,$asStatus)) { $label.ForeColor = $uiMuted }
$title.ForeColor = $uiInk
$modelLabel.ForeColor = $uiMuted
$header.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EEF2FA')
$footer.BackColor = $header.BackColor
$assistant.BackColor = $uiSurface
$assistant.BorderStyle = 'None'

$preview.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#EDF1F7')
$generate.BackColor = $uiAccent; $generate.FlatAppearance.BorderSize = 0
$generate.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#254AB4')
$generate.Cursor = [System.Windows.Forms.Cursors]::Hand
$stop.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFF1F1')
$stop.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#AB303B')
$stop.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#E5BAC0')
$stop.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#FBE0E3')
foreach ($button in @($asDirBtn,$asFill)) {
    $button.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#E8EEFC')
    $button.ForeColor = $uiAccent
    $button.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#B8C8EE')
}
$asStatus.AutoEllipsis = $true
$statusLabel.AutoEllipsis = $true
$tabs.DrawMode = 'OwnerDrawFixed'; $tabs.SizeMode = 'Fixed'
function Set-TabHeaderLayout {
    if ($tabs.TabPages.Count -eq 0) { return }
    $tabWidth=[Math]::Max(60,[Math]::Floor(($tabs.ClientSize.Width-4)/$tabs.TabPages.Count)-1)
    if ($tabs.ItemSize.Width -ne $tabWidth -or $tabs.ItemSize.Height -ne 40) {
        $tabs.ItemSize=New-Object Drawing.Size($tabWidth,40)
    }
}
$tabs.Add_Resize({ Set-TabHeaderLayout })
$body.Add_Layout({ Set-HeaderFooterLayout })
$resultTitle.TextAlign='MiddleLeft'
$tabs.Add_Layout({ if ($resultTitle.Height -ne $tabs.DisplayRectangle.Top) { $resultTitle.Height=$tabs.DisplayRectangle.Top } })
Set-TabHeaderLayout
$tabs.Add_DrawItem({
    param($sender,$eventArgs)
    $active = $eventArgs.Index -eq $tabs.SelectedIndex
    $brush = New-Object System.Drawing.SolidBrush($(if ($active) {[System.Drawing.Color]::White} else {$uiSurface}))
    try { $eventArgs.Graphics.FillRectangle($brush,$eventArgs.Bounds) } finally { $brush.Dispose() }
    $color = $(if ($active) {$uiAccent} else {$uiMuted})
    [System.Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,$tabs.TabPages[$eventArgs.Index].Text,$uiLabelFont,$eventArgs.Bounds,$color,([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
    if ($active) {
        $pen = New-Object System.Drawing.Pen($uiAccent,3)
        try { $eventArgs.Graphics.DrawLine($pen,$eventArgs.Bounds.Left+14,$eventArgs.Bounds.Bottom-3,$eventArgs.Bounds.Right-14,$eventArgs.Bounds.Bottom-3) } finally { $pen.Dispose() }
    }
})
# Hide the raised page frame while preserving the native tab headers.
function Set-TabFrameRegion {
    $content=$tabs.DisplayRectangle
    $region=New-Object Drawing.Region($content)
    $region.Union((New-Object Drawing.Rectangle(0,0,$tabs.GetTabRect($tabs.TabCount-1).Right,$content.Top)))
    $oldRegion=$tabs.Region
    $tabs.Region=$region
    if ($oldRegion) { $oldRegion.Dispose() }
}
$tabs.Add_Layout({ Set-TabFrameRegion })
Set-TabFrameRegion
$preview.Add_Paint({
    param($sender,$eventArgs)
    if ($preview.Image) { return }
    $bounds = $preview.ClientRectangle
    [System.Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,"图片会显示在这里`n可拖入图片，或按 Ctrl+V 粘贴参考图",$form.Font,$bounds,$uiMuted,([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::WordBreak))
})


$output.Add_Leave({ Open-OutputGallery })
$form.Add_Shown({ if (-not ($SelfTest -or $TestDrawer -or $TestAssistant -or $IntegrationTest)) { Open-OutputGallery } })
$prompt.Add_TextChanged({ Update-BatchSummary })
$batchCount.Add_ValueChanged({ Update-BatchSummary })
$mode.Add_SelectedIndexChanged({ Update-BatchSummary })
Update-BatchSummary
$form.Add_Resize({ Set-HeaderFooterLayout })
Set-HeaderFooterLayout

$script:autoSaveReady=$false
$script:settingsDirty=$false
$draftStatus=New-Object Windows.Forms.Label
$draftStatus.Location=New-Object Drawing.Point(280,12); $draftStatus.Size=New-Object Drawing.Size(200,22)
$draftStatus.ForeColor=$uiMuted; $header.Controls.Add($draftStatus)
$autoSaveTimer=New-Object Windows.Forms.Timer
$autoSaveTimer.Interval=1500
function Queue-SettingsSave {
    if (-not $script:autoSaveReady -or $script:suppressRefresh) { return }
    $script:settingsDirty=$true; $draftStatus.Text='草稿待保存'
    $autoSaveTimer.Stop(); $autoSaveTimer.Start()
}
function Save-PendingDraft {
    $autoSaveTimer.Stop()
    if (-not $script:settingsDirty) { return }
    try {
        Save-Settings
        $script:settingsDirty=$false; $draftStatus.Text='草稿已保存'
        $tip.SetToolTip($draftStatus,'提示词、预设和参数已自动保存。')
    } catch {
        $draftStatus.Text='草稿自动保存失败'
        $tip.SetToolTip($draftStatus,$_.Exception.Message)
    }
}
$autoSaveTimer.Add_Tick({ Save-PendingDraft })
foreach ($control in @($prompt,$fixedPrompt,$negPrompt,$output,$seed,$imagePath)) { $control.Add_TextChanged({ Queue-SettingsSave }) }
foreach ($control in @($model,$mode,$preset,$refUsage,$refPreset,$refElement,$negPreset,$presetStyle,$presetCharacter,$presetExpression)) { $control.Add_SelectedIndexChanged({ Queue-SettingsSave }) }
foreach ($control in @($width,$height,$steps,$cfg,$batchCount)) { $control.Add_ValueChanged({ Queue-SettingsSave }) }
$form.Add_Shown({ $script:autoSaveReady=-not ($SelfTest -or $TestDrawer -or $TestAssistant -or $IntegrationTest) })
$form.Add_FormClosed({ $autoSaveTimer.Stop(); $autoSaveTimer.Dispose() })

$agentBridgeFile=Join-Path $AppDirectory 'agent_bridge.ps1'
if (Test-Path -LiteralPath $agentBridgeFile) { . $agentBridgeFile }

if ($TestDrawer) {
    $form.Show(); $tabs.SelectedTab=$assistantPage
    [Windows.Forms.Application]::DoEvents(); Set-AssistantTabLayout
    if ($ScreenshotPath) {
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try { $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $bitmap.Save($ScreenshotPath,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
    }
    Write-Output 'ASSISTANT_THIRD_TAB_VISIBLE_OK'
    $form.Dispose(); exit 0
}

if ($TestAssistant) {
    Refresh-AssistantModels
    $form.Show(); $form.PerformLayout()
    [System.Windows.Forms.Application]::DoEvents()
    $tabs.SelectedTab=$assistantPage
    Set-AssistantTabLayout
    [System.Windows.Forms.Application]::DoEvents()
    $asMode.SelectedIndex = 1
    $asIdea.Text = '两个成年女性在书桌前，一个仔细比较两张手稿，一个拿笔托腮思考'
    $asDirBtn.PerformClick()
    Write-Host ('ASST_FINAL_OK=' + [bool]$asFinal.Text.Trim())
    Write-Host ('ASST_HAS_LAYOUT=' + ($asFinal.Text -match '布局与画风'))
    Write-Host ('ASST_HAS_PANEL=' + ($asFinal.Text -match '画面一'))
    Write-Host ('ASST_HAS_LIMB=' + ($asFinal.Text -match '肢体与空间要求'))
    Write-Host ('ASST_HAS_HAIR=' + ($asFinal.Text -match '发型与角色外观'))
    Write-Host ('ASST_HAS_COSTUME=' + ($asFinal.Text -match '服设'))
    Write-Host ('ASST_LEN=' + $asFinal.Text.Length)
    $asFill.PerformClick()
    Write-Host ('ASST_FILLED=' + ($prompt.Text -eq $asFinal.Text.Trim()))
    Write-Host ('ASST_MODE=' + $mode.SelectedIndex)
    Write-Host ('ASST_STATUS=' + $statusLabel.Text)
    $form.Dispose()
    exit 0
}

if ($SelfTest) {
    if ($script:assistantModelsLoaded) { throw 'Assistant connection blocked startup.' }
    $script:assistantRefreshCalls=0
    function Get-OllamaModels {
        $script:assistantRefreshCalls++
        if ($script:testAssistantOffline) { $script:ollamaLastError='offline'; return @() }
        return @($script:testAssistantModels)
    }
    $script:testAssistantModels=@('yi-9b-abliterated:latest','qwen3.5:4b','deepseek-r1:14b')

    foreach ($case in @(@('山间清晨，一座古祠。','英文'),@('a small shrine, soft lighting','中文'),@('银发女性, blue eyes','英文'),@('soft light, masterpiece, 高清','中文'))) {
        if ((Get-TranslationTarget $case[0]) -ne $case[1]) { throw 'Translation direction detection failed.' }
    }
    if ($null -ne (Get-TranslationTarget '12345, !')) { throw 'Non-language content should not be translated.' }
    Write-Output 'BIDIRECTIONAL_TRANSLATION_DETECTION_OK'
    $headerWidthBackup=$form.Width
    try {
        foreach ($testWidth in @(960,1220,1688)) {
            $form.Width=$testWidth; Set-HeaderFooterLayout
            if ($btnRefresh.Bounds.IntersectsWith($model.Bounds)) { throw 'Header controls overlap.' }
            if ($btnRefresh.Right -gt $header.ClientSize.Width) { throw 'Header controls extend outside the window.' }
            if ($btnRefresh.Left -ne $model.Right+30 -or $btnRefresh.Top -ne $model.Top -or $btnRefresh.Height -ne $model.Height) { throw 'Restart button must follow model selector with a 30px gap.' }
            if ($model.Left -ne ($body.Left+$right.Left) -or $modelLabel.Left -ne $model.Left) { throw 'Model selector does not align with preview column.' }
            Set-TabHeaderLayout
            $form.PerformLayout()
            if ($model.Left -ne ($body.Left+$right.Left) -or $model.Width -ne [Math]::Floor([Math]::Max(200,$right.ClientSize.Width-$right.Padding.Right)/2)) { throw ("width={0} model={1}/{2} preview={3}/{4}" -f $testWidth,$model.PointToScreen([Drawing.Point]::Empty).X,$model.Width,$preview.PointToScreen([Drawing.Point]::Empty).X,$preview.Width) }
            if ($resultTitle.Bottom -ne $tabs.DisplayRectangle.Top) { throw 'Preview and tab content start at different heights.' }
            $lastTab=$tabs.GetTabRect(2)
            if ($lastTab.Right -lt $tabs.ClientSize.Width-6 -or $lastTab.Right -gt $tabs.ClientSize.Width) { throw 'Tab headers do not fill the left column.' }
            if ($tabs.GetTabRect(0).Width -ne $tabs.GetTabRect(1).Width -or $tabs.GetTabRect(1).Width -ne $lastTab.Width) { throw 'Tab headers must have equal widths.' }
        }
    } finally { $form.Width=$headerWidthBackup; Set-HeaderFooterLayout }
    $tabs.SelectedTab=$creationPage
    $script:assistantModelsLoaded=$false; $script:assistantRefreshCalls=0
    Write-Output 'MODEL_PREVIEW_ALIGNMENT_AND_FULL_WIDTH_TABS_OK'
    $script:randomPresetGroups=@()
    $model.SelectedIndex=0; $mode.SelectedIndex=0
    Restore-Settings ([pscustomobject]@{model=$models[2].id; mode=0; steps=37; cfg=6.2; count=2; prompt='test'; output=$env:TEMP; seed='42'})
    if ($steps.Value -ne 37 -or $cfg.Value -ne 6.2 -or $model.SelectedIndex -ne 2) { throw 'Saved numeric settings were overwritten by model defaults.' }
    if ($mode.Enabled) { throw 'Text-only model must disable image mode selection.' }
    $mode.SelectedIndex=1
    if ($mode.SelectedIndex -ne 0) { throw 'Unsupported image mode entered programmatically.' }
    $asMode.SelectedIndex=3
    if ($asMode.SelectedIndex -ne 0) { throw 'Assistant entered unsupported image mode.' }
    $model.SelectedIndex=0
    if (-not $mode.Enabled) { throw 'Image mode did not become available.' }
    Write-Output 'RESTORE_SETTINGS_AND_MODEL_CAPABILITY_OK'

    $settingsTest=Join-Path ([IO.Path]::GetTempPath()) ('workbench-settings-'+[guid]::NewGuid().ToString('N')+'.json')
    try {
        Write-SettingsFile $settingsTest @{value='first'}
        Write-SettingsFile $settingsTest @{value='second'}
        if ((Get-Content -LiteralPath $settingsTest -Raw | ConvertFrom-Json).value -ne 'second') { throw 'Atomic settings replacement failed.' }
        $held=[IO.File]::Open($settingsTest,'Open','Read','None')
        $failed=$false
        try { Write-SettingsFile $settingsTest @{value='should not replace'} } catch { $failed=$true } finally { $held.Dispose() }
        if (-not $failed -or (Get-Content -LiteralPath $settingsTest -Raw | ConvertFrom-Json).value -ne 'second') { throw 'Failed save must report error and preserve previous settings.' }
    } finally { Remove-Item -LiteralPath $settingsTest -ErrorAction SilentlyContinue }
    Write-Output 'ATOMIC_SETTINGS_FAILURE_PRESERVES_DATA_OK'
    $actualSettingsFile=$settingsFile
    $draftTest=Join-Path ([IO.Path]::GetTempPath()) ('workbench-draft-'+[guid]::NewGuid().ToString('N')+'.json')
    $actualPrompt=$prompt.Text; $actualSeed=$seed.Text
    try {
        $settingsFile=$draftTest; $script:autoSaveReady=$true
        $prompt.Text='next task draft'; $seed.Text='1234'
        if (-not $autoSaveTimer.Enabled -or -not $script:settingsDirty -or (Test-Path -LiteralPath $draftTest)) { throw 'Draft changes must schedule a delayed save, not immediately write.' }
        $tick=[Windows.Forms.Timer].GetMethod('OnTick',[Reflection.BindingFlags]'Instance,NonPublic')
        $null=$tick.Invoke($autoSaveTimer,@([EventArgs]::Empty))
        $restored=Get-Content -LiteralPath $draftTest -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($restored.prompt -ne 'next task draft' -or $restored.seed -ne '1234' -or $script:settingsDirty -or $autoSaveTimer.Enabled) { throw 'Delayed draft save did not persist prompt and settings.' }
        $savedDraft=[IO.File]::ReadAllText($draftTest)
        $held=[IO.File]::Open($draftTest,'Open','Read','None')
        try { $prompt.Text='later draft'; Save-PendingDraft } finally { $held.Dispose() }
        if (-not $script:settingsDirty -or [IO.File]::ReadAllText($draftTest) -ne $savedDraft -or $draftStatus.Text -ne '草稿自动保存失败') { throw 'Draft save failure must preserve saved file and keep unsaved state.' }
        Save-PendingDraft
        if ($script:settingsDirty -or (Get-Content -LiteralPath $draftTest -Raw -Encoding UTF8 | ConvertFrom-Json).prompt -ne 'later draft') { throw 'Draft retry did not persist latest edits.' }
    } finally {
        $script:autoSaveReady=$false; $script:settingsDirty=$false; $autoSaveTimer.Stop()
        $settingsFile=$actualSettingsFile; $prompt.Text=$actualPrompt; $seed.Text=$actualSeed; $draftStatus.Text=''
        Remove-Item -LiteralPath $draftTest -ErrorAction SilentlyContinue
    }
    Write-Output 'DEBOUNCED_DRAFT_SAVE_FAILURE_PRESERVATION_AND_RETRY_OK'

    $prompt.Text="mountain`r`n`r`nsunset"; $batchCount.Value=50
    $null=Get-Config
    Update-BatchSummary
    if ($batchSummary.Text -notmatch '= 100') { throw 'Batch summary does not match task count.' }
    $batchCount.Value=1000
    $largeConfig=Get-Config
    Update-BatchSummary
    if ($largeConfig.count -ne 1000 -or $batchSummary.Text -notmatch '= 2000') { throw 'Large batch rejected or displayed incorrectly.' }
    $savedMode=$mode.SelectedIndex
    Restore-Settings ([pscustomobject]@{model=$models[0].id; mode=0; count=1000; prompt=$prompt.Text; output=$output.Text; seed=$seed.Text})
    if ($batchCount.Value -ne 1000) { throw 'Large batch count was not restored.' }
    $mode.SelectedIndex=1; $failed=$false
    try { $null=Get-Config } catch { $failed=$_.Exception.Message -like '*一段*' }
    if (-not $failed) { throw 'Edit must reject multiple prompt segments.' }
    $mode.SelectedIndex=0; $batchCount.Value=1
    Write-Output 'LARGE_BATCH_COUNT_RESTORE_AND_EDIT_SEGMENTS_OK'

    $shared="soft lighting`r`nsoft lighting, watercolor`r`nsoft lighting"
    $removed=Remove-FixedPresetText $shared 'soft lighting'
    if (-not $removed.Contains('soft lighting, watercolor') -or ($removed -split "`r`n" | Where-Object {$_ -eq 'soft lighting'}).Count -ne 1) { throw 'Preset removal damaged overlapping or duplicate blocks.' }
    if ((Remove-FixedPresetText 'manual soft lighting change' 'soft lighting') -ne 'manual soft lighting change') { throw 'Preset removal damaged hand-edited text.' }
    Write-Output 'PRESET_WHOLE_BLOCK_REMOVAL_OK'

    $galleryTest=Join-Path ([IO.Path]::GetTempPath()) ('workbench-gallery-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $galleryTest
    try {
        $paths=@(1..3 | ForEach-Object { Join-Path $galleryTest ($_.ToString()+'.png') })
        $bitmap=New-Object Drawing.Bitmap(8,8)
        try { foreach ($path in $paths) { $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png) } } finally { $bitmap.Dispose() }
        Add-ResultFiles @($paths[0],$paths[1])
        if ($script:resultIndex -ne 1 -or $script:lastFile -ne $paths[1]) { throw 'Gallery did not follow latest result.' }
        $broken=Join-Path $galleryTest 'broken.png'
        [IO.File]::WriteAllText($broken,'not a valid image')
        try {
            $null=Get-GalleryImages $galleryTest -Refresh
            Update-FolderGallery $galleryTest | Out-Null
            $beforeBad=$preview.Image
            Show-Result ([Array]::IndexOf($script:resultFiles,$broken))
            if ($script:lastFile -ne $paths[1] -or -not [object]::ReferenceEquals($beforeBad,$preview.Image) -or $statusLabel.Text -notlike '*读取失败*') { throw 'Unreadable image changed selected file or visible image.' }
        } finally { Remove-Item -LiteralPath $broken }
        Update-FolderGallery $galleryTest | Out-Null
        $cacheKey=([IO.Path]::GetFullPath($galleryTest).TrimEnd('\','/')+'\')
        $cacheBefore=$script:galleryCache[$cacheKey]
        $null=Get-GalleryImages $galleryTest
        $null=Get-GalleryImages $galleryTest
        if (-not [object]::ReferenceEquals($cacheBefore,$script:galleryCache[$cacheKey])) { throw 'Unchanged folder was unnecessarily rescanned.' }
        $external=Join-Path $galleryTest '4.png'
        $bitmap=New-Object Drawing.Bitmap(8,8)
        try { $bitmap.Save($external,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
        try { if ($external -notin @(Get-GalleryImages $galleryTest)) { throw 'Folder cache missed externally added image.' } }
        finally { Remove-Item -LiteralPath $external }
        if ($external -in @(Get-GalleryImages $galleryTest)) { throw 'Folder cache retained externally deleted image.' }
        Update-FolderGallery $galleryTest | Out-Null
        Write-Output 'UNREADABLE_IMAGE_PRESERVES_SELECTION_AND_FOLDER_CACHE_REFRESH_OK'
        Show-Result 0
        $script:manualGalleryBrowse=$true
        Add-ResultFiles @($paths[0],$paths[1],$paths[2])
        if ($script:resultIndex -ne 0 -or $script:lastFile -ne $paths[0] -or $script:resultFiles.Count -ne 3) { throw 'Incoming result interrupted browsing or duplicated entries.' }
        if ($latestPreview.Tag -ne $paths[2]) { throw 'Previously scanned file was ignored when its generation status arrived.' }
        $thumbnailBefore=$latestPreview.Image
        Add-ResultFiles @($paths[0],$paths[1],$paths[2])
        if (-not [object]::ReferenceEquals($thumbnailBefore,$latestPreview.Image)) { throw 'Repeated generation status reloaded existing thumbnail.' }
        Write-Output 'SCANNED_OUTPUT_ACKNOWLEDGEMENT_AND_STATUS_DEDUPLICATION_OK'
        Show-Result 2
        $extraPath=Join-Path $galleryTest '10.png'
        $bitmap=New-Object Drawing.Bitmap(8,8)
        try { $bitmap.Save($extraPath,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
        try {
            Add-ResultFiles @($extraPath)
            if ($script:lastFile -ne $paths[2] -or -not $latestPreview.Image -or $latestPreview.Tag -ne $extraPath) { throw 'Manual browsing must retain main preview and update thumbnail.' }
            Move-Result 1
            if ($script:lastFile -ne $extraPath -or $script:resultIndex -ne 3) { throw 'Folder navigation must include other numbered images in numeric order.' }
            Move-Result -1
            if ($script:lastFile -ne $paths[2]) { throw 'Previous folder image incorrect.' }
            Resume-LatestPreview
            if ($script:lastFile -ne $extraPath -or $script:manualGalleryBrowse) { throw 'Return to current did not restore latest generation and automatic following.' }
            $newestPath=Join-Path $galleryTest '11.png'
            $bitmap=New-Object Drawing.Bitmap(8,8)
            try { $bitmap.Save($newestPath,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
            try {
                Add-ResultFiles @($newestPath)
                if ($script:lastFile -ne $newestPath) { throw 'New generation did not follow after returning to current.' }
            } finally { Remove-Item -LiteralPath $newestPath }
            $script:manualGalleryBrowse=$true
            Write-Output 'RETURN_CURRENT_AND_RESUME_NEW_IMAGES_OK'
        } finally { Remove-Item -LiteralPath $extraPath }
        Update-FolderGallery $galleryTest | Out-Null
        Show-Result 2
        if ($nextResult.Enabled -or -not $previousResult.Enabled) { throw 'Gallery bounds incorrect.' }
        $script:manualGalleryBrowse=$false
        $previewClick=[Windows.Forms.Control].GetMethod('OnMouseClick',[Reflection.BindingFlags]'Instance,NonPublic')
        $click=New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left,1,([int]($preview.Width/2)),([int]($preview.Height/2)),0)
        $null=$previewClick.Invoke($preview,@($click.PSObject.BaseObject))
        if (-not $script:imageViewer) { throw 'Clicking main preview image did not open large viewer.' }
        Write-Output 'MAIN_PREVIEW_CLICK_OPENS_LARGE_VIEWER_OK'
        if ($script:manualGalleryBrowse) { throw 'Opening viewer changed main auto-follow state.' }
        $viewerTest=$script:imageViewer
        if (-not $viewerTest -or -not $viewerTest.Tag.Picture.Image -or $viewerTest.Tag.Next.Enabled) { throw 'Large viewer did not load current image or respect bounds.' }
        $viewerTest.Tag.OriginalButton.PerformClick()
        if ($viewerTest.Tag.Picture.ImageBounds.Size -ne $viewerTest.Tag.Picture.Image.Size -or $viewerTest.Tag.ScaleLabel.Text -ne '100%') { throw 'Original size must display one image pixel per screen pixel.' }
        $viewerTest.Tag.FitButton.PerformClick()
        if ($viewerTest.Tag.Zoom -ne 1 -or $viewerTest.Tag.Picture.ImageBounds.Width -gt $viewerTest.Tag.Picture.Width -or $viewerTest.Tag.Picture.ImageBounds.Height -gt $viewerTest.Tag.Picture.Height) { throw 'Fit window did not contain full image.' }
        Write-Output 'FIT_WINDOW_ORIGINAL_SIZE_AND_SCALE_INDICATOR_OK'
        Show-LargeImageViewer
        if ($script:imageViewer -ne $viewerTest) { throw 'Large viewer opened duplicate window.' }
        $viewerTest.Tag.Previous.PerformClick()
        if ($script:lastFile -ne $paths[2] -or $viewerTest.Text -notlike '*2.png*' -or $script:manualGalleryBrowse) { throw 'Large viewer navigation changed main preview or auto-follow state.' }
        $zoomWidth=$viewerTest.Tag.Picture.ImageBounds.Width
        Zoom-LargeImage 120 (New-Object Drawing.Point(200,200))
        if ($viewerTest.Tag.Zoom -le 1 -or $viewerTest.Tag.Picture.ImageBounds.Width -le $zoomWidth) { throw ("zoom={0} width={1} old={2} size={3}" -f $viewerTest.Tag.Zoom,$viewerTest.Tag.Picture.ImageBounds.Width,$zoomWidth,$viewerTest.Tag.Pane.Size) }
        Update-LargeImageViewer
        if ($viewerTest.Tag.Zoom -le 1) { throw 'Refreshing same image reset zoom.' }
        Zoom-LargeImage -120 (New-Object Drawing.Point(200,200))
        if ([Math]::Abs($viewerTest.Tag.Zoom-1) -gt 0.001) { throw 'Wheel zoom out did not restore scale.' }
        Zoom-LargeImage 120000 (New-Object Drawing.Point(200,200))
        if ($viewerTest.Tag.Zoom -ne 16) { throw 'Zoom upper limit failed.' }
        Zoom-LargeImage -120000 (New-Object Drawing.Point(200,200))
        if ($viewerTest.Tag.Zoom -ne 0.1) { throw 'Zoom lower limit failed.' }
        $viewerTest.Tag.Next.PerformClick()
        if ($viewerTest.Tag.Zoom -ne 1) { throw 'Switching image must fit new image to window.' }
        Write-Output 'LARGE_VIEWER_ZOOM_IN_OUT_LIMITS_AND_RESET_OK'
        $canvas=$viewerTest.Tag.Picture
        $canvasSize=$canvas.Size; $imageBefore=$canvas.Image
        $buffered=[Windows.Forms.Control].GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($canvas,$null)
        if (-not $buffered -or $canvas.Controls.Count) { throw 'Zoom canvas must buffer a single surface without resizing child controls.' }
        $wheelMethod=$canvas.GetType().GetMethod('OnMouseWheel',[Reflection.BindingFlags]'Instance,NonPublic')
        foreach ($delta in @(120,120,120,-120,-120,-120)) {
            $wheelEvent=New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::None,0,400,300,$delta)
            $null=$wheelMethod.Invoke($canvas,@($wheelEvent.PSObject.BaseObject))
            [Windows.Forms.Application]::DoEvents()
            if ($canvas.Size -ne $canvasSize -or -not [object]::ReferenceEquals($canvas.Image,$imageBefore)) { throw 'Wheel input resized canvas or recreated source image.' }
            if (-not $canvas.Visible) { throw 'Zoom transaction left image canvas hidden.' }
        }
        if ([Math]::Abs($viewerTest.Tag.Zoom-1) -gt 0.001) { throw 'Wheel event applied duplicate zoom or scrolling.' }
        Write-Output 'BUFFERED_CANVAS_REAL_WHEEL_EVENTS_AND_STABLE_SURFACE_OK'
        $independentNew=Join-Path $galleryTest '12.png'
        $bitmap=New-Object Drawing.Bitmap(8,8)
        try { $bitmap.Save($independentNew,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
        try {
            Add-ResultFiles @($independentNew)
            if ($script:lastFile -ne $independentNew -or $viewerTest.Tag.ImagePath -ne $paths[2] -or $script:manualGalleryBrowse) { throw 'New main image changed independent viewer or stopped automatic following.' }
            Show-Result 0
            if ($viewerTest.Tag.ImagePath -ne $paths[2]) { throw 'Main navigation changed independent viewer.' }
        } finally { Remove-Item -LiteralPath $independentNew }
        Update-FolderGallery $galleryTest | Out-Null
        Show-Result 2
        Write-Output 'LARGE_VIEWER_AND_MAIN_STATE_FULLY_INDEPENDENT_OK'
        $canvas=$viewerTest.Tag.Picture
        $mouseClick=$canvas.GetType().GetMethod('OnMouseClick',[Reflection.BindingFlags]'Instance,NonPublic')
        foreach ($case in @(@(0.25,[Windows.Forms.MouseButtons]::Left,$paths[1]),@(0.75,[Windows.Forms.MouseButtons]::Right,$paths[1]),@(0.75,[Windows.Forms.MouseButtons]::Left,$paths[2]),@(0.75,[Windows.Forms.MouseButtons]::Left,$paths[2]))) {
            $clickEvent=New-Object Windows.Forms.MouseEventArgs($case[1],1,([int]($canvas.ClientSize.Width*$case[0])),100,0)
            $null=$mouseClick.Invoke($canvas,@($clickEvent.PSObject.BaseObject))
            if ($viewerTest.Tag.ImagePath -ne $case[2] -or $script:lastFile -ne $paths[2] -or $script:manualGalleryBrowse) { throw 'Image half-click navigation changed incorrect image or main state.' }
        }
        Write-Output 'IMAGE_HALF_CLICK_NAVIGATION_BOUNDARY_AND_INDEPENDENCE_OK'
        $viewerTest.Tag.Zoom=3.0; Set-LargeImageLayout
        $canvas.AutoScrollPosition=New-Object Drawing.Point(300,300)
        $before=$canvas.ImageBounds
        $fx=(240-$before.X)/[double]$before.Width; $fy=(200-$before.Y)/[double]$before.Height
        Zoom-LargeImage 120 (New-Object Drawing.Point(240,200))
        $after=$canvas.ImageBounds
        if ([Math]::Abs(($after.X+$fx*$after.Width)-240) -gt 2 -or [Math]::Abs(($after.Y+$fy*$after.Height)-200) -gt 2) { throw 'Zoom did not preserve image point beneath cursor.' }
        $scrollBefore=$canvas.AutoScrollPosition; $viewerPathBefore=$viewerTest.Tag.ImagePath
        foreach ($event in @(@('OnMouseDown',240,200),@('OnMouseMove',200,170),@('OnMouseUp',200,170),@('OnMouseClick',200,170))) {
            $argsEvent=New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left,1,$event[1],$event[2],0)
            $method=$canvas.GetType().GetMethod($event[0],[Reflection.BindingFlags]'Instance,NonPublic')
            $null=$method.Invoke($canvas,@($argsEvent.PSObject.BaseObject))
        }
        if ($canvas.AutoScrollPosition.X -ne $scrollBefore.X-40 -or $canvas.AutoScrollPosition.Y -ne $scrollBefore.Y-30) { throw 'Dragging did not move image with pointer.' }
        if ($viewerTest.Tag.ImagePath -ne $viewerPathBefore -or $canvas.Capture) { throw 'Drag release triggered navigation or retained capture.' }
        $viewerTest.Tag.Zoom=1.0; Set-LargeImageLayout
        $keyboardIndex=$viewerTest.Tag.Index
        $processKey=[Windows.Forms.Control].GetMethod('ProcessKeyMessage',[Reflection.BindingFlags]'Instance,NonPublic')
        try {
            foreach ($target in @($viewerTest.Tag.Picture,$viewerTest.Tag.Previous,$viewerTest.Tag.Next,$viewerTest.Tag.Delete,$viewerTest.Tag.FitButton,$viewerTest.Tag.OriginalButton)) {
                $viewerTest.Tag.Index=1; Update-LargeImageViewer
                $null=$target.Focus()
                foreach ($keyCase in @(@(37,0),@(39,1))) {
                    $message=[Windows.Forms.Message]::Create($target.Handle,0x100,[IntPtr]$keyCase[0],[IntPtr]::Zero)
                    $state=$target.PreProcessControlMessage([ref]$message)
                    if ($state -ne [Windows.Forms.PreProcessControlState]::MessageNeeded) { throw ('Arrow key swallowed by '+$target.GetType().Name) }
                    $args=[object[]]@($message)
                    if (-not $processKey.Invoke($target,$args) -or $viewerTest.Tag.Index -ne $keyCase[1]) { throw ('Arrow key did not navigate once from '+$target.GetType().Name) }
                    if ($script:lastFile -ne $paths[2] -or $script:manualGalleryBrowse) { throw 'Viewer keyboard navigation changed main preview.' }
                }
            }
            $viewerTest.Tag.Index=0; Update-LargeImageViewer
            $target=$viewerTest.Tag.Picture
            $message=[Windows.Forms.Message]::Create($target.Handle,0x100,[IntPtr]37,[IntPtr]::Zero)
            $null=$target.PreProcessControlMessage([ref]$message)
            $null=$processKey.Invoke($target,[object[]]@($message))
            if ($viewerTest.Tag.Index -ne 0) { throw 'Left arrow crossed first-image boundary.' }
        } finally { $viewerTest.Tag.Index=$keyboardIndex; Update-LargeImageViewer }
        Write-Output 'VIEWER_NATIVE_ARROW_KEY_PIPELINE_CANVAS_BUTTON_FOCUS_AND_BOUNDARY_OK'

        Write-Output 'CURSOR_ANCHORED_ZOOM_AND_DRAG_WITHOUT_PAGE_CHANGE_OK'
        if ($ScreenshotPath) {
            $snapshot=New-Object Drawing.Bitmap($viewerTest.Width,$viewerTest.Height)
            try { $viewerTest.DrawToBitmap($snapshot,(New-Object Drawing.Rectangle(0,0,$viewerTest.Width,$viewerTest.Height))); $snapshot.Save(($ScreenshotPath+'.viewer.png'),[Drawing.Imaging.ImageFormat]::Png) } finally { $snapshot.Dispose() }
        }
        $viewerTest.Close()
        if ($script:imageViewer) { throw 'Large viewer failed to clean up.' }
        Write-Output 'LARGE_VIEWER_LOCAL_NAVIGATION_AND_REUSE_OK'
        Show-LargeImageViewer
        $recycleFunction=${function:Move-ImageToRecycleBin}
        try {
            function Move-ImageToRecycleBin([string]$path) { throw 'simulated recycle failure' }
            Remove-CurrentResult
            if ($script:lastFile -ne $paths[2] -or -not (Test-Path -LiteralPath $paths[2])) { throw 'Failed deletion changed gallery or original file.' }
            $recycleTest=Join-Path $galleryTest 'recycled'
            $null=New-Item -ItemType Directory -Path $recycleTest
            function Move-ImageToRecycleBin([string]$path) { Move-Item -LiteralPath $path -Destination $recycleTest -ErrorAction Stop }
            Remove-CurrentResult
            if ($script:lastFile -ne $paths[1] -or $script:resultFiles.Count -ne 2) { throw 'Deleting last image must show preceding image.' }
            Add-ResultFiles @($paths[2])
            if ($script:resultFiles.Count -ne 2) { throw 'Worker status resurrected deleted image.' }
            Show-Result 0
            Remove-CurrentResult
            if ($script:lastFile -ne $paths[1] -or $script:resultFiles.Count -ne 1) { throw 'Deleting first image must show following image.' }
            Remove-CurrentResult
            if ($script:lastFile -or $preview.Image -or $deleteResult.Enabled -or $script:resultFiles.Count) { throw 'Deleting only image must clear gallery and disable delete.' }
            if (-not $script:imageViewer.Tag.Picture.Image) { throw 'Main gallery deletion changed independent viewer.' }
            Write-Output 'GALLERY_DELETE_FAILURE_ADJACENT_EMPTY_AND_STALE_STATUS_OK'
        } finally {
            if ($script:imageViewer) { $script:imageViewer.Close() }
            Set-Item Function:Move-ImageToRecycleBin $recycleFunction
            if (Test-Path -LiteralPath $recycleTest) { foreach ($testFile in Get-ChildItem -LiteralPath $recycleTest -File) { Remove-Item -LiteralPath $testFile.FullName }; Remove-Item -LiteralPath $recycleTest }
        }
    } finally {
        if ($preview.Image) { $preview.Image.Dispose(); $preview.Image=$null }
        foreach ($path in $paths) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $galleryTest -ErrorAction SilentlyContinue
        $script:resultFiles=@(); $script:resultIndex=-1
$script:manualGalleryBrowse=$false; $script:lastFile=$null
        $previousResult.Enabled=$false; $nextResult.Enabled=$false
    }
    Write-Output 'RESULT_GALLERY_NAVIGATION_OK'

    $form.Show(); $form.PerformLayout(); [System.Windows.Forms.Application]::DoEvents()
    if ($latestPreview.Bottom -gt $resultBottom.ClientSize.Height -or $resultPath.Right -gt $latestPreview.Left) { throw 'Thumbnail clipped or overlapped by output path.' }
    $tabs.SelectedIndex = 0
    $mode.SelectedIndex = 0
    $prompt.Text = "山间古祠`r`n`r`n海边日落"
    $batchCount.Value = 3
    $batchConfig = Get-Config
    if ($batchConfig.prompts.Count -ne 2 -or $batchConfig.count -ne 3) { throw '多段批量生成配置错误。' }
    $batchCount.Value = 1
    if ($chooseFixedPresets -isnot [System.Windows.Forms.Button] -or $ldgCharacter.Parent -ne $creationPage -or $chooseFixedPresets.Parent -ne $creationPage -or $ldgCharacter.Right -ge $chooseFixedPresets.Left -or $ldgCharacter.Top -ne $chooseFixedPresets.Top -or $chooseFixedPresets.Right -gt $fixedPrompt.Right) { throw 'Preset buttons are not aligned in the preset row.' }
    $script:presetButtonOpened=$false
    $buttonTimer=New-Object Windows.Forms.Timer
    $buttonTimer.Interval=150
    $buttonTimer.Add_Tick({
        $buttonTimer.Stop()
        $dialog=[Windows.Forms.Application]::OpenForms | Where-Object {$_.Text -eq '组合预设'} | Select-Object -First 1
        if ($dialog) { $script:presetButtonOpened=$true; $dialog.DialogResult='Cancel'; $dialog.Close() }
    })
    try { $buttonTimer.Start(); $chooseFixedPresets.PerformClick() } finally { $buttonTimer.Dispose() }
    if (-not $script:presetButtonOpened) { throw 'Preset button did not open the dialog.' }
    Write-Output 'PRESET_ROW_BUTTONS_AND_DIALOG_OK'
    if ((Get-FolderPathKey 'D:\example\child\..\') -ne (Get-FolderPathKey 'D:\example')) { throw '文件夹路径归一化失败。' }
    $shellTest=New-Object -ComObject Shell.Application
    $testWindows=$shellTest.Windows()
    try {
        for ($windowIndex=0; $windowIndex -lt $testWindows.Count; $windowIndex++) {
            $candidateWindow=$testWindows.Item($windowIndex)
            try {
                if ([IO.Path]::GetFileName($candidateWindow.FullName) -ine 'explorer.exe') { continue }
                $candidatePath=[string]$candidateWindow.Document.Folder.Self.Path
                if (-not [IO.Path]::IsPathRooted($candidatePath) -or -not (Test-Path -LiteralPath $candidatePath -PathType Container)) { continue }
                if ((Find-OpenFolderWindow $candidatePath) -eq [IntPtr]::Zero) { throw '未识别已打开的文件夹窗口。' }
                Write-Output 'EXISTING_EXPLORER_WINDOW_FOUND_OK'
                break
            } finally { $null=[Runtime.InteropServices.Marshal]::ReleaseComObject($candidateWindow) }
        }
    } finally {
        $null=[Runtime.InteropServices.Marshal]::ReleaseComObject($testWindows)
        $null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shellTest)
    }
    Write-Output 'FOLDER_REUSE_PATH_CHECK_OK'

    $savedPromptText=$prompt.Text; $savedFixedText=$fixedPrompt.Text
    $prompt.Text=''; $fixedPrompt.Text='a peaceful mountain landscape'
    $presetOnly=Get-Config
    if ($presetOnly.prompt -ne 'a peaceful mountain landscape' -or $presetOnly.prompts) { throw '仅预设生成失败。' }
    $fixedPrompt.Text='   '
    $rejected=$false
    try { $null=Get-Config } catch { $rejected=$true }
    if (-not $rejected) { throw '两栏空白应给出提示。' }
    $prompt.Text=$savedPromptText; $fixedPrompt.Text=$savedFixedText
    if ($fixedPrompt.Bottom -ge $prompt.Top -or $prompt.Bottom -ge $negPrompt.Top) { throw '预设未排到最上方。' }
    Write-Output 'PRESET_ONLY_GENERATION_OK'
    $nameTestLibrary=Join-Path $env:TEMP ('workbench-role-names-'+[guid]::NewGuid().ToString('N')+'.json')
    $nameOriginalLibrary=$characterLibraryFile; $nameOriginalFixed=$fixedPrompt.Text
    try {
        [IO.File]::WriteAllText($nameTestLibrary,'{"female":{"test":[{"cn":"银狼","en":"silver wolf (honkai: star rail)"},{"cn":"卡芙卡","en":"kafka (honkai: star rail)"}]},"male":{}}',[Text.UTF8Encoding]::new($false))
        $characterLibraryFile=$nameTestLibrary
        $fixedPrompt.Text='silver wolf (honkai: star rail)'
        $roleNamingConfig=Get-Config
        if ($roleNamingConfig.output_characters.Count -ne 1 -or $roleNamingConfig.output_characters[0].name -ne '银狼') { throw 'Role output name missing from task snapshot.' }
        $fixedPrompt.Text='kafka (honkai: star rail)'
        if ($roleNamingConfig.output_characters[0].name -ne '银狼' -or (Get-Config).output_characters[0].name -ne '卡芙卡') { throw 'Changing selected role mutated queued naming snapshot.' }
        $candidates=@(Get-OutputCharacterPresets '' @(@{choices=@('silver wolf (honkai: star rail)','kafka (honkai: star rail)')}))
        if ($candidates.Count -ne 2) { throw 'Random role naming candidates missing.' }
        $fixedPrompt.Text='manual scenery'
        if ((Get-Config).output_characters.Count) { throw 'Removed role still controls output name.' }
    } finally {
        $characterLibraryFile=$nameOriginalLibrary; $fixedPrompt.Text=$nameOriginalFixed
        Remove-Item -LiteralPath $nameTestLibrary -ErrorAction SilentlyContinue
    }
    Write-Output 'CHARACTER_FILENAME_CONFIG_SNAPSHOT_RANDOM_AND_REMOVAL_OK'



    $mode.SelectedIndex = 0; $prompt.Text = '当前任务'; $seed.Text = '42'
    $submitted = Get-Config
    $snapshot = Join-Path ([IO.Path]::GetTempPath()) ('qwen-request-check-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($snapshot, ($submitted | ConvertTo-Json -Depth 10))
        Set-GenerationBusy $true
        if (-not $prompt.Enabled -or -not $model.Enabled -or -not $steps.Enabled -or -not $asFill.Enabled -or $generate.Enabled -or $btnRefresh.Enabled) { throw '生成中编辑状态错误。' }
        $prompt.Text = '下一次任务'; $steps.Value = 35; $seed.Text = '123'
        $pending = Get-Config
        $stored = [IO.File]::ReadAllText($snapshot) | ConvertFrom-Json
        if ($stored.prompt -ne $submitted.prompt -or $stored.steps -ne $submitted.steps -or $stored.seed -ne 42 -or $pending.prompt -notlike '下一次任务*' -or $pending.steps -ne 35 -or $pending.seed -ne 123) { throw '任务配置未正确隔离。' }
    } finally {
        Set-GenerationBusy $false
        Remove-Item -LiteralPath $snapshot -ErrorAction SilentlyContinue
    }
    Write-Output 'EDIT_DURING_GENERATION_SNAPSHOT_OK'
    $fixedBackup = $fixedPrompt.Text
    $styleBackup = $presetStyle.SelectedIndex; $characterBackup = $presetCharacter.SelectedIndex
    $presetStyle.SelectedIndex = 0; $presetCharacter.SelectedIndex = 0; $fixedPrompt.Text = 'custom scenery'
    $presetStyle.SelectedIndex = 2; $presetCharacter.SelectedIndex = 2
    if (-not $fixedPrompt.Text.Contains($stylePresetTexts[2]) -or -not $fixedPrompt.Text.Contains($characterPresetTexts[2])) { throw '画风人物合并失败。' }
    $presetStyle.SelectedIndex = 3
    if ($fixedPrompt.Text.Contains($stylePresetTexts[2]) -or -not $fixedPrompt.Text.Contains($characterPresetTexts[2])) { throw '画风切换误改其他片段。' }
    $presetCharacter.SelectedIndex = 0
    if ($fixedPrompt.Text.Contains($characterPresetTexts[2]) -or -not $fixedPrompt.Text.Contains($stylePresetTexts[3])) { throw '人物移除误改画风。' }
    $presetStyle.SelectedIndex = $styleBackup; $presetCharacter.SelectedIndex = $characterBackup; $fixedPrompt.Text = $fixedBackup
    Write-Output 'SPLIT_FIXED_PRESETS_REBUILD_OK'
    if (-not $characterPresetTexts[2].Contains('dragon girl') -or $characterPresetTexts[2].Contains('high key lighting') -or $characterPresetTexts[2].Contains($stylePresetTexts[1])) { throw '龙娘人物预设仍混入画风。' }
    if ($legacyFixedPresets[6] -ne ($characterPresetTexts[2] + ', ' + $stylePresetTexts[1])) { throw '龙娘与画风拆分遗漏原有关键词。' }
    Write-Output 'DRAGON_CHARACTER_STYLE_SEPARATION_OK'

    $fixedBackup = $fixedPrompt.Text
    $keysBackup = @($script:selectedFixedKeys); $appliedBackup = $script:fixedAppliedTexts.Clone()
    $script:selectedFixedKeys=@(); $script:fixedAppliedTexts=@{}; $fixedPrompt.Text='custom scenery'
    Set-FixedPresetSelection @('style:2','style:3','expression:1','expression:2')
    if ($script:selectedFixedKeys.Count -ne 4 -or -not $fixedPrompt.Text.Contains($stylePresetTexts[2]) -or -not $fixedPrompt.Text.Contains($stylePresetTexts[3])) { throw '同类预设多选失败。' }
    $beforeApply=$fixedPrompt.Text
    Set-FixedPresetSelection @('style:2','style:3','expression:1','expression:2')
    if ($fixedPrompt.Text -ne $beforeApply) { throw '重复应用导致内容重复。' }
    Set-FixedPresetSelection @('style:3')
    if ($fixedPrompt.Text.Contains($stylePresetTexts[2]) -or -not $fixedPrompt.Text.Contains('custom scenery') -or -not $fixedPrompt.Text.Contains($stylePresetTexts[3])) { throw '取消勾选误改其他内容。' }
    Set-FixedPresetSelection @()
    if ($fixedPrompt.Text -ne 'custom scenery') { throw '取消全部预设失败。' }
    $script:selectedFixedKeys=$keysBackup; $script:fixedAppliedTexts=$appliedBackup; $fixedPrompt.Text=$fixedBackup; Update-FixedPresetCaption
    Write-Output 'MULTI_PRESET_SELECTION_OK'
    $selectionText=$fixedPrompt.Text; $selectionKeys=@($script:selectedFixedKeys)
    $selectionApplied=$script:fixedAppliedTexts.Clone(); $characterApplied=$script:characterAppliedTexts.Clone()
    $catalogBackup=@($fixedChoices)
    try {
        $script:selectedFixedKeys=@(); $script:fixedAppliedTexts=@{}; $fixedPrompt.Text='custom scenery'
        Set-FixedPresetSelection @('style:2','expression:1')
        $fixedPrompt.Text=$fixedPrompt.Text.Replace("`r`n",', ')
        $cancelTimer=New-Object Windows.Forms.Timer; $cancelTimer.Interval=150
        $script:cancelPresetError=$null
        $cancelTimer.Add_Tick({
            $cancelTimer.Stop()
            $dialog=@([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq '组合预设' })[0]
            try {
                if (-not $dialog) { throw 'Combination preset dialog did not open.' }
                $pending=@($dialog.Controls); $styleList=$null
                while ($pending.Count) {
                    $control=$pending[0]
                    $pending=@($pending | Select-Object -Skip 1)+@($control.Controls)
                    if ($control -is [Windows.Forms.CheckedListBox] -and $control.Tag.CategoryKey -eq 'style') { $styleList=$control; break }
                }
                if (-not $styleList) { throw 'Style checkbox list missing.' }
                $choice=@($styleList.Tag.VisibleChoices | Where-Object { $_.Key -eq 'style:2' })[0]
                $styleList.SetItemChecked([Array]::IndexOf($styleList.Tag.VisibleChoices,$choice),$false)
                if (Test-PromptFragment $fixedPrompt.Text $choice.Text) { throw 'Unchecked preset must be removed before closing dialog.' }
                $styleList.SetItemChecked([Array]::IndexOf($styleList.Tag.VisibleChoices,$choice),$true)
                if (-not (Test-PromptFragment $fixedPrompt.Text $choice.Text)) { throw 'Checked preset must be added immediately.' }
                $grid=$styleList.Parent.Parent
                Search-FixedPresetGroups $grid.Tag 'no-match-live-test'
                if (-not (Test-PromptFragment $fixedPrompt.Text $choice.Text)) { throw 'Search must not alter selection.' }
                Clear-FixedGroupSelections $grid.Tag
                if ($script:selectedFixedKeys.Count -or $fixedPrompt.Text -ne 'custom scenery') { throw 'Clear must remove even hidden selections immediately.' }
                Add-RandomPresetChoice $styleList.Tag
                if ($script:selectedFixedKeys.Count -ne 1 -or $fixedPrompt.Text -eq 'custom scenery') { throw 'Hidden random selection must sync immediately.' }
                Clear-FixedGroupSelections $grid.Tag
                Search-FixedPresetGroups $grid.Tag ''
                $expressionSection=@($grid.Tag | Where-Object { $_.CategoryKey -eq 'expression' })[0]
                $expressionChoice=@($expressionSection.VisibleChoices | Where-Object { $_.Key -eq 'expression:1' })[0]
                $expressionSection.List.SetItemChecked([Array]::IndexOf($expressionSection.VisibleChoices,$expressionChoice),$true)
                $expressionSection.EachMenu.Checked=$true
                if ('expression' -notin $script:randomPresetGroups) { throw 'Per-image random must sync immediately.' }
                $expressionSection.EachMenu.Checked=$false
                if ('expression' -in $script:randomPresetGroups) { throw 'Disabling random must sync immediately.' }
                $dialog.Close()
            } catch { $script:cancelPresetError=$_.Exception.Message; if ($dialog) { $dialog.DialogResult='Cancel'; $dialog.Close() } }
        })
        try { $cancelTimer.Start(); & $openFixedPresets } finally { $cancelTimer.Stop(); $cancelTimer.Dispose() }
        if ($script:cancelPresetError) { throw $script:cancelPresetError }
        if ((Test-PromptFragment $fixedPrompt.Text $stylePresetTexts[2]) -or -not (Test-PromptFragment $fixedPrompt.Text $expressionPresetTexts[1]) -or -not $fixedPrompt.Text.Contains('custom scenery')) { throw 'Cancelling inline preset removed wrong content or failed to remove old fragment.' }
        $script:selectedFixedKeys=@('style:2'); $script:fixedAppliedTexts=@{}
        $fixedPrompt.Text='custom scenery, '+$stylePresetTexts[2]
        Set-FixedPresetSelection @()
        if ($fixedPrompt.Text -ne 'custom scenery') { throw 'Legacy selection without applied mapping was not removed.' }
        $script:fixedChoices=@([pscustomobject]@{Key='style:testA';Text='soft lighting';Random=$false},[pscustomobject]@{Key='style:testB';Text='soft lighting, watercolor';Random=$false})
        $script:selectedFixedKeys=@(); $script:fixedAppliedTexts=@{}; $fixedPrompt.Text='custom scenery'
        Set-FixedPresetSelection @('style:testA','style:testB'); Set-FixedPresetSelection @('style:testB')
        if (-not $fixedPrompt.Text.Contains('soft lighting, watercolor')) { throw 'Cancelling one preset damaged overlapping selected preset.' }
        $script:fixedChoices=$catalogBackup
        $script:characterAppliedTexts=@{'yun jin (genshin impact)'='yun jin (genshin impact)'}
        $fixedPrompt.Text='custom scenery, yun jin (genshin impact), soft lighting'
        Set-CharacterSelection @('yun jin (genshin impact)','keqing (genshin impact)')
        Set-CharacterSelection @('keqing (genshin impact)')
        if ((Test-PromptFragment $fixedPrompt.Text 'yun jin (genshin impact)') -or -not (Test-PromptFragment $fixedPrompt.Text 'keqing (genshin impact)') -or -not $fixedPrompt.Text.Contains('soft lighting')) { throw 'Character deselection did not preserve remaining character and style.' }
        $once=$fixedPrompt.Text; Set-CharacterSelection @('keqing (genshin impact)')
        if ($once -ne $fixedPrompt.Text) { throw 'Repeated character selection duplicated text.' }
        Set-CharacterSelection @()
        if ($fixedPrompt.Text -ne 'custom scenery, soft lighting') { throw 'Clearing characters damaged manual content.' }
    } finally {
        $script:fixedChoices=$catalogBackup; $script:selectedFixedKeys=$selectionKeys; $script:fixedAppliedTexts=$selectionApplied
        $script:characterAppliedTexts=$characterApplied; $fixedPrompt.Text=$selectionText; Update-FixedPresetCaption
    }
    Write-Output 'INLINE_PRESET_CANCELLATION_CHARACTER_SYNC_AND_OVERLAP_OK'
    Write-Output 'LIVE_PRESET_CHECK_UNCHECK_HIDDEN_CLEAR_RANDOM_AND_CLOSE_OK'

    $originalCharacterFile=$characterLibraryFile; $originalFavoriteFile=$favoriteLibraryFile
    $roleText=$fixedPrompt.Text; $roleApplied=$script:characterAppliedTexts.Clone()
    $roleTest=Join-Path ([IO.Path]::GetTempPath()) ('workbench-roles-'+[guid]::NewGuid().ToString('N')+'.json')
    $roleFavorites=$roleTest+'.favorites.json'
    $characterTimer=New-Object Windows.Forms.Timer; $characterTimer.Interval=150
    $script:roleDialogPass=0; $script:roleDialogError=$null
    try {
        @{female=@{'原神'=@(@{cn='云堇';en='yun jin (genshin impact)';desc='blue eyes, long hair'},@{cn='刻晴';en='keqing (genshin impact)';desc='purple eyes'})};male=@{'原神'=@(@{cn='迪卢克';en='diluc (genshin impact)'})}} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $roleTest -Encoding UTF8
        $characterLibraryFile=$roleTest; $favoriteLibraryFile=$roleFavorites
        $fixedPrompt.Text='custom scenery, yun jin (genshin impact), soft lighting'
        $characterTimer.Add_Tick({
            $characterTimer.Stop()
            $dlg=@([Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like '素材库 · 角色*' })[0]
            try {
                if (-not $dlg) { throw 'Character selection dialog did not open.' }
                $rows=@($dlg.Controls | Where-Object { $_ -is [Windows.Forms.ListView] })[0]
                $searchBox=@($dlg.Controls | Where-Object { $_ -is [Windows.Forms.TextBox] })[0]
                $yun=@($rows.Items | Where-Object { $_.Tag.En -eq 'yun jin (genshin impact)' })[0]
                $keqing=@($rows.Items | Where-Object { $_.Tag.En -eq 'keqing (genshin impact)' })[0]
                if ($script:roleDialogPass -eq 0) {
                    if (-not $yun.Checked -or $keqing.Checked) { throw 'Existing character was not restored as checked.' }
                    $mouseUp=[Windows.Forms.Control].GetMethod('OnMouseUp',[Reflection.BindingFlags]'Instance,NonPublic')
                    $clickRole={
                        param($item,$button)
                        $point=New-Object Drawing.Point(($item.SubItems[1].Bounds.Left+12),($item.Bounds.Top+[int]($item.Bounds.Height/2)))
                        $mouseEvent=New-Object Windows.Forms.MouseEventArgs($button,1,$point.X,$point.Y,0)
                        $null=$mouseUp.Invoke($rows,@($mouseEvent.PSObject.BaseObject))
                    }
                    & $clickRole $keqing ([Windows.Forms.MouseButtons]::Left)
                    & $clickRole $yun ([Windows.Forms.MouseButtons]::Left)
                    $checkY=$keqing.Bounds.Top+[int]($keqing.Bounds.Height/2)
                    $checkX=@(0..30 | Where-Object { $rows.HitTest($_,$checkY).Location -band [Windows.Forms.ListViewHitTestLocations]::StateImage })[0]
                    if ($null -eq $checkX) { throw 'Native role checkbox hit target missing.' }
                    foreach ($checked in @($false,$true)) {
                        $keqing.Checked=$checked
                        $mouseEvent=New-Object Windows.Forms.MouseEventArgs([Windows.Forms.MouseButtons]::Left,1,$checkX,$checkY,0)
                        $null=$mouseUp.Invoke($rows,@($mouseEvent.PSObject.BaseObject))
                        if ($keqing.Checked -ne $checked) { throw 'Native checkbox click toggled twice.' }
                    }
                    if ((Test-PromptFragment $fixedPrompt.Text $yun.Tag.En) -or -not (Test-PromptFragment $fixedPrompt.Text $keqing.Tag.En)) { throw 'Checkbox changes did not immediately synchronize text.' }
                    $searchBox.Text='云堇'
                    if ($rows.Items.Count -ne 1 -or $rows.Items[0].Checked -or -not (Test-PromptFragment $fixedPrompt.Text 'keqing (genshin impact)')) { throw 'Filtering dropped hidden character selection.' }
                    $searchBox.Text=''
                    $keqing=@($rows.Items | Where-Object { $_.Tag.En -eq 'keqing (genshin impact)' })[0]
                    if (-not $keqing.Checked) { throw 'Clearing filter lost checked character.' }
                    $beforeFavorite=$fixedPrompt.Text
                    $yun=@($rows.Items | Where-Object { $_.Tag.En -eq 'yun jin (genshin impact)' })[0]
                    $keqing.Selected=$false; $yun.Selected=$true
                    & $clickRole $keqing ([Windows.Forms.MouseButtons]::Right)
                    if ($fixedPrompt.Text -ne $beforeFavorite -or $script:dlgFavMap['keqing (genshin impact)'] -ne 1 -or $script:dlgFavMap.ContainsKey('yun jin (genshin impact)')) { throw 'Right click changed selection or starred the previously highlighted role.' }
                    foreach ($stars in @(2,3,0)) {
                        $keqing=@($rows.Items | Where-Object { $_.Tag.En -eq 'keqing (genshin impact)' })[0]
                        & $clickRole $keqing ([Windows.Forms.MouseButtons]::Right)
                        $actual=$(if($script:dlgFavMap.ContainsKey('keqing (genshin impact)')){$script:dlgFavMap['keqing (genshin impact)']}else{0})
                        if ($actual -ne $stars -or $fixedPrompt.Text -ne $beforeFavorite) { throw 'Right-click star cycle changed checkbox state or failed to cycle 0..3.' }
                    }
                    Write-Output 'ROLE_LEFT_SELECT_RIGHT_STAR_CYCLE_AND_NATIVE_CHECKBOX_OK' 
                    if ($ScreenshotPath) {
                        $snapshot=New-Object Drawing.Bitmap($dlg.Width,$dlg.Height)
                        try { $dlg.DrawToBitmap($snapshot,(New-Object Drawing.Rectangle(0,0,$dlg.Width,$dlg.Height))); $snapshot.Save(($ScreenshotPath+'.roles.png'),[Drawing.Imaging.ImageFormat]::Png) } finally { $snapshot.Dispose() }
                    }
                } elseif ($script:roleDialogPass -eq 1) {
                    if ($yun.Checked -or -not $keqing.Checked) { throw 'Reopening character dialog did not restore latest checks.' }
                    $keqing.Checked=$false
                    if ($fixedPrompt.Text -ne 'custom scenery, soft lighting') { throw 'Last character removal failed to preserve manual/style content.' }
                } elseif ($script:roleDialogPass -eq 2) {
                    if (-not $yun.Checked -or $keqing.Checked) { throw 'Editing a role description lost its checkbox.' }
                    $before=$fixedPrompt.Text
                    $keqing.Checked=$true
                    if ($fixedPrompt.Text.Contains('blue eyes, long hair') -or -not $fixedPrompt.Text.Contains('custom description') -or ([regex]::Matches($fixedPrompt.Text,[regex]::Escape($yun.Tag.En))).Count -ne 1) { throw 'Selecting another role duplicated or reset edited description.' }
                    $keqing.Checked=$false
                    $yun.Checked=$false
                    if ($fixedPrompt.Text -ne 'custom scenery, custom description, soft lighting') { throw 'Deselecting edited role must preserve manual description.' }
                } elseif ($script:roleDialogPass -eq 3) {
                    if ($yun.Checked -or $keqing.Checked -or $script:characterAppliedTexts.Count) { throw 'Deleted role tag must clear checked state even when description remains.' }
                } elseif ($script:roleDialogPass -eq 4) {
                    if (-not $yun.Checked -or $keqing.Checked) { throw 'Restoring role text must restore its checkbox without cached state.' }
                }
                $script:roleDialogPass++
            } catch { $script:roleDialogError=$_.Exception.Message }
            finally { if ($dlg) { $dlg.Close() } }
        })
        foreach ($pass in 1..2) {
            $characterTimer.Start(); Show-CharacterLibrary
            if ($script:roleDialogError) { throw $script:roleDialogError }
        }
        $fixedPrompt.Text='custom scenery, yun jin (genshin impact), custom description, soft lighting'
        $characterTimer.Start(); Show-CharacterLibrary
        if ($script:roleDialogError) { throw $script:roleDialogError }
        $fixedPrompt.Text='custom scenery, blue eyes, long hair, soft lighting'
        $characterTimer.Start(); Show-CharacterLibrary
        if ($script:roleDialogError) { throw $script:roleDialogError }
        $fixedPrompt.Text='custom scenery, yun jin (genshin impact), blue eyes, long hair, soft lighting'
        $script:characterAppliedTexts=@{}; $script:dlgCharacterChecked=@{}
        $characterTimer.Start(); Show-CharacterLibrary
        if ($script:roleDialogError) { throw $script:roleDialogError }
        if ($script:roleDialogPass -ne 5) { throw 'Character modal selection tests did not finish.' }
        Write-Output 'ROLE_REOPEN_EDITED_DESCRIPTION_DELETED_TAG_AND_TEXT_RESTORE_OK'
    } finally {
        $characterTimer.Stop(); $characterTimer.Dispose()
        $characterLibraryFile=$originalCharacterFile; $favoriteLibraryFile=$originalFavoriteFile
        $script:characterAppliedTexts=$roleApplied; $fixedPrompt.Text=$roleText
        foreach ($file in @($roleTest,$roleFavorites)) { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
    }
    Write-Output 'REAL_CHARACTER_MULTICHECK_FILTER_FAVORITES_REOPEN_AND_REMOVE_OK'

    $testRandomCatalog=@($fixedChoices); $testRandomText=$fixedPrompt.Text; $testRandomPrompt=$prompt.Text
    try {
        $script:fixedChoices=@([pscustomobject]@{Key='style:1'; Name='画风 · 水彩'; Text='watercolor'; Random=$false},[pscustomobject]@{Key='style:2'; Name='画风 · 墨线'; Text='ink'; Random=$false})
        $script:randomPresetGroups=@('style'); $fixedPrompt.Text=''; $prompt.Text=''
        $randomOnly=Get-Config
        if ($randomOnly.random_presets.Count -ne 1 -or $randomOnly.random_presets[0].choices.Count -ne 2 -or $randomOnly.prompt) { throw 'Random preset snapshot or random-only request failed.' }
        $fixedChoices[0].Text='edited'
        if ($randomOnly.random_presets[0].choices[0] -ne 'watercolor') { throw 'Submitted random choices changed while editing.' }
    } finally { $script:fixedChoices=$testRandomCatalog; $script:randomPresetGroups=@(); $fixedPrompt.Text=$testRandomText; $prompt.Text=$testRandomPrompt }
    Write-Output 'RANDOM_PRESET_SNAPSHOT_OK'
    $testHost = New-Object System.Windows.Forms.TableLayoutPanel
    $testSections = @(New-FixedPresetGroups $testHost)
    try {
        if ($testSections.Count -ne 7 -or @($testSections | Where-Object { $_.Expanded }).Count) { throw '分组没有默认收起。' }
        $expression=$testSections[2]
        $expression.Header.PerformClick()
        if (-not $expression.Expanded -or $expression.Panel.Height -le 40 -or $testSections[0].Expanded) { throw '表情分组展开失败。' }
        $expression.List.SetItemChecked(0,$true)
        $expression.List.SetItemChecked(1,$true)
        $expression.Header.PerformClick()
        $groupKeys=@(Get-FixedGroupKeys $testSections)
        if ($expression.Expanded -or 'expression:1' -notin $groupKeys -or 'expression:2' -notin $groupKeys -or $expression.Header.Text -notmatch '已选 [2-9]') { throw '收纳后多选状态丢失。' }
        Expand-AllPresetGroups $testSections
        if (@($testSections | Where-Object { -not $_.Expanded }).Count) { throw '全展开失败。' }
        foreach ($section in $testSections) {
            if ($section.List.Height -ne (10*$section.List.ItemHeight+8) -or $section.Panel.Height -ne $expression.Panel.Height) { throw '分类列表高度未统一为10条。' }
        }
        Expand-AllPresetGroups $testSections
        if (@($testSections | Where-Object { -not $_.Expanded }).Count) { throw '重复全展开不应收起。' }
        if (@(Get-FixedGroupKeys $testSections).Count -ne $groupKeys.Count) { throw '全展开改变了勾选状态。' }
        Write-Output 'UNIFORM_TEN_ROWS_EXPAND_ALL_OK' 
        if ($testHost.GetColumn($testSections[0].Panel) -ne 0 -or $testHost.GetColumn($testSections[1].Panel) -ne 1 -or $testHost.GetColumn($testSections[2].Panel) -ne 2 -or $testHost.GetRow($testSections[3].Panel) -ne 1 -or $testHost.RowCount -ne [Math]::Ceiling($testSections.Count/3)) { throw '每排三个分类排列错误。' }
        if (@($fixedChoices | Where-Object { $_.Key -like 'atmosphere:*' }).Count -or @($testSections | Where-Object { $_.Title -eq '氛围' }).Count) { throw '氛围分类未完整移除。' }
        Write-Output 'THREE_COLUMN_COLLAPSIBLE_PRESETS_OK'
        $beforeSearch=@(Get-FixedGroupKeys $testSections) -join '|'
        Search-FixedPresetGroups $testSections '不存在的选项xyz'
        if ((@(Get-FixedGroupKeys $testSections) -join '|') -ne $beforeSearch) { throw '无结果搜索丢失勾选。' }
        Search-FixedPresetGroups $testSections '柔和空气感'
        $styleSection=$testSections[0]
        if ($styleSection.VisibleChoices.Count -ne 1 -or $styleSection.VisibleChoices[0].Key -ne 'style:2' -or -not $styleSection.Expanded) { throw '搜索过滤或自动展开失败。' }
        $styleSection.List.SetItemChecked(0,$true)
        Search-FixedPresetGroups $testSections ''
        if ('style:2' -notin @(Get-FixedGroupKeys $testSections) -or $styleSection.List.Items.Count -ne $styleSection.Choices.Count) { throw '搜索后勾选映射或清空恢复错误。' }
        Write-Output 'PRESET_SEARCH_PRESERVES_SELECTION_OK'
        $randomSection=$testSections[0]
        $beforeRandom=@($randomSection.Choices | Where-Object { $randomSection.Checked[$_.Key] })
        $remaining=@($randomSection.Choices | Where-Object { -not $randomSection.Checked[$_.Key] })
        if ($remaining.Count) {
            Add-RandomPresetChoice $randomSection
            $afterRandom=@($randomSection.Choices | Where-Object { $randomSection.Checked[$_.Key] })
            if ($afterRandom.Count -ne $beforeRandom.Count+1) { throw '随机未恰好追加一项。' }
            foreach ($choice in $beforeRandom) { if (-not $randomSection.Checked[$choice.Key]) { throw '随机覆盖了原勾选。' } }
        }
        for ($randomIndex=0; $randomIndex -lt $randomSection.Choices.Count; $randomIndex++) { Add-RandomPresetChoice $randomSection }
        if ($randomSection.UnifiedMenu.Enabled -or @($randomSection.Checked.Values | Where-Object { $_ }).Count -ne $randomSection.Choices.Count) { throw '全选后随机按钮未停用。' }
        Add-RandomPresetChoice $randomSection
        Write-Output 'RANDOM_CATEGORY_APPEND_ONLY_OK'
        $beforeEach=@(Get-FixedGroupKeys $testSections) -join '|'
        $randomSection.EachMenu.PerformClick()
        if (-not $randomSection.RandomEach -or -not $randomSection.EachMenu.Checked -or (@(Get-FixedGroupKeys $testSections) -join '|') -ne $beforeEach) { throw 'Per-image menu changed fixed selections.' }
        $randomSection.EachMenu.PerformClick()
        if ($randomSection.RandomEach) { throw 'Per-image menu could not be disabled.' }
        Clear-FixedGroupSelections $testSections
        $randomSection.EachMenu.PerformClick()
        $randomSection.UnifiedMenu.PerformClick()
        if ($randomSection.RandomEach -or @($randomSection.Checked.Values | Where-Object { $_ }).Count -ne 1) { throw 'Unified random must disable per-image mode and select one item.' }
        Write-Output 'TWO_RANDOM_MENU_MODES_OK'
        Search-FixedPresetGroups $testSections '柔和空气感'
        Clear-FixedGroupSelections $testSections
        if (@(Get-FixedGroupKeys $testSections).Count) { throw '清空未清除隐藏勾选。' }
        Search-FixedPresetGroups $testSections ''
        foreach ($section in $testSections) {
            if ($section.List.CheckedItems.Count -or -not $section.UnifiedMenu.Enabled) { throw '清空后选项或随机按钮状态错误。' }
        }
        Write-Output 'CLEAR_ALL_PRESET_SELECTIONS_OK'



        foreach ($section in $testSections) { if ($section.Expanded) { Set-PresetGroupExpanded $section $false } }
        Expand-AllPresetGroups $testSections -SelectedOnly
        foreach ($section in $testSections) {
            if ($section.Expanded -ne ($section.List.CheckedItems.Count -gt 0)) { throw '已选分类未自动展开或空分类误展开。' }
        }
        Write-Output 'SELECTED_GROUPS_AUTO_EXPAND_OK'
    $hiddenDialog = New-Object System.Windows.Forms.Form
    $hiddenGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $hiddenDialog.Controls.Add($hiddenGrid)
    $hiddenSections = @(New-FixedPresetGroups $hiddenGrid)
    try {
        $hiddenSections[0].List.SetItemChecked(0,$true)
        Expand-AllPresetGroups $hiddenSections -SelectedOnly
        if (-not $hiddenSections[0].Expanded) { throw '显示前未设置展开状态。' }
        $hiddenDialog.Show(); [System.Windows.Forms.Application]::DoEvents()
        foreach ($section in $hiddenSections) {
            if ($section.List.Visible -ne ($section.List.CheckedItems.Count -gt 0)) { throw '真实弹窗分类可见性错误。' }
        }
        Write-Output 'REAL_DIALOG_SELECTED_EXPANSION_OK'
        $libraryBackup=$presetLibraryFile; $catalogBackup=@($fixedChoices)
        $deletedBackup=@($script:presetDeletedKeys); $customBackup=@($script:presetCustomItems); $overridesBackup=@($script:presetOverrides)
        $presetLibraryFile=Join-Path $AppDirectory ('preset-test-'+[guid]::NewGuid().ToString('N')+'.json')
        try {
            $editSection=$hiddenSections[0]
            $customItem=New-CustomPresetItem 'style' '画风' '自定义测试' 'soft watercolor'
            Save-PresetGroupItems $editSection @($editSection.Choices[0],$customItem)
            $roundTrip=Get-Content -LiteralPath $presetLibraryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($customItem.Key -notin @($roundTrip.custom.Key) -or $customItem.Key -notin $fixedChoices.Key -or -not @($roundTrip.deleted).Count) { throw '新增或删除持久化失败。' }
            $failed=$false
            try { $null=New-CustomPresetItem 'style' '画风' '' '' } catch { $failed=$true }
            if (-not $failed) { throw '空白自定义预设应被拒绝。' }
            $edited=New-CustomPresetItem 'style' '画风' '更新测试' 'new watercolor'
            $edited.Key=$editSection.Choices[0].Key
            Save-PresetGroupItems $editSection @($edited,$customItem)
            $roundTrip=Get-Content -LiteralPath $presetLibraryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($roundTrip.overrides[0].Key -ne $edited.Key -or $roundTrip.overrides[0].Text -ne 'new watercolor') { throw 'Edited builtin was not persisted with its original key.' }
            $managerTimer=New-Object System.Windows.Forms.Timer
            $managerTimer.Interval=200
            $managerTimer.Add_Tick({
                $managerTimer.Stop()
                $dialog=[System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like '管理预设*' } | Select-Object -First 1
                $list=$dialog.Controls | Where-Object { $_ -is [System.Windows.Forms.ListBox] } | Select-Object -First 1
                $list.SelectedIndex=0
                $state=$list.Tag
                $state.Name.Text='界面编辑测试'; $state.Text.Text='updated through manager'
                $state.Update.PerformClick()
                ($dialog.Controls | Where-Object { $_.Text -eq '保存修改' }).PerformClick()
            })
            try { $managerTimer.Start(); Show-PresetGroupManager $editSection } finally { $managerTimer.Stop(); $managerTimer.Dispose() }
            $roundTrip=Get-Content -LiteralPath $presetLibraryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($roundTrip.overrides[0].Text -ne 'updated through manager') { throw 'Manager edit interaction did not persist.' }
            Write-Output 'PRESET_MANAGER_EDIT_AND_PERSISTENCE_OK' 
        } finally {
            Remove-Item -LiteralPath $presetLibraryFile -ErrorAction SilentlyContinue
            $presetLibraryFile=$libraryBackup; $script:fixedChoices=$catalogBackup
            $script:presetDeletedKeys=$deletedBackup; $script:presetCustomItems=$customBackup; $script:presetOverrides=$overridesBackup
        }

    } finally { $hiddenDialog.Dispose() } 
    } finally { $testHost.Dispose() }



    $mode.SelectedIndex = 1
    $refUsage.SelectedIndex = 1
    if ($refPreset.SelectedIndex -ne 0 -or $refPreset.Items[0] -ne '自由发挥' -or -not $refElement.Enabled) { throw '参考预设初始化失败。' }
    $refPreset.SelectedIndex = 2
    $refUsage.SelectedIndex = 0
    if ($refPreset.SelectedIndex -ne 1 -or $refElement.Enabled -or $refPreset.Items[1] -ne '常规修改') { throw '修改预设切换失败。' }
    $mode.SelectedIndex = 0
    Write-Output 'REFERENCE_PRESETS_MODE_SYNC_OK'




    $form.Show(); $form.PerformLayout(); [System.Windows.Forms.Application]::DoEvents()
    $mode.SelectedIndex = 0; $asMode.SelectedIndex = 3
    if ($mode.SelectedIndex -ne 1 -or -not ($refUsage.SelectedIndex -eq 1) -or $asMode.SelectedIndex -ne 3) { throw '助手特征参考同步失败。' }
    $refUsage.SelectedIndex = 0
    if ($asMode.SelectedIndex -ne 2) { throw '编辑模式反向同步失败。' }
    $mode.SelectedIndex = 0
    $tabWidthBackup=$form.Width
    foreach ($testWidth in @(960,1220)) {
        $form.Width=$testWidth
        $tabs.SelectedTab=$assistantPage
        [Windows.Forms.Application]::DoEvents(); Set-AssistantTabLayout
        if (-not $assistant.Visible -or -not $right.Visible -or $tabs.TabPages.Count -ne 3 -or $form.Width -ne $testWidth) { throw 'Assistant tab changed window size or hid image preview.' }
        foreach ($control in @($asModel,$asMode,$asIdea,$asFinal,$asTranslate,$asAnalyze)) {
            if ($control.Parent -ne $assistant -or $control.Right -gt $assistant.ClientSize.Width) { throw 'Assistant control extends outside the tab.' }
        }
        if ($asIdea.Bottom -ge $asDirBtn.Top -or $asStatus.Bottom -ge $asCaption3.Top -or $asFinal.Bottom -ge $asCopy.Top) { throw 'Assistant controls overlap vertically.' }
        $tabs.SelectedTab=$creationPage
    }
    $form.Width=$tabWidthBackup
    Write-Output 'ASSISTANT_THIRD_TAB_LAYOUT_OK'
    if ($presetStyle.Right -gt $presetCharacter.Left -or $presetCharacter.Right -gt $fixedPrompt.Right -or $presetCharacter.Top -ne $presetStyle.Top -or $presetCharacter.Bottom -gt $fixedPrompt.Top) { throw '双预设布局重叠。' }
    if ($negPrompt.Height -ne [Math]::Floor($prompt.Height / 2) -or $chooseFixedPresets.Bottom -gt $fixedPrompt.Top -or $chooseFixedPresets.Right -gt $fixedPrompt.Right) { throw '半高负面框或多选按钮布局错误。' }
    if ($negPreset.Bottom -gt $negPrompt.Top -or $fixedPrompt.Bottom -gt ($negPreset.Top - 8)) { throw '输入区域重叠。' }
    foreach ($control in @($model,$statusLabel,$progress)) {
        if ($control.Right -gt $control.Parent.ClientSize.Width) { throw '控件超出窗口。' }
    }
    $testJob = Join-Path ([System.IO.Path]::GetTempPath()) ('workbench-ui-check-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testJob | Out-Null
    try {
        [System.IO.File]::WriteAllText((Join-Path $testJob 'status.json'), '{"state":"running","progress":20,"message":"test"}')
        $script:job = $testJob; $script:started = Get-Date; $script:stopped = $false
        $script:worker = [pscustomobject]@{HasExited=$false}
        Set-GenerationBusy $true
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $stop.PerformClick(); $watch.Stop()
        if ($watch.ElapsedMilliseconds -gt 1000 -or -not (Test-Path -LiteralPath (Join-Path $testJob 'stop')) -or -not $script:stopped -or $generate.Enabled) { throw '停止按钮阻塞或过早允许新任务。' }
        Write-Output 'STOP_BUTTON_NONBLOCKING_OK'
        $script:job = $testJob; $script:started = Get-Date; $script:stopped = $true
        $script:worker = [pscustomobject]@{HasExited=$true}
        $script:worker | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        $inputs.Enabled = $false; $generate.Enabled = $false
        $tickMethod = [System.Windows.Forms.Timer].GetMethod('OnTick',[System.Reflection.BindingFlags]'Instance,NonPublic')
        $null = $tickMethod.Invoke($timer,@([System.EventArgs]::Empty))
        if ($script:worker -or -not $inputs.Enabled -or -not $generate.Enabled) { throw '停止后旧状态导致界面未恢复。' }
    } finally {
        Remove-Item -LiteralPath (Join-Path $testJob 'stop') -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $testJob 'status.json') -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $testJob -ErrorAction SilentlyContinue
        $script:job = $null
    }
    Write-Output 'LAYOUT_MODE_SYNC_STOP_RECOVERY_OK'
    $queueTest=Join-Path ([IO.Path]::GetTempPath()) ('workbench-queue-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $queueTest
    $actualAppDirectory=$AppDirectory; $actualWorkerFile=$workerFile
    $queuePausedBefore=$script:queuePaused
    try {
        $AppDirectory=$queueTest; $workerFile=Join-Path $queueTest 'fake-worker.py'
        $fakeWorker=@'
import json
import os
from pathlib import Path
import shutil
import sys
import time

request = Path(sys.argv[1])
job = request.parent
base = job.parent.parent
config = json.loads(request.read_text(encoding='utf-8'))

def publish(**data):
    temporary = job / 'status.tmp'
    temporary.write_text(json.dumps(data), encoding='utf-8')
    os.replace(temporary, job / 'status.json')

terminal = dict(state='error', message='simulated failure', progress=0, completed=0)
try:
    lock = (base / 'active.lock').open('x')
except FileExistsError:
    publish(state='error', message='overlapping workers', progress=0, completed=0)
    raise SystemExit(1)
try:
    with (base / 'launches.jsonl').open('a', encoding='utf-8') as log:
        log.write(json.dumps(config) + '\n')
    publish(state='running', message='simulated generation', progress=0)
    for _ in range(20):
        if (job / 'stop').exists():
            terminal = dict(state='cancelled', message='simulated stop', progress=0, completed=0)
            break
        time.sleep(0.02)
    else:
        if config['seed'] != 999:
            output = Path(config['output']) / (str(config['seed']) + '.png')
            shutil.copyfile(base / 'fixture.png', output)
            terminal = dict(state='done', message='simulated done', progress=100, completed=1,
                            seed=config['seed'], outputs=[dict(output=str(output), seed=config['seed'])])
finally:
    lock.close()
    (base / 'active.lock').unlink()
publish(**terminal)
'@
        [IO.File]::WriteAllText($workerFile,$fakeWorker,[Text.UTF8Encoding]::new($false))
        $bitmap=New-Object Drawing.Bitmap(8,8)
        try { $bitmap.Save((Join-Path $queueTest 'fixture.png'),[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
        $script:queueItems.Clear(); $script:queuePaused=$true; $timer.Stop()
        $config=[ordered]@{model='qwen21';mode='text';prompt='queue alpha';prompts=@('queue alpha');count=1;output=$queueTest;seed=101;random_presets=@(@{key='style';choices=@('watercolor','ink')})}
        $first=Add-QueuedTask $config
        $config.prompt='queue beta'; $config.prompts[0]='queue beta'; $config.seed=102; $config.random_presets[0].choices[0]='edited'
        $second=Add-QueuedTask $config
        if ($script:worker -or (Test-Path -LiteralPath (Join-Path $queueTest 'launches.jsonl'))) { throw 'Paused queue started a task.' }
        Move-QueuedTask $second -1
        if (@($script:queueItems | Where-Object {$_.Status -eq 'waiting'})[0] -ne $second) { throw 'Queue reorder failed.' }
        Move-QueuedTask $second 1
        $script:queuePaused=$false; Start-NextQueuedTask
        $deadline=[DateTime]::UtcNow.AddSeconds(12)
        while ($script:worker -or @($script:queueItems | Where-Object {$_.Status -eq 'waiting'}).Count) {
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Queue FIFO completion timed out.' }
        }
        $launches=@(Get-Content -LiteralPath (Join-Path $queueTest 'launches.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        if ($launches.Count -ne 2 -or $launches[0].seed -ne 101 -or $launches[1].seed -ne 102 -or $launches[0].prompt -ne 'queue alpha' -or $launches[0].random_presets[0].choices[0] -ne 'watercolor' -or $first.Status -ne 'done' -or $second.Status -ne 'done') { throw 'Queue order, immutable nested snapshots or automatic chaining failed.' }
        $script:queuePaused=$true; $config.seed=106
        $finishing=Add-QueuedTask $config
        $script:queuePaused=$false; Start-NextQueuedTask
        $activeProcess=$script:worker
        $config.seed=107; $heldTask=Add-QueuedTask $config
        if ($script:worker -ne $activeProcess -or $heldTask.Status -ne 'waiting') { throw 'Enqueue while running replaced active worker.' }
        $script:queuePaused=$true; Update-QueueUi
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while ($script:worker) {
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Pausing queue interrupted or hung active task.' }
        }
        if ($finishing.Status -ne 'done' -or $heldTask.Status -ne 'waiting') { throw 'Paused queue must finish active task and retain pending task.' }
        $script:queuePaused=$false; Start-NextQueuedTask
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while ($script:worker) {
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Continuing paused queue timed out.' }
        }
        if ($heldTask.Status -ne 'done') { throw 'Continuing queue did not start retained task.' }
        $script:queuePaused=$true; $config.seed=103
        $stopping=Add-QueuedTask $config
        $config.seed=104; $waiting=Add-QueuedTask $config
        $script:queuePaused=$false; Start-NextQueuedTask
        $stop.PerformClick()
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while ($script:worker) {
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Queue stop confirmation timed out.' }
        }
        if (-not $script:queuePaused -or $stopping.Status -ne 'cancelled' -or $waiting.Status -ne 'waiting') { throw 'Stopping current task must pause queue and retain pending task.' }
        $script:queuePaused=$false; $timer.Start(); Start-NextQueuedTask
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while ($script:worker) {
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Queue resume timed out.' }
        }
        if ($waiting.Status -ne 'done') { throw 'Queue resume failed.' }
        $script:queuePaused=$true; $config.seed=999
        $failing=Add-QueuedTask $config
        $config.seed=105; $retained=Add-QueuedTask $config
        $script:queuePaused=$false; Start-NextQueuedTask
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while ($script:worker) {
            [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Queue failure test timed out.' }
        }
        if (-not $script:queuePaused -or $failing.Status -ne 'error' -or $retained.Status -ne 'waiting') { throw 'Failed task did not pause remaining queue.' }
        Write-Output 'QUEUE_FIFO_SNAPSHOTS_STOP_RESUME_FAILURE_AND_NO_OVERLAP_OK'
        $queueDialogTimer=New-Object Windows.Forms.Timer; $queueDialogTimer.Interval=150
        $script:queueDialogError=$null; $script:queueDialogTested=$false
        $queueDialogTimer.Add_Tick({
            $queueDialogTimer.Stop()
            $dialog=$script:queueDialog
            try {
                if (-not $dialog -or $dialog.Tag.List.Items.Count -ne $script:queueItems.Count) { throw 'Queue manager did not display task states.' }
                if ($ScreenshotPath) {
                    $snapshot=New-Object Drawing.Bitmap($dialog.Width,$dialog.Height)
                    try { $dialog.DrawToBitmap($snapshot,(New-Object Drawing.Rectangle(0,0,$dialog.Width,$dialog.Height))); $snapshot.Save(($ScreenshotPath+'.queue.png'),[Drawing.Imaging.ImageFormat]::Png) } finally { $snapshot.Dispose() }
                }
                foreach ($row in $dialog.Tag.List.Items) { if ($row.Tag -eq $retained) { $row.Selected=$true } }
                $remove=@($dialog.Controls | Where-Object {$_.Text -eq '移除'})[0]
                $beforeRemove=$script:queueItems.Count; $remove.PerformClick()
                if ($retained -in $script:queueItems -or $script:queueItems.Count -ne $beforeRemove-1) { throw 'Removing pending task from queue manager failed.' }
                $script:queueDialogTested=$true
            } catch { $script:queueDialogError=$_.Exception.Message }
            finally { if ($dialog) { $dialog.Close() } }
        })
        try { $queueDialogTimer.Start(); Show-TaskQueue } finally { $queueDialogTimer.Stop(); $queueDialogTimer.Dispose() }
        if ($script:queueDialogError) { throw $script:queueDialogError }
        if (-not $script:queueDialogTested) { throw 'Queue manager test did not finish.' }
        Write-Output 'QUEUE_MANAGER_STATUS_AND_REMOVE_OK'
    } finally {
        $timer.Stop()
        if ($script:worker) {
            if (-not $script:worker.HasExited) { $script:worker.Kill(); $null=$script:worker.WaitForExit(2000) }
            $script:worker.Dispose(); $script:worker=$null
        }
        $AppDirectory=$actualAppDirectory; $workerFile=$actualWorkerFile
        $script:currentQueueTask=$null; $script:queueItems.Clear(); $script:queuePaused=$queuePausedBefore
        $script:seenGeneratedFiles=@{}; $script:stopped=$false
        Set-GenerationBusy $false; Update-QueueUi
        $resolved=[IO.Path]::GetFullPath($queueTest)
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'workbench-queue-*') { throw 'Invalid queue test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }

    if ($script:assistantRefreshCalls -ne 1 -or -not $script:assistantModelsLoaded) { throw 'Assistant must load on first tab visit only.' }
    Write-Output 'ASSISTANT_LAZY_LOAD_ON_FIRST_TAB_VISIT_OK'

    $asModel.SelectedItem='deepseek-r1:14b'
    Refresh-AssistantModels
    if ($asModel.SelectedItem -ne 'deepseek-r1:14b') { throw 'Refresh lost selected model.' }
    $script:testAssistantOffline=$true
    Refresh-AssistantModels
    if ($script:assistantModelsLoaded -or $asModel.Items.Count -ne 3 -or $asModel.SelectedItem -ne 'deepseek-r1:14b') { throw 'Failed refresh must preserve models and allow retry.' }
    $script:testAssistantOffline=$false
    $script:testAssistantModels=@()
    Refresh-AssistantModels
    if ($script:assistantModelsLoaded -or $asModel.Items.Count -ne 0) { throw 'Empty service response must allow retry.' }
    $script:testAssistantOffline=$true
    Refresh-AssistantModels
    if ($script:assistantModelsLoaded -or $asModel.Items.Count -ne 0) { throw 'Initial connection failure must allow retry.' }
    $script:testAssistantOffline=$false
    $script:testAssistantModels=@('custom-model:latest')
    Refresh-AssistantModels
    if (-not $script:assistantModelsLoaded -or $asModel.SelectedItem -ne 'custom-model:latest') { throw 'Retry must select the complete single model name.' }
    $script:testAssistantModels=@('yi-9b-abliterated:latest','qwen3.5:4b','deepseek-r1:14b')
    Refresh-AssistantModels
    Write-Output 'ASSISTANT_MODEL_RETRY_SELECTION_AND_FAILURE_PRESERVATION_OK'


    if (-not (Test-Path -LiteralPath $workerFile)) { throw '缺少任务执行器。' }
    if ($tip.InitialDelay -ne 500 -or $tip.ReshowDelay -ne 500) { throw '悬停延迟不是 500 毫秒。' }
    foreach ($item in $helpItems) {
        $label = $helpLabels | Where-Object {$_.Text.StartsWith($item.Name)} | Select-Object -First 1
        if (-not $label -or [string]::IsNullOrWhiteSpace($tip.GetToolTip($label))) { throw ('配置缺少说明：'+$item.Name) }
    }


    if (-not (Get-Command Get-DroppedReferenceImages -ErrorAction SilentlyContinue)) { throw '尚未实现图片拖入。' }
    $reference = Join-Path $portable 'ComfyUI_Qwen21\input\qwen21_reference.png'
    $dropData = New-Object System.Windows.Forms.DataObject
    $dropData.SetData([System.Windows.Forms.DataFormats]::FileDrop,[string[]]@($reference,$reference))
    if (@(Get-DroppedReferenceImages $dropData).Count -ne 2) { throw '未识别多张拖入图片。' }
    $dropData.SetData([System.Windows.Forms.DataFormats]::FileDrop,[string[]]@($reference,$workerFile))
    if (@(Get-DroppedReferenceImages $dropData).Count) { throw '不应接收混有非图片的文件。' }
    $dropData.SetData([System.Windows.Forms.DataFormats]::FileDrop,[string[]]@($reference+'.missing.png'))
    if (@(Get-DroppedReferenceImages $dropData).Count) { throw '不应接收不存在的图片。' }
    $dropData.SetData([System.Windows.Forms.DataFormats]::FileDrop,[string[]]@($reference,$reference))
    $mode.SelectedIndex=0
    $dropEvent=New-Object System.Windows.Forms.DragEventArgs($dropData,0,0,0,[System.Windows.Forms.DragDropEffects]::Copy,[System.Windows.Forms.DragDropEffects]::None)
    & $imageDropHandler $preview $dropEvent
    if ($mode.SelectedIndex -ne 1 -or $script:referenceFiles.Count -ne 2 -or $batchCount.Value -ne 1 -or -not $preview.Image) { throw '多图拖入状态错误。' }
    $model.SelectedIndex=0
    $prompt.Text='批量测试'
    $config=Get-Config
    if ($config.images.Count -ne 2 -or $config.reference_count -ne 1) { throw '批量改图配置错误。' }
    $script:worker=[pscustomobject]@{Busy=$true}; $mode.SelectedIndex=0
    & $imageDropHandler $preview $dropEvent
    $script:worker=$null
    if ($mode.SelectedIndex -ne 1) { throw '生成中应允许准备下一批参考图。' }
    $mode.SelectedIndex=0
    $batchCount.Value=3; $config=Get-Config
    if ($config.count -ne 3) { throw '批量生成数量错误。' }
    $batchCount.Value=1
    $model.SelectedIndex = 0
    $previousPixels = 0
    for ($index=0; $index -lt $sizePresets.Count; $index++) {
        $preset.SelectedIndex=$index
        $choice=$sizePresets[$index]; $pixels=$choice.Width*$choice.Height
        if ($pixels -lt $previousPixels -or $width.Value -ne $choice.Width -or $height.Value -ne $choice.Height) { throw '尺寸排序或映射错误。' }
        if ($choice.Width % 32 -or $choice.Height % 32) { throw '尺寸不符合 32 倍数要求。' }
        $previousPixels=$pixels
    }
    $preset.SelectedIndex=$sizePresets.Count
    if (-not $width.Enabled -or -not $height.Enabled) { throw '自定义尺寸不可编辑。' }
    $preset.SelectedIndex=$defaultSizeIndex
    if ($width.Value -ne 1024 -or $height.Value -ne 1024) { throw '默认尺寸错误。' }
    $fixedPrompt.Text = ''
    $prompt.Text = "[0001] 1girl, silver hair`n   NEG: bad anatomy, blurry"
    [System.Windows.Forms.Application]::DoEvents()
    $config = Get-Config
    if ($config.prompt -ne '1girl, silver hair' -or $config.negative_prompt -ne 'bad anatomy, blurry') { throw '块格式拆分错误。' }
    if ($negPrompt.Text -notmatch 'bad anatomy') { throw '块格式未自动填入负面词。' }
    $fixedPrompt.Text = 'soft shading, masterpiece'
    $prompt.Text = '1girl'
    $config = Get-Config
    if ($config.prompt -ne '1girl, soft shading, masterpiece') { throw '固定片段拼接错误。' }
    $fixedPrompt.Text = ''; $negPrompt.Text = ''
    $prompt.Text = '桌面界面自检'; $config = Get-Config
    if ($config.mode -ne 'text' -or $config.steps -ne 25) { throw '文生图默认值错误。' }
    Set-ReferenceImages @((Join-Path $portable 'ComfyUI_Qwen21\input\qwen21_reference.png'))
    $config = Get-Config
    if ($config.mode -ne 'edit' -or $config.steps -ne 40 -or $width.Enabled) { throw '图生图默认值错误。' }
    $model.SelectedIndex = 1
    if ($steps.Value -ne 8 -or $steps.Enabled) { throw 'Turbo 默认参数错误。' }
    $mode.SelectedIndex = 0
    if ($steps.Value -ne 8) { throw 'Turbo 文生图默认参数错误。' }
    $model.SelectedIndex = 0
    $mode.SelectedIndex = 0; $prompt.Text = '山间清晨，一座古祠立于石阶尽头，松林与薄雾环绕，写实摄影，自然光。'
    $form.Show(); $form.PerformLayout(); [System.Windows.Forms.Application]::DoEvents()
    if ($ScreenshotPath) {
        $bitmap = New-Object System.Drawing.Bitmap($form.Width,$form.Height)
        $form.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle(0,0,$form.Width,$form.Height)))
        $bitmap.Save($ScreenshotPath,[System.Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
    }

    $bridgeTestFile=Join-Path $AppDirectory 'test_agent_bridge.ps1'
    if (Test-Path -LiteralPath $bridgeTestFile) { . $bridgeTestFile }
    $tip.Dispose(); $form.Dispose(); Write-Output 'UI_SELF_TEST_OK BATCH_UI_OK FILE_DROP_OK TOOLTIP_DELAY_500MS ALL_12_OPTIONS'; exit 0

}
if ($IntegrationTest) {
    $script:integrationPassed = $false
    $foundModel = $false
    for ($index=0; $index -lt $models.Count; $index++) {
        if ($models[$index].id -eq $TestModel) { $model.SelectedIndex=$index; $foundModel=$true; break }
    }
    if (-not $foundModel) { throw '测试模型未登记。' }
    $prompt.Text = 'A cinematic photograph of a small ancient Chinese mountain shrine, stone steps, misty pine forest at dawn, warm lanterns, realistic natural light.'
    $output.Text = Join-Path (Split-Path $ScreenshotPath -Parent) 'qwen_app_test_output'
    $seed.Text = '42'
    $batchCount.Value=$TestCount
    if ($TestMode -eq 'edit') {
        $mode.SelectedIndex = 1
        $references = @()
        for ($index=1; $index -le $TestCount; $index++) {
            $sample = Join-Path $AppDirectory ('integration_reference_'+$index+'.png')
            Copy-Item -LiteralPath (Join-Path $portable 'ComfyUI_Qwen21\input\qwen21_reference.png') -Destination $sample -Force
            $references += $sample
        }
        Set-ReferenceImages $references
        $prompt.Text = 'Cover the temple roof, every stone step, ground and pine branches with thick white snow. Preserve the temple architecture and viewpoint. Cold soft daylight, snowy winter landscape.'
    }
    $form.Add_Shown({ $generate.PerformClick() })
}

[void]$form.ShowDialog()
if ($IntegrationTest) {
    if (-not $script:integrationPassed) { throw '原生界面生成测试失败。' }
    Write-Output ('NATIVE_INTEGRATION_OK ' + $TestModel + ' ' + $TestMode + ' ' + $script:lastFile)
}
if ($preview.Image) { $preview.Image.Dispose() }
$timer.Dispose(); $tip.Dispose(); $form.Dispose()