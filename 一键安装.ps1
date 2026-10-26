# ============================================================
#  本地生图工作台 · 一键安装
#  把工作台程序层装进 ComfyUI 便携版，并创建桌面快捷方式。
#  不下载模型、不改动 ComfyUI 本体代码。
# ============================================================
param(
    [string]$ComfyUIRoot,
    [string]$OutputDir,
    [switch]$SkipShortcut,
    [switch]$SkipDependencyCheck,
    [switch]$SkipModelCheck,
    [switch]$RunSelfTest,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$payload = Join-Path $here '工作台文件'
$runtime = Join-Path $here '运行时文件'
$docsDir = Join-Path $here '文档'

function Write-Step([string]$text) { Write-Host ''; Write-Host ('== ' + $text) -ForegroundColor Cyan }
function Write-Ok([string]$text) { Write-Host ('   [OK] ' + $text) -ForegroundColor Green }
function Write-Warn2([string]$text) { Write-Host ('   [!] ' + $text) -ForegroundColor Yellow }
function Write-Bad([string]$text) { Write-Host ('   [X] ' + $text) -ForegroundColor Red }

function Test-ComfyUIRoot([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $path 'python_embeded\python.exe'))) { return $false }
    foreach ($name in @('ComfyUI_Qwen21', 'ComfyUI')) {
        if (Test-Path -LiteralPath (Join-Path $path ($name + '\main.py'))) { return $true }
    }
    return $false
}

function Find-ComfyUIRoot {
    $common = @(
        $ComfyUIRoot,
        $env:COMFYUI_ROOT,
        'D:\ComfyUI_windows_portable\ComfyUI_windows_portable',
        'C:\ComfyUI_windows_portable\ComfyUI_windows_portable',
        (Join-Path $env:USERPROFILE 'ComfyUI_windows_portable\ComfyUI_windows_portable'),
        (Join-Path $env:USERPROFILE 'Desktop\ComfyUI_windows_portable\ComfyUI_windows_portable')
    )
    foreach ($candidate in $common) {
        if (Test-ComfyUIRoot $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    # 在各固定磁盘上找 ComfyUI 便携版常见的两层目录
    $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -match '^[A-Za-z]:\\$' })
    foreach ($drive in $drives) {
        foreach ($pattern in @('ComfyUI_windows_portable', '*\ComfyUI_windows_portable', '*\*\ComfyUI_windows_portable')) {
            $found = @(Get-ChildItem -Path (Join-Path $drive.Root $pattern) -Directory -ErrorAction SilentlyContinue)
            foreach ($dir in $found) {
                if (Test-ComfyUIRoot $dir.FullName) { return $dir.FullName }
                $inner = Join-Path $dir.FullName 'ComfyUI_windows_portable'
                if (Test-ComfyUIRoot $inner) { return $inner }
            }
        }
    }
    return $null
}

function Read-ComfyUIVersion([string]$root) {
    foreach ($name in @('ComfyUI_Qwen21', 'ComfyUI')) {
        $file = Join-Path $root ($name + '\comfyui_version.py')
        if (Test-Path -LiteralPath $file) {
            $text = Get-Content -LiteralPath $file -Raw
            if ($text -match '__version__\s*=\s*"([^"]+)"') { return $matches[1] }
        }
    }
    return $null
}

function Test-QwenNodes([string]$root) {
    foreach ($name in @('ComfyUI_Qwen21', 'ComfyUI')) {
        $file = Join-Path $root ($name + '\comfy_extras\nodes_qwen.py')
        if (Test-Path -LiteralPath $file) {
            $text = Get-Content -LiteralPath $file -Raw
            if ($text -match 'TextEncodeQwenImage21' -and $text -match 'QwenImage21Cache') { return $true }
        }
    }
    return $false
}

Write-Host ''
Write-Host '本地生图工作台 · 一键安装' -ForegroundColor White
Write-Host '把工作台装进已有的 ComfyUI 便携版（不下载模型，不改 ComfyUI 本体）' -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $payload)) {
    Write-Bad ('缺少程序文件目录：' + $payload)
    Write-Host '请把整个分享包解压后再运行本脚本。'
    exit 1
}

