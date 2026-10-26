# Agent requests are data snapshots consumed by the existing WinForms queue.
function Export-AgentCatalog {
    $presets=@(foreach($choice in $fixedChoices) {
        @{id=$choice.Key;name=$choice.Name;text=$choice.Text;category=($choice.Key -split ':',2)[0];random=[bool]$choice.Random}
    })
    $characters=@()
    if (Test-Path -LiteralPath $characterLibraryFile) {
        $library=Get-Content -LiteralPath $characterLibraryFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $sha=[Security.Cryptography.SHA256]::Create()
        try {
            $characters=@(foreach($group in @(@('female',$library.female),@('male',$library.male))) {
                foreach($work in $group[1].PSObject.Properties) {
                    foreach($character in $work.Value) {
                        $hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$character.en)))).Replace('-','').ToLowerInvariant()
                        $fullText=$(if($character.desc){$character.en+', '+$character.desc}else{$character.en})
                        @{id=('character:'+$hash.Substring(0,32));name=$character.cn;text=$fullText;tag=$character.en;description=[string]$character.desc;work=$work.Name;gender=$group[0]}
                    }
                }
            })
        } finally { $sha.Dispose() }
    }
    Write-SettingsFile (Join-Path $script:agentRoot 'catalog.json') @{output=$output.Text;presets=$presets;characters=$characters}
}

function Initialize-AgentBridge([bool]$startService=$true) {
    $script:agentRoot=Join-Path $AppDirectory 'agent_api'
    $null=New-Item -ItemType Directory -Path $script:agentRoot -Force
    try { $script:agentLock=[IO.File]::Open((Join-Path $script:agentRoot 'bridge.lock'),'OpenOrCreate','ReadWrite','None') }
    catch [IO.IOException] { return $false }
    $script:agentSession=[guid]::NewGuid().ToString('N')
    $script:agentEntries=@{}; $script:agentPublished=@{}; $script:agentTicks=0
    foreach($directory in @('inbox','jobs')) { $null=New-Item -ItemType Directory -Path (Join-Path $script:agentRoot $directory) -Force }
    Export-AgentCatalog
    if ($startService) {
        $client=Join-Path $AppDirectory 'agent_client.py'
        $null=Start-Process -FilePath $python -ArgumentList @('-s',('"'+$client+'"'),'--app',('"'+$AppDirectory+'"'),'serve') -WorkingDirectory $AppDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $script:agentRoot 'startup.stdout.log') -RedirectStandardError (Join-Path $script:agentRoot 'startup.stderr.log') -PassThru
    }
    return $true
}