# ---------- 1. 定位 ComfyUI 便携版 ----------
Write-Step '1/7 定位 ComfyUI 便携版'
$root = Find-ComfyUIRoot
if (-not $root) {
    Write-Warn2 '没有自动找到 ComfyUI 便携版。'
    Write-Host '请先下载并解压 ComfyUI 便携版（NVIDIA 显卡版），然后把它所在的根目录粘贴到这里。'
    Write-Host '该目录里应当同时有 python_embeded 和 ComfyUI 两个文件夹。'
    Write-Host '示例：D:\ComfyUI_windows_portable\ComfyUI_windows_portable'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $typed = Read-Host 'ComfyUI 便携版根目录'
        $typed = $typed.Trim().Trim('"').Trim("'")
        if (Test-ComfyUIRoot $typed) { $root = (Resolve-Path -LiteralPath $typed).Path; break }
        Write-Bad '这个目录不像是 ComfyUI 便携版根目录（缺少 python_embeded 或 ComfyUI\main.py）。'
    }
    if (-not $root) { Write-Bad '放弃安装：没有可用的 ComfyUI 目录。'; exit 1 }
}
Write-Ok ('根目录：' + $root)

$version = Read-ComfyUIVersion $root
if ($version) {
    Write-Ok ('ComfyUI 版本：' + $version)
    try {
        if ([version]($version -replace '[^0-9.].*$','') -lt [version]'0.42.0') {
            Write-Warn2 '版本低于 0.42.0：可能没有 Qwen-Image 2.1 节点，Qwen 模型会加载失败。建议更新便携版。'
        }
    } catch { }
}
if (-not (Test-QwenNodes $root)) {
    Write-Warn2 '没有在 comfy_extras\nodes_qwen.py 里找到 Qwen-Image 2.1 节点；请确认 ComfyUI 更新到支持 Qwen-Image 2.1 的版本。'
} else {
    Write-Ok 'Qwen-Image 2.1 节点已就绪'
}

$python = Join-Path $root 'python_embeded\python.exe'
$app = Join-Path $root 'QwenImageApp'
$comfyFolder = if (Test-Path -LiteralPath (Join-Path $root 'ComfyUI_Qwen21\main.py')) { 'ComfyUI_Qwen21' } else { 'ComfyUI' }

# ---------- 2. 复制程序 ----------
Write-Step '2/7 复制工作台程序'
if (-not (Test-Path -LiteralPath $app)) { $null = New-Item -ItemType Directory -Path $app -Force }
# 这些是使用中产生的个人数据，重复安装时保留，不用空白模板覆盖
$dataFiles = @('素材库_角色.json', '素材库_提示词.json', '素材库_收藏.json', 'settings.json', 'preset_library_changes.json')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $app ('安装备份\' + $stamp)
$script:backedUp = 0
$script:sameSkipped = 0
$script:preserved = 0
function Copy-WithBackup([string]$source, [string]$destination) {
    $exists = Test-Path -LiteralPath $destination
    if ($exists) {
        $same = $false
        try { $same = ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) } catch { }
        if ($same) { $script:sameSkipped++; return $false }
        if (-not (Test-Path -LiteralPath $backupRoot)) { $null = New-Item -ItemType Directory -Path $backupRoot -Force }
        $name = Split-Path $destination -Leaf
        $target = Join-Path $backupRoot $name
        if (Test-Path -LiteralPath $target) {
            $target = Join-Path $backupRoot ([IO.Path]::GetFileNameWithoutExtension($name) + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + [IO.Path]::GetExtension($name))
        }
        Copy-Item -LiteralPath $destination -Destination $target -Force
        $script:backedUp++
    }
    Copy-Item -LiteralPath $source -Destination $destination -Force
    return $true
}
if ($Force) { Write-Warn2 '-Force：会用包内空白素材库覆盖现有素材库；覆盖前会自动备份。' }
$copied = 0
foreach ($file in @(Get-ChildItem -LiteralPath $payload -File)) {
    $dest = Join-Path $app $file.Name
    if (($file.Name -in $dataFiles) -and (Test-Path -LiteralPath $dest) -and (-not $Force)) { $script:preserved++; continue }
    if (Copy-WithBackup $file.FullName $dest) { $copied++ }
}
Write-Ok ('已更新 ' + $copied + ' 个文件到 ' + $app)
if ($script:preserved) { Write-Host ('   保留已有个人文件 ' + $script:preserved + ' 个（未覆盖；加 -Force 才会覆盖）') -ForegroundColor DarkGray }
if ($script:sameSkipped) { Write-Host ('   内容相同、跳过 ' + $script:sameSkipped + ' 个') -ForegroundColor DarkGray }
if ($script:backedUp) { Write-Warn2 ('本次覆盖前已备份 ' + $script:backedUp + ' 个文件到 ' + $backupRoot) }

$launcherSource = Join-Path $runtime 'launch_qwen21.py'
$launcherTarget = Join-Path $root 'launch_qwen21.py'
if (Test-Path -LiteralPath $launcherTarget) {
    $sameLauncher = $false
    try { $sameLauncher = ((Get-FileHash -LiteralPath $launcherSource).Hash -eq (Get-FileHash -LiteralPath $launcherTarget).Hash) } catch { }
    if (-not $sameLauncher) {
        if (-not (Test-Path -LiteralPath $backupRoot)) { $null = New-Item -ItemType Directory -Path $backupRoot -Force }
        Copy-Item -LiteralPath $launcherTarget -Destination (Join-Path $backupRoot 'launch_qwen21.py') -Force
        $script:backedUp++
        Write-Warn2 ('已备份原 launch_qwen21.py 到 ' + $backupRoot)
    }
}
Copy-Item -LiteralPath $launcherSource -Destination $launcherTarget -Force
Write-Ok '已写入引擎启动脚本 launch_qwen21.py'

if (Test-Path -LiteralPath $docsDir) {
    $appDocs = Join-Path $app '文档'
    if (-not (Test-Path -LiteralPath $appDocs)) { $null = New-Item -ItemType Directory -Path $appDocs -Force }
    foreach ($file in @(Get-ChildItem -LiteralPath $docsDir -File)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $appDocs $file.Name) -Force
    }
    Write-Ok '说明书已复制到 QwenImageApp\文档'
}