function Write-AgentHeartbeat([bool]$online=$true) {
    if (-not $script:agentLock) { return }
    Write-SettingsFile (Join-Path $script:agentRoot 'heartbeat.json') @{time=([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0);session=$script:agentSession;online=$online;paused=$script:queuePaused}
    $script:agentLastPause=$script:queuePaused
}

function Publish-AgentQueueStates {
    if (-not $script:agentLock) { return }
    if ($script:agentLastPause -ne $script:queuePaused) { Write-AgentHeartbeat }
    $waiting=@($script:queueItems | Where-Object {$_.Status -eq 'waiting'})
    foreach($id in @($script:agentEntries.Keys)) {
        $entry=$script:agentEntries[$id]
        if ($entry -notin $script:queueItems -and $entry.Status -eq 'waiting') { $entry.Status='cancelled' }
        $position=$null
        if ($entry.Status -eq 'waiting') { $position=[Array]::IndexOf($waiting,$entry)+1 }
        $signature=$entry.Status+'|'+$position
        if ($script:agentPublished[$id] -eq $signature) { continue }
        $directory=Join-Path (Join-Path $script:agentRoot 'jobs') $id
        $null=New-Item -ItemType Directory -Path $directory -Force
        Write-SettingsFile (Join-Path $directory 'bridge.json') @{session=$script:agentSession;state=$(if($entry.Status -eq 'waiting'){'queued'}else{$entry.Status});queue_number=$entry.Number;queue_position=$position;source=$entry.Source;message=('工作台任务 '+$entry.Number+' · '+$entry.Status)}
        $script:agentPublished[$id]=$signature
    }
}

function Invoke-AgentBridgeTick {
    if (-not $script:agentLock) {
        if (-not (Initialize-AgentBridge (-not $SelfTest))) { return }
    }
    $script:agentTicks++
    if ($script:agentTicks % 4 -eq 1) { Write-AgentHeartbeat }
    if ($script:agentTicks % 25 -eq 0) { Export-AgentCatalog }
    $changed=$false
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $script:agentRoot 'inbox') -Filter '*.json' -File | Sort-Object LastWriteTimeUtc | Select-Object -First 20)) {
        $id=$file.BaseName
        if ($id -notmatch '^job_[a-f0-9]{32}$') { continue }
        $directory=Join-Path (Join-Path $script:agentRoot 'jobs') $id
        $null=New-Item -ItemType Directory -Path $directory -Force
        try {
            if (-not $script:agentEntries.ContainsKey($id)) {
                if (Test-Path -LiteralPath (Join-Path $directory 'cancel')) {
                    Write-SettingsFile (Join-Path $directory 'bridge.json') @{state='cancelled';session=$script:agentSession;message='入队前已取消'}
                    Remove-Item -LiteralPath $file.FullName; continue
                }
                # A previous session may already have launched this ID; never silently replay it.
                if ((Test-Path -LiteralPath (Join-Path $directory 'bridge.json')) -or (Test-Path -LiteralPath (Join-Path (Join-Path $AppDirectory 'jobs') ($id+'\request.json')))) {
                    Remove-Item -LiteralPath $file.FullName; continue
                }
                $message=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($message.job_id -ne $id -or -not $message.config) { throw '无效 Agent 请求' }
                $entry=New-QueueTask $message.config
                $entry.AgentJobId=$id; $entry.Source=[string]$message.source
                if (-not $entry.Source) { $entry.Source='agent' }
                $entry.Summary='['+$id.Substring(4,8)+'] '+$entry.Summary
                $script:agentEntries[$id]=$entry
                $changed=$true
            }
            Publish-AgentQueueStates
            Remove-Item -LiteralPath $file.FullName
        } catch {
            Write-SettingsFile (Join-Path $directory 'bridge.json') @{state='error';session=$script:agentSession;code='bridge_rejected';message=$_.Exception.Message}
            Remove-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        }
    }
    foreach($id in @($script:agentEntries.Keys)) {
        $entry=$script:agentEntries[$id]
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $script:agentRoot 'jobs') $id) 'cancel'))) { continue }
        if ($entry.Status -eq 'waiting') { $null=$script:queueItems.Remove($entry);$entry.Status='cancelled';$changed=$true }
        elseif ($entry.Status -eq 'running' -and $script:currentQueueTask -eq $entry -and -not $script:stopped) {
            [IO.File]::WriteAllText((Join-Path $script:job 'stop'),'')
            $script:stopped=$true; $script:queuePaused=$true; $stop.Enabled=$false
            $statusLabel.Text='Agent 请求停止任务 '+$entry.Number+'，等待引擎确认…'
        }
    }
    if ($changed) { Update-QueueUi } else { Publish-AgentQueueStates }
    Start-NextQueuedTask
}

function Stop-AgentBridge {
    if ($script:agentLock) {
        try { Write-AgentHeartbeat $false } finally { $script:agentLock.Dispose();$script:agentLock=$null }
    }
}

if (-not ($SelfTest -or $IntegrationTest -or $TestDrawer -or $TestAssistant)) {
    $output.Add_Leave({ if ($script:agentLock) { Export-AgentCatalog } })
    $agentBridgeTimer=New-Object Windows.Forms.Timer
    $agentBridgeTimer.Interval=250
    $agentBridgeTimer.Add_Tick({
        try { Invoke-AgentBridgeTick }
        catch { $queueStatus.Text='Agent 接口暂不可用：'+$_.Exception.Message }
    })
    $form.Add_Shown({ $agentBridgeTimer.Start() })
    $form.Add_FormClosed({ $agentBridgeTimer.Stop();$agentBridgeTimer.Dispose();Stop-AgentBridge })
}