# 首次安装时给出默认输出目录
$settingsFile = Join-Path $app 'settings.json'
if (-not (Test-Path -LiteralPath $settingsFile)) {
    if (-not $OutputDir) { $OutputDir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Qwen生图' }
    if (-not (Test-Path -LiteralPath $OutputDir)) { $null = New-Item -ItemType Directory -Path $OutputDir -Force }
    $settings = [ordered]@{
        model = 'qwen21'
        mode = 0
        prompt = ''
        fixedPrompt = ''
        negPrompt = ''
        output = $OutputDir
        width = 1024
        height = 1024
        steps = 25
        cfg = 1.0
        count = 1
        seed = '-1'
    }
    [IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Ok ('默认输出目录：' + $OutputDir)
} else {
    Write-Ok '保留已有设置（settings.json）'
}

# ---------- 3. Python 依赖 ----------
Write-Step '3/7 检查 Python 依赖'
if ($SkipDependencyCheck) {
    Write-Warn2 '已跳过依赖检查'
} else {
    & $python -c "import aiohttp, requests, PIL" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 'python_embeded 缺少 aiohttp / requests / pillow，尝试用 pip 安装…'
        & $python -m pip install --disable-pip-version-check aiohttp requests pillow
        if ($LASTEXITCODE -ne 0) { Write-Warn2 'pip 安装失败。工作台生成图片需要这三个包，请联网后重试或手动安装。' }
        else { Write-Ok '依赖安装完成' }
    } else {
        Write-Ok 'aiohttp / requests / pillow 已安装'
    }
    $cuda = (& $python -c "import torch;print(torch.cuda.is_available())" 2>$null)
    if ($cuda -eq 'True') { Write-Ok 'PyTorch 可用 CUDA 显卡加速' }
    else { Write-Warn2 'PyTorch 没有检测到 CUDA。没有 NVIDIA 显卡时生成会非常慢或失败。' }
}

# ---------- 4. 检查模型 ----------
Write-Step '4/7 检查模型文件'
$modelRoots = @(
    (Join-Path (Join-Path $root $comfyFolder) 'models'),
    (Join-Path $root 'ComfyUI\models'),
    (Join-Path $root 'ComfyUI_Qwen21\models')
) | Select-Object -Unique
$required = @(
    @{ Folder = 'diffusion_models'; Name = 'qwen_image_2.1_int8_convrot.safetensors'; MB = 6921; For = 'Qwen 2.1 标准版' },
    @{ Folder = 'text_encoders';    Name = 'qwen3vl_8b_w4a8.safetensors';               MB = 6020; For = 'Qwen 2.1 标准版' },
    @{ Folder = 'vae';              Name = 'qwen_image_2.1_vae_bf16.safetensors';       MB = 644;  For = 'Qwen 2.1 标准版' },
    @{ Folder = 'diffusion_models'; Name = 'qwen_image_2.1_turbo_int8_convrot.safetensors'; MB = 6921; For = 'Qwen 2.1 Turbo' },
    @{ Folder = 'checkpoints';      Name = 'sd3.5_medium.safetensors';                  MB = 4871; For = 'SD 3.5 Medium' },
    @{ Folder = 'text_encoders';    Name = 'clip_l.safetensors';                        MB = 235;  For = 'SD 3.5 Medium' },
    @{ Folder = 'text_encoders';    Name = 't5xxl_fp8_e4m3fn.safetensors';              MB = 4667; For = 'SD 3.5 Medium' },
    @{ Folder = 'diffusion_models'; Name = 'z_image_int8_convrot.safetensors';          MB = 5914; For = 'Z-Image' },
    @{ Folder = 'text_encoders';    Name = 'qwen_3_4b_fp4_mixed.safetensors';           MB = 3318; For = 'Z-Image' },
    @{ Folder = 'vae';              Name = 'ae.safetensors';                            MB = 320;  For = 'Z-Image' }
)

if ($SkipModelCheck) {
    Write-Warn2 '已跳过模型检查'
} else {
    $missing = 0
    $totalMissingMB = 0
    foreach ($item in $required) {
        $found = $null
        foreach ($models in $modelRoots) {
            $candidate = Join-Path $models ($item.Folder + '\' + $item.Name)
            if (Test-Path -LiteralPath $candidate) { $found = $candidate; break }
        }
        if ($found) {
            $actualMB = [math]::Round((Get-Item -LiteralPath $found).Length / 1MB)
            if ($actualMB -lt ($item.MB * 0.8)) {
                Write-Warn2 ('大小异常：' + $item.Name + '（' + $actualMB + ' MB，应为 ' + $item.MB + ' MB 左右）——可能没下载完')
                $missing++
                $totalMissingMB += $item.MB
            } else {
                Write-Ok ($item.Name + '  [' + $item.For + ']')
            }
        } else {
            Write-Bad ('缺少 ' + $item.Folder + '\' + $item.Name + '  [' + $item.For + ']')
            $missing++
            $totalMissingMB += $item.MB
        }
    }
    if ($missing -gt 0) {
        Write-Warn2 ('还缺 ' + $missing + ' 个模型文件，约 ' + [math]::Round($totalMissingMB / 1024, 1) + ' GB。')
        Write-Host '   模型不随包分发：从原工作台电脑复制，或按《模型清单.md》的地址下载。'
        Write-Host '   只放你要用的模型也可以：models.json 里有 4 个模型，缺哪个就换用别的。'
    } else {
        Write-Ok '模型文件齐全'
    }
}

# ---------- 5. 启动脚本 ----------
Write-Step '5/7 生成启动入口'
$ps1 = Join-Path $app '本地生图工作台.ps1'
$bat = Join-Path $app '启动工作台.bat'
$batText = "@echo off`r`nstart `"`" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"%~dp0本地生图工作台.ps1`"`r`n"
[IO.File]::WriteAllText($bat, $batText, [Text.Encoding]::GetEncoding(936))
Write-Ok '已生成 启动工作台.bat'

# ---------- 6. 桌面快捷方式 ----------
Write-Step '6/7 创建桌面快捷方式'
if ($SkipShortcut) {
    Write-Warn2 '已跳过（-SkipShortcut）'
} else {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop '本地生图工作台.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "' + $ps1 + '"'
        $shortcut.WorkingDirectory = $app
        $icon = Join-Path $app 'qwen_image_white.ico'
        if (Test-Path -LiteralPath $icon) { $shortcut.IconLocation = $icon + ',0' }
        $shortcut.Description = '本地生图工作台'
        $shortcut.Save()
        Write-Ok ('桌面快捷方式：' + $lnkPath)
    } catch {
        Write-Warn2 ('创建快捷方式失败：' + $_.Exception.Message + '；可直接双击 ' + $bat)
    }
}

# ---------- 7. 可选自检 ----------
Write-Step '7/7 完成'
if ($RunSelfTest) {
    Write-Host '   正在运行工作台界面自检（会短暂弹出窗口）…'
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -STA -File $ps1 -SelfTest -AppDirectory $app
    if ($LASTEXITCODE -eq 0) { Write-Ok '界面自检通过' } else { Write-Warn2 ('界面自检返回 ' + $LASTEXITCODE + '，请看上面的报错行。') }
}

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Host ('  工作台目录：' + $app)
Write-Host ('  ComfyUI    ：' + (Join-Path $root $comfyFolder))
Write-Host '  启动方式   ：双击桌面「本地生图工作台」'
Write-Host ''
Write-Host '第一次使用：' -ForegroundColor Cyan
Write-Host '  1. 确认模型已放进 models 对应子文件夹（见 4/7 的结果）'
Write-Host '  2. 打开工作台，右上角选模型，填提示词，点“开始生成”'
Write-Host '  3. 第一次生成会自动启动引擎，约 30～90 秒；引擎日志在 QwenImageApp\engine.log'
Write-Host ''
Write-Host '给 AI 助手用：把 文档\给AI的交接文档.md 交给它，按里面的接口调用。'