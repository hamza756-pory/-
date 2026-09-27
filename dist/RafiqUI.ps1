# Rafiq 1.0.0 — Windows 10/11 repair companion
# UTF-8 with BOM is prepended by the packager.
$ErrorActionPreference = 'Continue'
$RafiqVersion = '1.0.0'
$RafiqRoot = Join-Path $env:LOCALAPPDATA 'Rafiq'
New-Item -ItemType Directory -Force -Path $RafiqRoot | Out-Null
$LogFile = Join-Path $RafiqRoot 'rafiq.log'

function Write-RafiqLog([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Test-RafiqAdmin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RafiqJson($obj) {
    return ($obj | ConvertTo-Json -Compress -Depth 8)
}

function Send-Rafiq($Response, [string]$Body, [string]$Type = 'application/json; charset=utf-8', [int]$Status = 200) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = $Status
    $Response.ContentType = $Type
    $Response.Headers.Add('Cache-Control', 'no-store')
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Invoke-RafiqCmd([string]$File, [string]$Arguments, [int]$TimeoutSec = 60) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        return @{ ok = $false; output = 'Timeout' }
    }
    $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    return @{ ok = ($p.ExitCode -eq 0); output = $out; code = $p.ExitCode }
}

function Get-RafiqDirSize([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    try {
        $sum = [int64]0
        Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue -File | ForEach-Object {
            $sum += $_.Length
        }
        return $sum
    } catch { return [int64]0 }
}

function Clear-RafiqDir([string]$Path, [int]$KeepDays = 0) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $n = 0
    Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($KeepDays -gt 0 -and $_.LastWriteTime -gt (Get-Date).AddDays(-$KeepDays)) { return }
            Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            $n++
        } catch {}
    }
    return $n
}

function Set-RafiqReg($HivePath, $Name, $Value, $Type = 'DWord') {
    if (-not (Test-Path $HivePath)) { New-Item -Path $HivePath -Force | Out-Null }
    New-ItemProperty -Path $HivePath -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-RafiqInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $adapters = @()
    try {
        Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.NetAdapter.Status -eq 'Up' } | ForEach-Object {
            $dns = @()
            try { $dns = @(Get-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerAddresses) } catch {}
            $adapters += @{
                name   = $_.InterfaceAlias
                status = 'Up'
                ipv4   = ($_.IPv4Address | Select-Object -First 1 | ForEach-Object { $_.IPAddress })
                dns    = $dns
            }
        }
    } catch {
        Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } | ForEach-Object {
            $adapters += @{ name = $_.Description; status = 'Up'; ipv4 = @($_.IPAddress | Where-Object { $_ -match '^\d' } | Select-Object -First 1); dns = @($_.DNSServerSearchOrder) }
        }
    }
    $caption = $os.Caption
    $ver = [Environment]::OSVersion.Version.ToString()
    return @{
        ok         = $true
        demo       = $false
        admin      = [bool](Test-RafiqAdmin)
        os         = "$caption ($ver)"
        build      = $os.BuildNumber
        computer   = $cs.Name
        cpu        = $cpu.Name
        ramTotal   = [int64]$os.TotalVisibleMemorySize * 1024
        ramFree    = [int64]$os.FreePhysicalMemory * 1024
        diskTotal  = [int64]$disk.Size
        diskFree   = [int64]$disk.FreeSpace
        uptime     = [int]((New-TimeSpan -Start $os.LastBootUpTime -End (Get-Date)).TotalSeconds)
        netUp      = [bool]($adapters.Count -gt 0)
        dnsOk      = $true
        adapters   = $adapters
        version    = $RafiqVersion
    }
}

function Get-RafiqScan {
    $tempUser = $env:TEMP
    $tempWin = Join-Path $env:SystemRoot 'Temp'
    $update = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $do = Join-Path $env:ProgramData 'Microsoft\Windows\DeliveryOptimization\Cache'
    $thumbs = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    $dumps = Join-Path $env:LOCALAPPDATA 'CrashDumps'
    $prefetch = Join-Path $env:SystemRoot 'Prefetch'
    $items = @(
        @{ id = 'temp';     label = 'Temporary files';           path = $tempUser; bytes = Get-RafiqDirSize $tempUser; safe = $true }
        @{ id = 'wintemp';  label = 'Windows Temp';              path = $tempWin;  bytes = Get-RafiqDirSize $tempWin;  safe = $true }
        @{ id = 'updates';  label = 'Windows Update cache';      path = $update;   bytes = Get-RafiqDirSize $update;   safe = $true }
        @{ id = 'do';       label = 'Delivery Optimization';     path = $do;       bytes = Get-RafiqDirSize $do;       safe = $true }
        @{ id = 'thumbs';   label = 'Thumbnail / icon cache';    path = $thumbs;   bytes = Get-RafiqDirSize $thumbs;   safe = $true }
        @{ id = 'dumps';    label = 'Crash dumps';               path = $dumps;    bytes = Get-RafiqDirSize $dumps;    safe = $true }
        @{ id = 'prefetch'; label = 'Prefetch (optional)';       path = $prefetch; bytes = Get-RafiqDirSize $prefetch; safe = $true }
        @{ id = 'recycle';  label = 'Recycle Bin';               path = 'RecycleBin'; bytes = 0; safe = $true }
    )
    return @{ ok = $true; items = $items }
}

function Invoke-RafiqClean($ids) {
    if (-not $ids) { $ids = @('temp') }
    $n = 0
    foreach ($id in @($ids)) {
        switch ($id) {
            'temp' { $n += Clear-RafiqDir $env:TEMP }
            'wintemp' { $n += Clear-RafiqDir (Join-Path $env:SystemRoot 'Temp') }
            'updates' { $n += Clear-RafiqDir (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') }
            'do' { $n += Clear-RafiqDir (Join-Path $env:ProgramData 'Microsoft\Windows\DeliveryOptimization\Cache') }
            'thumbs' {
                Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                $n++
            }
            'dumps' { $n += Clear-RafiqDir (Join-Path $env:LOCALAPPDATA 'CrashDumps') }
            'prefetch' { $n += Clear-RafiqDir (Join-Path $env:SystemRoot 'Prefetch') }
            'recycle' {
                try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; $n++ } catch {}
            }
            'clean_temp' { $n += Clear-RafiqDir $env:TEMP }
        }
    }
    return @{ ok = $true; message = "Removed $n items"; output = "Removed $n items" }
}

function Invoke-RafiqDiagnose {
    $lines = New-Object System.Collections.Generic.List[string]
    $r1 = Invoke-RafiqCmd 'ping.exe' '-n 2 -w 1500 1.1.1.1'
    $lines.Add('--- ping 1.1.1.1 ---')
    $lines.Add($r1.output.Trim())
    $r2 = Invoke-RafiqCmd 'ping.exe' '-n 2 -w 1500 www.microsoft.com'
    $lines.Add('--- ping www.microsoft.com (DNS + ICMP) ---')
    $lines.Add($r2.output.Trim())
    $r3 = Invoke-RafiqCmd 'ipconfig.exe' '/all'
    $lines.Add('--- ipconfig /all (truncated) ---')
    $all = $r3.output -split "`n" | Select-Object -First 80
    $lines.Add(($all -join "`n"))
    return @{ ok = $true; output = ($lines -join "`n") }
}

function Set-RafiqDns([string]$Preset) {
    $servers = $null
    switch ($Preset) {
        'cloudflare' { $servers = @('1.1.1.1', '1.0.0.1') }
        'google' { $servers = @('8.8.8.8', '8.8.4.4') }
        'adguard' { $servers = @('94.140.14.14', '94.140.15.15') }
        'quad9' { $servers = @('9.9.9.9', '149.112.112.112') }
        'dhcp' { $servers = $null }
        default { return @{ ok = $false; message = 'Unknown DNS preset' } }
    }
    $ok = $true
    $out = New-Object System.Collections.Generic.List[string]
    try {
        Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
            if ($null -eq $servers) {
                Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses
                $out.Add("DHCP DNS on $($_.Name)")
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $servers
                $out.Add("$($_.Name) -> $($servers -join ', ')")
            }
        }
    } catch {
        $ok = $false
        $out.Add("$_")
    }
    Invoke-RafiqCmd 'ipconfig.exe' '/flushdns' | Out-Null
    return @{ ok = $ok; message = ($out -join '; '); output = ($out -join "`n") }
}

function Invoke-RafiqTweak([string]$Id) {
    switch ($Id) {
        'classicMenu' {
            $p = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
            New-Item -Path $p -Force | Out-Null
            Set-ItemProperty -Path $p -Name '(default)' -Value ''
            return @{ ok = $true; message = 'Classic context menu enabled. Restart Explorer to apply.' }
        }
        'taskbarLeft' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAl' 0
            return @{ ok = $true; message = 'Taskbar alignment set to left.' }
        }
        'fileExt' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
            return @{ ok = $true; message = 'File extensions visible.' }
        }
        'hiddenFiles' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1
            return @{ ok = $true; message = 'Hidden files visible.' }
        }
        'copilot' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
            Set-RafiqReg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
            return @{ ok = $true; message = 'Copilot button hidden.' }
        }
        'widgets' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
            return @{ ok = $true; message = 'Widgets hidden.' }
        }
        'adsLock' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 0
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338387Enabled' 0
            return @{ ok = $true; message = 'Lock screen suggestions disabled.' }
        }
        'adsStart' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
            return @{ ok = $true; message = 'Start suggestions disabled.' }
        }
        'adsSettings' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 0
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 0
            return @{ ok = $true; message = 'Settings suggestions disabled.' }
        }
        'tailored' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
            return @{ ok = $true; message = 'Tailored experiences disabled.' }
        }
        'adId' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
            return @{ ok = $true; message = 'Advertising ID disabled.' }
        }
        'searchBing' {
            Set-RafiqReg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
            return @{ ok = $true; message = 'Bing suggestions in search disabled.' }
        }
        'fastStartup' {
            if (-not (Test-RafiqAdmin)) { return @{ ok = $false; message = 'Administrator required' } }
            Invoke-RafiqCmd 'powercfg.exe' '/h off' | Out-Null
            return @{ ok = $true; message = 'Fast Startup / hibernation disabled.' }
        }
        'endTask' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDeveloperSettings' 1
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarEndTask' 1
            return @{ ok = $true; message = 'End Task on taskbar enabled.' }
        }
        'compact' {
            Set-RafiqReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'UseCompactMode' 1
            return @{ ok = $true; message = 'Compact Explorer view enabled.' }
        }
        default { return @{ ok = $false; message = "Unknown tweak $Id" } }
    }
}

function Invoke-RafiqRepair([string]$Id) {
    switch ($Id) {
        'flushdns' { $r = Invoke-RafiqCmd 'ipconfig.exe' '/flushdns'; return @{ ok = $r.ok; message = 'DNS cache flushed'; output = $r.output } }
        'renew' {
            Invoke-RafiqCmd 'ipconfig.exe' '/release' | Out-Null
            $r = Invoke-RafiqCmd 'ipconfig.exe' '/renew'
            return @{ ok = $true; message = 'IP renewed'; output = $r.output }
        }
        'winsock' {
            if (-not (Test-RafiqAdmin)) { return @{ ok = $false; message = 'Administrator required for Winsock reset. Reboot after it succeeds.' } }
            $r = Invoke-RafiqCmd 'netsh.exe' 'winsock reset'
            return @{ ok = $r.ok; message = 'Winsock reset. Reboot Windows.'; output = $r.output }
        }
        'ipreset' {
            if (-not (Test-RafiqAdmin)) { return @{ ok = $false; message = 'Administrator required' } }
            $r = Invoke-RafiqCmd 'netsh.exe' 'int ip reset'
            return @{ ok = $true; message = 'TCP/IP stack reset. Reboot Windows.'; output = $r.output }
        }
        'explorer' {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Process explorer.exe
            return @{ ok = $true; message = 'Explorer restarted' }
        }
        'audio' {
            Restart-Service -Name Audiosrv -Force -ErrorAction SilentlyContinue
            Restart-Service -Name AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
            return @{ ok = $true; message = 'Audio services restarted' }
        }
        'spooler' {
            Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
            $pq = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
            if (Test-Path $pq) { Get-ChildItem $pq -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
            Start-Service -Name Spooler -ErrorAction SilentlyContinue
            return @{ ok = $true; message = 'Print spooler reset' }
        }
        'search' {
            Restart-Service -Name WSearch -Force -ErrorAction SilentlyContinue
            return @{ ok = $true; message = 'Windows Search restarted' }
        }
        'icons' {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            $db = Join-Path $env:LOCALAPPDATA 'IconCache.db'
            if (Test-Path $db) { Remove-Item $db -Force -ErrorAction SilentlyContinue }
            Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') -Filter 'iconcache*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Start-Process explorer.exe
            return @{ ok = $true; message = 'Icon cache rebuilt' }
        }
        'thumbs' {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Start-Process explorer.exe
            return @{ ok = $true; message = 'Thumbnail cache cleared' }
        }
        'wsreset' {
            Start-Process 'wsreset.exe' -ErrorAction SilentlyContinue
            return @{ ok = $true; message = 'Microsoft Store reset started' }
        }
        'godmode' {
            $p = Join-Path $env:USERPROFILE 'Desktop\GodMode.{ED7BA470-8E54-465E-825C-99712043E01C}'
            New-Item -ItemType Directory -Force -Path $p | Out-Null
            Start-Process explorer.exe $p
            return @{ ok = $true; message = 'God Mode folder opened on the Desktop' }
        }
        'restore' {
            try {
                Checkpoint-Computer -Description 'Rafiq restore point' -RestorePointType 'MODIFY_SETTINGS'
                return @{ ok = $true; message = 'Restore point created' }
            } catch {
                return @{ ok = $false; message = "$_" }
            }
        }
        'privacy_pack' {
            foreach ($t in @('adsLock','adsStart','adsSettings','tailored','adId','copilot','widgets','searchBing')) {
                Invoke-RafiqTweak $t | Out-Null
            }
            return @{ ok = $true; message = 'Privacy pack applied' }
        }
        'clean_temp' { return Invoke-RafiqClean @('temp') }
        default { return @{ ok = $false; message = "Unknown action $Id" } }
    }
}

function Get-RafiqStartup {
    $items = @()
    foreach ($pair in @(
            @{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; loc = 'HKCU Run' },
            @{ path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; loc = 'HKLM Run' }
        )) {
        if (Test-Path $pair.path) {
            Get-ItemProperty $pair.path | ForEach-Object {
                $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                    $items += @{ name = $_.Name; command = [string]$_.Value; loc = $pair.loc; enabled = $true }
                }
            }
        }
    }
    return @{ ok = $true; items = $items }
}

function Toggle-RafiqStartup([string]$Name) {
    foreach ($path in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
        if (-not (Test-Path $path)) { continue }
        $item = Get-ItemProperty $path -ErrorAction SilentlyContinue
        if ($item.PSObject.Properties.Name -contains $Name) {
            $backup = Join-Path $path 'RafiqDisabled'
            if (-not (Test-Path $backup)) { New-Item $backup -Force | Out-Null }
            $val = (Get-ItemProperty $path).$Name
            Set-ItemProperty -Path $backup -Name $Name -Value $val -Force
            Remove-ItemProperty -Path $path -Name $Name -Force
            return @{ ok = $true; message = "Disabled $Name" }
        }
        $backup = Join-Path $path 'RafiqDisabled'
        if (Test-Path $backup) {
            $b = Get-ItemProperty $backup -ErrorAction SilentlyContinue
            if ($b.PSObject.Properties.Name -contains $Name) {
                Set-ItemProperty -Path $path -Name $Name -Value $b.$Name -Force
                Remove-ItemProperty -Path $backup -Name $Name -Force
                return @{ ok = $true; message = "Enabled $Name" }
            }
        }
    }
    return @{ ok = $false; message = 'Not found' }
}

function Get-RafiqWifi {
    $items = @()
    $raw = (netsh wlan show profiles) 2>$null
    $names = @()
    foreach ($line in ($raw -split "`n")) {
        if ($line -match ':\s*(.+)$' -and $line -match 'All User Profile|Profil Tous|Profilo|Profil') {
            $names += $Matches[1].Trim()
        } elseif ($line -match 'All User Profile\s*:\s*(.+)$') {
            $names += $Matches[1].Trim()
        }
    }
    if ($names.Count -eq 0) {
        foreach ($line in ($raw -split "`n")) {
            if ($line -match ':\s*(.+)$' -and $line -notmatch 'Interface') {
                $n = $Matches[1].Trim()
                if ($n -and $n -notmatch '^[0-9]+$') { $names += $n }
            }
        }
        $names = $names | Select-Object -Unique
    }
    foreach ($n in ($names | Select-Object -Unique)) {
        $detail = netsh wlan show profile name="$n" key=clear 2>$null
        $key = ''
        foreach ($line in ($detail -split "`n")) {
            if ($line -match 'Key Content\s*:\s*(.+)$' -or $line -match 'Contenu de la cl.+\s*:\s*(.+)$') {
                $key = $Matches[1].Trim()
            }
        }
        $items += @{ ssid = $n; key = $key }
    }
    return @{ ok = $true; items = $items }
}

function Get-RafiqPorts {
    $items = @()
    try {
        Get-NetTCPConnection -State Listen -ErrorAction Stop | Select-Object -First 80 | ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            $items += @{ port = $_.LocalPort; proto = 'TCP'; pid = $_.OwningProcess; name = $(if ($proc) { $proc.ProcessName } else { '?' }) }
        }
    } catch {
        foreach ($line in ((netstat -ano -p tcp) -split "`n")) {
            if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)') {
                $procId = [int]$Matches[2]
                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                $items += @{ port = [int]$Matches[1]; proto = 'TCP'; pid = $procId; name = $(if ($proc) { $proc.ProcessName } else { '?' }) }
            }
        }
    }
    return @{ ok = $true; items = $items }
}

function Invoke-RafiqAction($body) {
    $act = [string]$body.action
    Write-RafiqLog "action $act"
    if ($act -like 'dns_*') { return Set-RafiqDns ($act.Substring(4)) }
    if ($act -like 'tweak_*') { return Invoke-RafiqTweak ($act.Substring(6)) }
    if ($act -eq 'diagnose') { return Invoke-RafiqDiagnose }
    if ($act -eq 'clean') { return Invoke-RafiqClean $body.ids }
    if ($act -eq 'startup_toggle') { return Toggle-RafiqStartup ([string]$body.name) }
    if ($act -eq 'wifi') { return Get-RafiqWifi }
    if ($act -eq 'ports') { return Get-RafiqPorts }
    return Invoke-RafiqRepair $act
}

# --- embedded UI (replaced at build) ---
$HtmlB64 = @'
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImFyIiBkaXI9InJ0bCI+CjxoZWFkPgo8bWV0YSBjaGFyc2V0PSJVVEYtOCIvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiLz4KPHRpdGxlPlJhZmlxIOKAlCDYsdmB2YrZgiDZiNmK2YbYr9mI2LI8L3RpdGxlPgo8bGluayByZWw9Imljb24iIGhyZWY9ImRhdGE6aW1hZ2UvcG5nO2Jhc2U2NCxpVkJPUncwS0dnb0FBQUFOU1VoRVVnQUFBRUFBQUFCQUNBWUFBQUNxYVhIZUFBQWFrMGxFUVZSNG5HMmJlNUF0VjNYZWYydnQzWDNPbVpuN1FLK3JLd2trOFZJc1RBQWpIa0VZTEVnQ3lJRXlPSmd5U1FCWEpjYU9JYTQ0cVZTNVhDNmdrc0pPREhaU29oTEhxUlRCZ00zRDRXRlF3Q0c4UkNHUURMaEFQSVFlY0lXUXJxNTB1UTlwN3N5Y2M3cjN5aDlyN2U0ZUpWTTEwcG5iM2J2M2VuM3JXMnZ0STV1TExRTUJBUkF3LzlPSUgvTlBJdkhuOE8vcys1Rll3ekQvSERlSkNHWTIzRFhjTDRKTkZyTmh6WEZoUWZ3djhYMklqTS83UG4xdEVZWjNXbDBMUVVRUXMzMWI5VFZqTFlPTXVOQjFNNzZRRGNvUWhMaDN2RWNFeElhTldHeFVBRUZIZllZbWg4MVZJV1N5am8zdnNvbGlSS1lpeVNEOElKN29zRTlmb2lwSGh0ME02b3IxcHVvMVFCUXlnS2hpcFV4ZWgrdEpCS3hnS0FDcUlVUVZUZ3ppMmxRV0dkNWdnMEJHZUpiWVB1K3AyeEtSVVFacy9Hd1MrNG1GYmJ3ZVR1RHZDR01NNG90aEp0T1hERWF5aVl2bitxYXBlMDFkbUdxSmlkWE0yR2ZaY1lQdVNSWWFrTkNNREJzWHpNb29QWWFvQWpvcVZpeThTSUV5OFpMeC9hUEdRN0dUMEtrZVlqWXgxcU04YnRnT2tOM0NNc1NFRFZFMC90dWdCSWg0dHBCYWg4V0tHVlo2K3I1Z1ZpYlI3dTVxRXlGcUtBeWVhNk50cWdGczMyY0dEeEZSVUVWVkVJMDltMkZtcU9pZ2hsSEY3czBpUXJFU2N0VUlGaklXQ3cyYXFpamdMalQ2d3JpMEMxUllyMWRRakp3enM4V2MzRGJrK1J4SkdVMEpqWFZUU2hoQzZYc1hRTVpOMXMxVi9WUUlOUUdzUURHc0ZMcXVwKy9XV05leFdpNVo3ZXl4NnRhb0tLbkpxT28raktvS3I3ZzBYcHRnbVpVSkNFNHNWa2F2Y2RHSFRLQ0lHTjFxUlc0YUxyamtLSWN2dnBqNTRVTlkyOUNaZ01LcTYrbEw1OWFwMmc0cklja1hMNzJ2cWVvYkxpVXd4eTlyVG9PN1M0UmlRbWh6UWtXUjFacWQwMmM0ZS85eHpwNTRrUFZxUldyYThOb0luYW5ScGk2QklYVnZteHNIYkFDR2lhMWw0cEpWcTMzWElRSkhycnlTdzQ5N0xQMXN4dmJlTGp1N3V5eFhLL3F1cCs4NnJQUys3VkllQlZLanA0MmhGRUthVzBZcnVtdWtNUkhmcUFvaWlvcWdLYk9ZejFsc2JySzFzVWxlTGpsMTExMmMrTUV4ekFxYTg1QWVRU2NZTWhxNnlpeWJtd2RObUNEbUJDdnJSMUdsVzYzWVBIaVF5MzdtNmF4bkxRLzk1Q1I3NTNZcHBYZ01pbS9laHRRcEZNTFNnU0VpdmhrYnZLNE0zcWNpOFp4UzQ5UnEraFVaUGNVTURZVWFSazZaemExTkxyamdQTkxPSHZkODlWYTJUNStobWMzM0diREtzNThUZ0d4dUhyTEJKZXBsRzYwbUt2U3JOWSs1OUdJdWZPcFBjL0xoUnpoNytqU2w5T0c2KytKbHpQT1ZxSlFTRzlFQXJZQTRzd2kxTWY4blZmYzhBNUpRQW1oQm9CUlVQZVdhZ0FVSVNvRmlQWm9TaDg4L2p3dTNEdkhBclYvbjVJL3VwWm5QQTVCcjlobnhyUm9sai9FeVNYL2hoYUxLZXJua3ZNdU9jdjdUbnNxOUQ1eGc3OXlPSTdBRXNFaGxjU0V3SU1WR254N2lzRURSUWVEQkZZYzBHNGd1UWttR2lJRW9PckJCd1JRbkkzMUJ6S0FvSlF2aFNKdzVkWnJsY3NVbHozczJKbkRxUi9mU3poZVV2cWJUNERtVkZKbVJoenc2a0JqSFRWUW9YY2ZtWXc1eDRLb25jKy94QjFqdDdBSkdYenpsaktTaURPRGwyU1BjWW95aTBkWXlzSWFCQkEzSlNzRG9BeWc5VzVTKzkzdHpwdlJkT0pOemhIQmJSQVdWaEttd3Mxeng0NGRPY1BFMXoyQzVmWTZkTTJkSnVRa1RPTktWVWp6a0hMTkhEZGYvU2FRZ1ZlSHdrNTdJeWJOblEvaVJZTlJZcVdsTVZDSjEyZURHWlJweE5zbnM4UkpQaVFJa2hBUXBJZXJDbTRsN2tpcVdsWklVYXhwVU5SNUpTSk5CUXZpa21BZ3F3dDdla3BPNzU3am9tcWNIWG96dS8raWFRbXRLTnB0NEFyajFqeDVoSnllV2oreEVISTNrWk9MRVZXUElzSGkxdVRxcmN6QUpvQXVxTFdCU2tGTFpuUVdoOFJCU0JOT0lmL05ZVndRVC94MkVVYVZYQ1FicFZrYUY3WFBiN0cxdGNPanhsMU9XcXluckdNVTBjU0kvN0RsaXVCUlBKZW1DODlrNXR6M0dPYVBNRmhhdXRjUGdQaE9kcUZTUEN2WkZCY25Zamlta2hDWVpzbzNHL1poaFRYSlBzUXFzZ2lYMSsxVzhybEJRS2U1OXFsanlleEI0K053MnN5ZGNRWnExRHNiaElYV1Rucms4K2FBVDE2UXZOSWNPc2hUb2x1dEF6RW5jMnVnTlprYXh3dFNCWEZqZDUrb3E2cHRXRzF4ZlVnSlZDb28wQ2JPQ0pVSGFCTWt6aytTRTVveWs1TmR3YnhJWllDSkNHSW9xNUNaU1ptTGRyVmh2elpsZmVBRjBIYVBvMVdQZHF3YXJPYUs0R0xxNXdXcmREVzVKdFV4MTE1cFhyWXhFd3dGaUpEa3dPTnpBZ1VvSTMyUklBVVNxRkl1cXNSVG5GaWtoWmlpR1pVVnlJamNKVGY1OENVc1dvSWhpeWRmVFNIdW8xd1hMOVpwMDVQeFJUQmtKRmdJNkxWS29Pa2lKZmo2ajlMMjd6S0FjcW8ySGxGa0JiNGdpQk4vMkpGN0V3SUlkcXRCVHNHS2Uxd1d3M3A5VEJWTktNU2lPOG4xT1dBS1JndEZqZm91RHBUYVVwRWpPampZcVNFNklSdHBWWWIxZXcrR0RTSlBkdzZybnhtOHVacVJwaFdCQWsxbXJVbnJuNjVRcTRTamltTWQxbi9aR0loVHFFUVBTU0xRMGtWVllkVDNiNTdiWldHeVFrMElDcFVGUzhYQUpYaUhCSjNxcDVDV1lKQUthZ3BNRU9ZcjdKVHhPZ0NKR1AyK1J0c1gybHM0bHFyY0thQVVGcTUwZE0yaWJFZEFtNllOSHViYm9mbkNyeWhDekFETkg4NlNaUEp1UlozT1dxelZuVDUraGFUTC80TVV2WnV2Z0FVcndqNzd2YVhORHpza3JQQ2NDVVJHNkhZcHIzZCtkQTF2QzVldVdMVUpNbXhiVmhNMWFaRDRMVmxxTjdWNmNBMXpEQVNKSmFCWEVPYmhoVWVBTVp2ZHJnWGlWME5oUWdSa21TbEpQZld2ck9iZTlEY1Y0OHVPZndLdGYraEplOTRwWGNQU2lpM2p5TC93Q3E0Y2ZZWFBSY3RHRjUvSEQ0L2RUK3A2dHpRMW1zNGFPaVNkRzJTeEp2VEl0TmhSS3B1SWxjVkpLMTVHQ3pscGZzR3d3bncwUkdUa1FzMmlKamVSQUlqRFNlSE1rdStpSERXRXlZUUZCZ0dKbEsyaFN1czQ0ZDI0YlNzZDVGeDdoN3ozLytiejIrcGZ4a3VmL0xBZTN0Z0E0ZWVZTWFvWWtUMThmK2FNLzVNY25IdVJQYi93a1gvajZyWnc0ZVJKeVptTXhKMm1pcDVBMG9RRjRWc1NmclEwWU15U2xDQ0ZYVEJFb09jR3NkWStxdllJb3l2SW9TQkFNcVFoYTBmN1JVVi92TnlxMGp4elB3V2xuZDhuaHJTMWU4TnhuOGZMcnJ1UDZGN3lRS3krN0RIQ09VWC91ZmVBNHk5VWVTVHlWenR1VzY2KzlsdXV2dlpZZkhUL09wNzc2RmY3eXBpL3lsZS9jeHBuZEhSYXpHWktUYTc4UHhVbk5NQkVHZlhGanBlZ2NsUUk1SWZObVF0bkhiSlluRWcwcHExU0J6ZnR6VldNalR4N2NZNnk3eFVpYTJkblo0VGZlOEhwKzYvV3Y0L0pMTHVYUlAyYkc1Mi85YTk3ejhZOXk0NWUvek01NmhiU0pkZC9UZGV2aG5zY2RQY29iWC9rcTN2aktWM0hzK0hIZStjRVA4RjgrOGlFT3pBN1FSeXhiQ0tlYTZDdElSMlBGTUxMMXNaNW5oSXIvazE1SmRJWERyU2ZKMHRrWGt5Ym1wSEZSYzU1akJKZ1lJcG1VRzdyUzg4Sm5QNGZMTDdtVTNlV1N4Y3hqNzlqOTkvT0pMOXpFK3o5OUkxLzcxbTMwWlUyeldOQVZZMk14UjFWNC9kdmV5aSsvN0dXODhnWFhjZVVsbHdDd3MxeHl4ZEdqL096VG5zYTcvdUlEa0VhQ1ZTdFpLMjQ0U1FsU0hscDhQY1ZESW1kbzIxRnFHTHdtVDRVYnMvbEljSWErd09BcE1ucUxFT1dVVmhjQ1ZaYkxKY1dNTm1jK2MvTlh1T0g5NytPVzI3N05nNmRPMGN6bmJHMXVVSkl5YTFvdVAzb0ozemwyTjNzN3UzenR1OS9sYTdmZnpoKzgvNzA4NitxbjhPWmZlZzNYUGYyWkZET1czUXFhSEZoVlhQSFJhN1RJQUpZVktTNmRoM0tHckpnb3BlSmJOWFo0UXZZL0pwMWhsMzdDK2dJTERHZGhnMHQ1cFM2OUM5MG5vN2NlUkdsU2NnS1ZFdS8rK01mNHhJMmY1T0JsbDNMKytZY3dsQ0pDdDF4eS9zRkRmT3FHZDNIUDhmdjU4T2MreTZkdnZZVTc3N21IQjA2ZDVoUC82MGEyRGh6Z1JjKzRCZ0d5SnJlNEJ2WmtyeE9zQ0dvQ3M4WXhZZDFqS3FCUUVMUlVEeDlMOFdsakxFc0ZFTVl4azZyU1YrcUw1M1ZVSi9GT0tFVmM2MUZMbUZjbVk1Y1pXQ3ptcE1PSEVCV1c2dzVSSlNYLzdjSUsxMXg5TmRkY2ZUVnZYZjRxTjkvMkxUNzJwWnY0MkJjL3g4SEZGaWxTY29uU3VJaUNSaDlBWEJIZUhBSEVRUzdseWdtQ3NTYU4rVU9RcGpJT1h0UXFZeHVDZy85bm9NQ2tUeWVBbXFJV1pVUllXaldUTklOQjE0MmN3YXpRTDVlVXJsQ0VxT0E4ZlMyN05kczdPNk95WmpOZWZNMnp1T0ZmL2l0dWUrOEhlTTVQWGMxLy9maEhPZlh3dzh3WGMyaWlWNkJDaVRJdUo3d1hZSVlhYUp1Y0xpTStGelR6NmpENTMzWENORkJoL3lNR2pMVmlxWFY1RmRDOFJTWFJqcXFjSG5VeTR1MHJjd3NBNTFhclFhaXR4U2FrNUdqZEY4U2dRMGpKc2VJbHYvbG0vdjd6bnNjdlhuY2R6NzM2cDVtM0xXYUZ3d2NPc0ZmVy9QTi8reGIrOENNZjV2RGh3MnpPRmw0aTVBU04xd3lsTnkrQ0dxRXpROFVvSklwQXprcEsvcm1VT3ZDWmxPODFEZTZiNEZwaG1QQ0dXeWtqTTBURnk4N0tFSlJoWVUwWkZCNDZmV3A0eGVPT1hnb3AwYVJNUjhHTFFSbnE5Mk1uSCtSZGYvRkIvdmpHai9PVXk2L2c1NTkzTGRjLzkzbGMrNVNuY3NmOTk4SEduQk9Qbk9YWVQwNHluN2VJWml3SmFrWm5ocWdoVnZBMldsU0pDbG1FbEFJMFZaek9XYTFnQnhyZ2c1R2hHMVM5WHRRcHBrd0dscW5GR3lNU3BDa05RaUp1aGRvQys5SHg0OE9scTY2OGd0VE92S1lYbnl0NENBdDlFdWFMbGcwV2xLN3d2WHVPOGMyNzcrUWRILzV6bnYyM25zSjExMXpEYzU5NURkKzgrMDVta29LWEZDQjVOU21HNUtiMlV3ZVFTK0t6QTlNNjVQSDVvOGlqQ1YzTWpLcjgvbnpFTytZTkIxVWtOWmoxbExMMjZ5TCs4cGorYXE2TkRaQ200ZHQzM1QxNDFOOSswaE41ektHRGRQMmFyRUpTaWY1ZGdGcGY2RXVIRldQV3pqaDg4Q0R6eFFaZnUvTU9mdTFsTCtjcmYvU2YrZHkvLzQ4Y3VmQThscVVFR0Jja2dUWVpTVEpVZ21oQ200eHBvbmRuOXQ2cDVxRE1rOEl0c0VCclBweUNua1NlSmZDZHFMeW93MGNSYjFwR2g2ZG9VRkpndm1pNS9kNGZjT0xVVHp3RUxyNllwMTExRmVlV3UxaWpGRE9LT0RCSlh3SjNIS1E4Z3lSMjFpdCs3aG5YY09ReDU0SEJUMTErQlV1S3p4Z2xtcCt6K2NBRE5HWHZVb3ZUWTJrenFZbUtzc2t3eTE0NVVqUGIyTUJ4WHgrNDhRZ09sZnc0ZEhneWxhWmxhSUFraitHU2xGSjZYMVNNcHAzeDRFTVA4YVZ2ZkQyOFNuanRTMS9LZXQzUkFXdDZ4eGpWcU9vQTlRNnZaTjl3MTNXODVycnJTRkdKZnZLV3IzTGZReWVaenpkY2NacnB1K0lXMW9Ua2pHV2ZKMnJUeExFRjd5WmJzRUdMRHBIWldOdDRSaHVpZ2FqeWpHSUFtWktVUHJuQUdtMXEwWmp3aUJNYXJ4UTlGWlZZU1hMRCt6N3pWd2l3WHEvNWh5LzZ1eno1OFZleWMrNmM5K2lqNkVySng5d3BaY2labERJUDcrNXk5WlZQNEplZS93TDYzcWRQSC9yeUY1SFVrSkxTNUVTVGszZCtja3lGc2NDbzZDdXEwV0UrUFFvRGpST3F5QVRCY0hWb1NWZHFhNEhtUXpoTXFrUERYWFc4NGhraTU2Q2Zyb1ROclFOODVwWmIrZVlkM3llbHhNSE5UWDd2MTM2RGJ0MmhVYzQ2V2RJb3ZhT0hrSVYxdCtiMzN2QlAyWmpORVJYKzVnZDM4ZG5idnNHQnJRMHNlMytDcEVQODAvajdVL1pROVZadjlBNHhhREs1eWU1TlpUUjM1VHJSRnE4MGVBU0gycjFXcVNCamFPTllZRm5yUlJBaEZhSjNhQ1JSY3M3c0xaZTg3VDN2UmxYWld5NTUxYys5aU45NjNSdDQrTXdwbXRZSEdrV05FcUNZTkhIbTlHbCs1eCs5bmxjODUrK3dzN2VIaXZLMkQ3NmYzYjRudFlsbDZWaUwwV1VRTlRTUGRVb1JRVFRXeFZCSkxtaFBsTWIrOXpnVWtab2ZiRjhhckFDSGFIU0R2UHVpU2Vqd2dZbXpFWkNrUHFsUmphbE9IaWp6b2NPSCtlaVhidUxQUHZ0L21NOW03QzZYdk9QWDM4UWJYL1BMbkRwMWltS0dOaTA1enhCTm5ONCt5NXQrOGRYOHUzL3lLK3dzOTlpWXovblRMMzZXdjd6bFpnNXRiTkwxVVpVbW9aaDU1cWo3alJhWkpZR3NwTGJCUkVnNVEwNzBxaFF4ZENpSkdVci82QXJ2ejQrS3B6OENxRHpIQjZGSTZnT0xuSUptK3REU3gyTTZVRlZMeXRaaXpwdiswenY0NXQxM3Naak4yRnN1K2VQZi9OZTgvZGZmekZvSzI2c2xaNVk3clB1T1AvaG5iK0tHTjc2WjNlV1NqZG1jdnpuMlEvN0Z1LytFalVPSEtDbGpLYUhlSlBmNFRUNUtNd3lpTjJnQzFtUkltVHhManY2empMVE4wTENxSGw3ZFhEWVdXellNTUJEb083ajRDQnc1Z2xydkw3RktjY1E1ZFZTQ3BvTGw1QldYU0tDdU9OSEpEbkRuVm50Y2V0SEZmUHIzMzhsVmx6MldjN3U3YkM0Vy9QVWR0L052L3NkL0k2bnlIMzdsVi9tWkp6eUp2ZFdLZWR2eXZmdCt6UFZ2LzEwZU9IT0crY3hKVk1HUHloUk5xQkx0NzRSWUliVVpLOUFKYUZZa0pRVG9vMVRYclEyNno5MUs5L2xia0kwRjF2Y0RGWlN0amEzSyt0MTZYWWNjdVpEMHVFc3BmVCtRaDZMK2dPcGtnaFRad0lKK1doUkdUcTNkWlhQT2JLK1dIRG4vZk43LzI3L0xDNS82ZEZick5XM1RNUDFaZHgxTnpuemhPN2Z4ajI5NEp6L1pmb1N0eFlLKzd5R3AxL3c1VXJhcWw3dkZhT0o4VUZlTWdwOGhrRm5qakRVbjd6bHVMbGovNzV0WmZlRnJyb0JveXdVcm5RNExJd3o2UGxwaVBrYjJlWnhQWjZyZ0pnNDh4RlMyRjhIVTZiRlpjVnFjbEw3MGJNNFhQTFM5emMrLzViZDUrNGYrckI0dFpMbGFzYXlGazhEYlAvb2hYdjc3YitYMHppTXNOaGFzMVdLYzVzaGZyQS93OVRqVjdHamVJOUFtbXRtTXRKaGpDRGtudFBFc1V3UzZ2YVZubWpySk1vdTJtZFdDcnc0VERQcENaMzdrcFZKTktZWTJpcGlFeGQzNlhmUVA2Z1NwMXVHcXJqREIyZHBtTzhNby9NNTcvanVmdU9WbTN2TGExL1BTWno0TGdMLzY1amQ0NjUrL2w2L2UrVDBPYkIxZzBXWjZpU21PS3Rva256LzJEblNHenlMYkpsT1N6LzQxYVhTSEJFa3RodEZiNUhwQTl0YTF4S3NNenpGaFk3RlZENjA0OHZjOWNtZ0xlK0xqNCtDQkEwZUpNenBvRUNYMXVoc0pyazF0bXVMbGI0a2pjU2xqYlNiaml0T2NlR1JubXlMQ3E1Ly9Ba3lFLy9tVkx5R3FiR3h1MEJQVnA3ajFVbEkwcFhpbk4wT01IdEhzS1ZTaHlVMXdDOFBFQnlKOTZSdzNWTkNOQmVzLytRamRIY2VRK1d3NFB5d0NlY3ovREhXaXJkYUlGUzg5QTBna3lVQ0dKRVZEUW4wZVo3MERsTWE1SHRXRU5lMHd5OWZvSFpnWlhiOW1zYkZBUlBuZ3pUY2htam04ZFFCTFFtK1F0SWFaVXF2dTNnYUc0cGhqNWtSSUU2WHZLWkhGRzBtWWlIZVhrNUFrb1UyQzFacTkwMmM5b3dYcHEzTG5hVzA4ZEg3WEhicGVZNUZQaXpITTNVb2YrVDluTkFTM05pRTk5RTJpSHBiMm93cEtBcFRvRjJwR0pPRk5UZUc4ZzRkY1NTcjBWa2lpdFE3MUVFdGU5dm9VMlZWUVVnSnRvWmlQMUpLenZDSkdKNGEwaXZWR2FwTDdmdFBRMzNjQ3pqN2lOWU1ONWdhczlnUVppd0VWNkhvNHQ0c2MzSUsrUXlSaHBjZEVmY29xNGdPSVdzamdydWtaSWxHSW8zSEJCL280UTZ3WTFtUXlTaEZZWTVUU0Flb3VYTS8zcVRPM0lrNThmSDJ2UVhMYllDWVVaeVpvMjNwWFRvMWVvTVJneERTUlJMQjVRM2ZmQ2RoYncrYmNPMW82VmNEd2thRkFBS0djUGdOSEw0aWhnMUtVaUVjQjg1cTgxK1JsY20rUXNnOHhkVkovMTI1UkVUUXBtcU5IR0EwTGlXdVNuR0wzY1M1Skd2Y2JBWFJXTXd0QnVFQlVTTE1XNlExeVE2ZDlwREdmRXhSMXJQR3pXb24rOW1PVDR5clRFWWlRTFJMOXZubC9VdXpoYmRKeVRiKzVRTXc1UHJGaEVvTXJHMFpxNTk0WDZOMjFVNHBLc2NRRU9RVTVFWUVDSlFYV3hGeFF4WSt1bEZLUTFIaVpYWS92VzYwK0RacUd0UmxhZWxqN1BsUjZUNVc5MGVRTVRhSXZJRG43bVAvSEQ5RGZmZ3lkTlVIaFpVTDdoM0o0MmlZS1VPZ0w1YjRUd2ZHRE5WV2FXNWxoeXFnMm9ONUEwVG9QVUliMnVPYUV6bHBJbWRJRU5SV2xpN2FhSmovc2JMMGdpMWw4ZDhHWlhpK080a1dFb3NrOVRoUGF0bWhXTDZOTEdZQzVNNTlLTjRzWlpqMHl5OWlYdmdHN3l4anVSZ2tVYm04MmxNUGpMTEFxUVpvTUQ1NGtuVGtMVGVzdW03UVdWUjZiVFF1NXdZcGhSZVBNai9mNlRBMmR1eld0aStLSkZEV0ZzN2ZjSkQ4ZW94bVpOMmdQdlFnbHU5ZG9rN3lKbWwxSmhGZVVoUE43VFZodVVFMWVJcy85c0xTdDFxU05CZDMzNzJIOTFkdVFqZmxRd0xtWWxRVFVzeXlUMkI5N0J0RkJ2ZU1Zc2xwaldXSVM2d0JsOVRSbzZWeWw4OFpiNVVuOXVIeVRBM0FVWm1sSVFhSUNNeVcxR25rOVJXdk5ZMXl6ZTBVcEpXcis3RzB3Q0J4SlNNcVVFdVY1Ni8xSWxVUUtEN1JteHZyc05ydnYvU1NVeWJsQU0vWi9ZYU1lazZ1OWtBb1A5ZjZrMkxsZHlyZS83eDNHN0lNUHlaNE5pZ0JaMEpTUXZnTTErdVJmbnNDY0dqc1c0S0dqeGNtVE9WNlF3SksvVnpWRjJ2VXdvMGxJYXIyWVNWN25TNU9SeG8vVmFZQm1EUGdnUSttS24yNVJZZm51anlNUG5JUlpNM2gyclh3bmFGZVB6VTBQeS9lRGk0Z1ZiMzc4NUF6bDY5K0I5UnJiV0lDRTBOSFF0TVJRR3d5bnVpZVZvMVZhbkxPL3RwUklZOUZWVG5GZU1GS2Rha1p5UzhGUGZHaVR5SXZaeU9zeE5EV2VlUURKRFNtM2NPZ0FaYmxtNTRiM1ViNzdBOWhZeENDbjZpRGEvTkhLTTBDMk5nNGE0bWR3YWhSVUhCelFRZ1RXSGJhNVFKNTZGWHJwUmI3b3F2TVRYTm5kMkRPSW45bXREUldKV1o0WFZSTElvekJyZkNUYm01T1p0bzNXZFl5eW91cXJBTnkzaXBtQzlhU1V2TU9qUXBzeXRqR25aR1g5clR0WmZlQlQySU9uUE81N0d5ajZmc0pYdlFIL3drUjFpR2xUWkR4ZFBWRkc3ODFGZmV4UjlFbVhVdzV2SWJONXNEU3JKTk9wYWtwUkM5VDg2NjF6VVhGNm1wTFBFYnJPVTlhc2RXOFJ6eVlsQ3JEVXRQVHEvRUdhakNWb1dtK0pwMFdMOVlYdXJoK3ordnl0OUYvL3JvZEsyd3dISlFiUE5odGtISW12MUcrTVRPbFFkWVBSRzRiNW9McHd0dTRkMU00N2hCeTlBTDNnUEd4ckFWdno2TWk0OENsNVA5NTVmWFpMNXVUSnR3amFOaFRyUUJ3a1U1dXhsS01LZEdkcDVuTk1DdjJxYzBEVFFsNzFkQ2RPVVg3MEFNdnYzZ1UvdkI5V0hiSXhHOENPaVVUN1FIQ1E5ZityZ0ltMnF0VnI1VFFGeDFoTSt0NVRvQW95bTNram9rblFORDZ5eW1GUjRwUUdoYjRldW9qMHEwbkdUWnA1LzE2aStWV0pTOWRUMW10WXJyQzlKWnpid1hhVzBIVnhETTdQQnRDUGFieFlITWtkZHo5aGdGVXhobXh1SEp5eW9Db3p3NG1hZW1CeCt2VEVRd2FmTWZPRGZMWEJhbDRRRVJ1cHdHcjE3Y05id3lVampEeGt4N1kxRUhQSzZEelZYa1FjbVIyK2tMV1B6RTI4WUJvR0EvNlBqcDJuejlRTFRKV3d6K3I3WkI5bml2Vy9hYittalRRb2RBaWphdTFReDc3d3MzRTE4TUdteXJobWZkNk1vYTFGUFp3NVlOaHc5L0N2SS9PMy9WUVl5QllIallic3VFL1N5YkpERVZIaFR1S09xUmRNdEMvVHRjS0MxUWFUZmRiUittaTA4UlNYVEJhZmZxN1czVGZuZzMzS0hBeUpqRktFeDlSckVGUjRyQUtIUit1S2s0WHI4bFgwOFlucHZSYTdIUnhZTklTdkc1N1M3cW1sSGpXMEdNSnRERVdidVBvd294eGZQYm11aUV5UjdWR3VPMUhpT0FNYnZzUEZtUDhIVGU4RDFxSHZONFpBUFdBeE9ZczN2R3hpNCtrWEgvd0kwNkNRUWJESk16S3V4UEM0akY1WmxUb2M3cWo3cWk4ZlRybU5teS8xT0gxNDZmOEZRRWhFaXJMYy9td0FBQUFBU1VWT1JLNUNZSUk9Ii8+CjxzdHlsZT4KOnJvb3R7CiAgLS1iZzojMGIwZjEyOyAtLWJnMjojMTAxNjFiOyAtLWNhcmQ6IzE2MWQyMzsgLS1saW5lOiMyNDMwMzg7CiAgLS10ZXh0OiNlOGVlZjI7IC0tbXV0ZWQ6IzhiOWFhMzsgLS1hY2NlbnQ6IzFlYzhiMDsgLS1hY2NlbnQyOiMwZThmODA7CiAgLS13YXJuOiNmNWMxNmM7IC0tYmFkOiNmZjZiNmI7IC0tb2s6IzNkZDY4YzsgLS1zaGFkb3c6MCAxOHB4IDUwcHggcmdiYSgwLDAsMCwuMzUpOwogIC0tc2lkZToyNjhweDsKfQoqe2JveC1zaXppbmc6Ym9yZGVyLWJveH0KaHRtbCxib2R5e21hcmdpbjowO2hlaWdodDoxMDAlO2JhY2tncm91bmQ6dmFyKC0tYmcpO2NvbG9yOnZhcigtLXRleHQpOwogIGZvbnQtZmFtaWx5OiJTZWdvZSBVSSBWYXJpYWJsZSBUZXh0IiwiU2Vnb2UgVUkiLCJDYWlybyIsIlRhaG9tYSIsc2Fucy1zZXJpZjt9CmJvZHl7b3ZlcmZsb3c6aGlkZGVufQouYXBwe2Rpc3BsYXk6ZmxleDtoZWlnaHQ6MTAwJX0KLnNpZGV7d2lkdGg6dmFyKC0tc2lkZSk7ZmxleC1zaHJpbms6MDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxODBkZWcsIzBlMTQxOCwjMTAxODFkKTsKICBib3JkZXItaW5saW5lLWVuZDoxcHggc29saWQgdmFyKC0tbGluZSk7cGFkZGluZzoxOHB4IDEycHg7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6NnB4fQouYnJhbmR7ZGlzcGxheTpmbGV4O2dhcDoxMnB4O2FsaWduLWl0ZW1zOmNlbnRlcjtwYWRkaW5nOjhweCAxMHB4IDE2cHh9Ci5icmFuZCBpbWd7d2lkdGg6NDJweDtoZWlnaHQ6NDJweDtib3JkZXItcmFkaXVzOjEycHh9Ci5icmFuZCBoMXttYXJnaW46MDtmb250LXNpemU6MThweDtsZXR0ZXItc3BhY2luZzouM3B4fQouYnJhbmQgc21hbGx7ZGlzcGxheTpibG9jaztjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7bWFyZ2luLXRvcDoycHh9Ci5uYXZ7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6NHB4O2ZsZXg6MTtvdmVyZmxvdzphdXRvfQoubmF2IGJ1dHRvbnthcHBlYXJhbmNlOm5vbmU7Ym9yZGVyOjA7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtjb2xvcjp2YXIoLS10ZXh0KTt0ZXh0LWFsaWduOnN0YXJ0OwogIHBhZGRpbmc6MTBweCAxMnB4O2JvcmRlci1yYWRpdXM6MTJweDtjdXJzb3I6cG9pbnRlcjtkaXNwbGF5OmZsZXg7Z2FwOjEwcHg7YWxpZ24taXRlbXM6Y2VudGVyO2ZvbnQtc2l6ZToxNHB4fQoubmF2IGJ1dHRvbjpob3ZlcntiYWNrZ3JvdW5kOiMxYTI0MmJ9Ci5uYXYgYnV0dG9uLmFjdGl2ZXtiYWNrZ3JvdW5kOnJnYmEoMzAsMjAwLDE3NiwuMTQpO2NvbG9yOnZhcigtLWFjY2VudCl9Ci5uYXYgc3Zne3dpZHRoOjE4cHg7aGVpZ2h0OjE4cHg7ZmxleC1zaHJpbms6MH0KLnNpZGUtZm9vdHtwYWRkaW5nOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMXB4fQoubWFpbntmbGV4OjE7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjttaW4td2lkdGg6MH0KLnRvcHtoZWlnaHQ6NjRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6MCAyMnB4OwogIGJvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JhY2tncm91bmQ6cmdiYSgxNiwyMiwyNywuOSk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoMTJweCl9Ci5jaGlwc3tkaXNwbGF5OmZsZXg7Z2FwOjhweDthbGlnbi1pdGVtczpjZW50ZXJ9Ci5jaGlwe2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7YmFja2dyb3VuZDp2YXIoLS1jYXJkKTtjb2xvcjp2YXIoLS10ZXh0KTtib3JkZXItcmFkaXVzOjk5OXB4OwogIHBhZGRpbmc6NnB4IDEycHg7Zm9udC1zaXplOjEycHg7Y3Vyc29yOnBvaW50ZXJ9Ci5jaGlwLm9ue2JvcmRlci1jb2xvcjp2YXIoLS1hY2NlbnQpO2NvbG9yOnZhcigtLWFjY2VudCl9Ci5iYWRnZXtmb250LXNpemU6MTFweDtwYWRkaW5nOjRweCA4cHg7Ym9yZGVyLXJhZGl1czo5OTlweDtiYWNrZ3JvdW5kOiMxYTI0MmI7Y29sb3I6dmFyKC0tbXV0ZWQpfQouYmFkZ2UuYWRtaW57Y29sb3I6dmFyKC0tb2spO2JhY2tncm91bmQ6cmdiYSg2MSwyMTQsMTQwLC4xMil9Ci5iYWRnZS5kZW1ve2NvbG9yOnZhcigtLXdhcm4pO2JhY2tncm91bmQ6cmdiYSgyNDUsMTkzLDEwOCwuMTIpfQouY29udGVudHtmbGV4OjE7b3ZlcmZsb3c6YXV0bztwYWRkaW5nOjIycHggMjRweCA0MHB4fQpoMnttYXJnaW46MCAwIDZweDtmb250LXNpemU6MjZweH0KLnN1Yntjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luOjAgMCAyMHB4O2ZvbnQtc2l6ZToxNHB4fQouZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOnJlcGVhdCgxMiwxZnIpO2dhcDoxNHB4fQouY2FyZHtiYWNrZ3JvdW5kOnZhcigtLWNhcmQpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxNnB4O3BhZGRpbmc6MTZweCAxOHB4O2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KX0KLnNwYW40e2dyaWQtY29sdW1uOnNwYW4gNH0uc3BhbjZ7Z3JpZC1jb2x1bW46c3BhbiA2fS5zcGFuOHtncmlkLWNvbHVtbjpzcGFuIDh9LnNwYW4xMntncmlkLWNvbHVtbjpzcGFuIDEyfQoua3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEycHh9LnZ7Zm9udC1zaXplOjIycHg7bWFyZ2luLXRvcDo2cHg7Zm9udC13ZWlnaHQ6NjUwfQouYmFye2hlaWdodDo4cHg7YmFja2dyb3VuZDojMGMxMjE2O2JvcmRlci1yYWRpdXM6OTlweDtvdmVyZmxvdzpoaWRkZW47bWFyZ2luLXRvcDoxMHB4fQouYmFyPml7ZGlzcGxheTpibG9jaztoZWlnaHQ6MTAwJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1hY2NlbnQyKSx2YXIoLS1hY2NlbnQpKTt3aWR0aDo0MCV9Ci5yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDoxMHB4O2FsaWduLWl0ZW1zOmNlbnRlcn0KLmFjdGlvbnN7ZGlzcGxheTpmbGV4O2ZsZXgtd3JhcDp3cmFwO2dhcDo4cHg7bWFyZ2luLXRvcDoxMnB4fQpidXR0b24uYnRuLGEuYnRue2FwcGVhcmFuY2U6bm9uZTtib3JkZXI6MDtiYWNrZ3JvdW5kOnZhcigtLWFjY2VudCk7Y29sb3I6IzA0MjYxZjtmb250LXdlaWdodDo3MDA7CiAgcGFkZGluZzoxMHB4IDE0cHg7Ym9yZGVyLXJhZGl1czoxMnB4O2N1cnNvcjpwb2ludGVyO3RleHQtZGVjb3JhdGlvbjpub25lO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7Zm9udC1zaXplOjEzcHh9CmJ1dHRvbi5idG4uc2Vje2JhY2tncm91bmQ6IzFjMjcyZTtjb2xvcjp2YXIoLS10ZXh0KTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpfQpidXR0b24uYnRuLndhcm57YmFja2dyb3VuZDp2YXIoLS13YXJuKTtjb2xvcjojMmExZDAwfQpidXR0b24uYnRuLmJhZHtiYWNrZ3JvdW5kOnZhcigtLWJhZCk7Y29sb3I6I2ZmZn0KYnV0dG9uLmJ0bjpkaXNhYmxlZHtvcGFjaXR5Oi41O2N1cnNvcjpub3QtYWxsb3dlZH0KLmxpc3R7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4fQouaXRlbXtkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEwcHg7YWxpZ24taXRlbXM6Y2VudGVyO3BhZGRpbmc6MTBweCAxMnB4OwogIGJhY2tncm91bmQ6IzEwMTcxYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6MTJweH0KLml0ZW0gYntmb250LXdlaWdodDo2MDB9Ci50b2dnbGV7d2lkdGg6NDJweDtoZWlnaHQ6MjRweDtib3JkZXItcmFkaXVzOjk5cHg7YmFja2dyb3VuZDojMmEzMzM4O3Bvc2l0aW9uOnJlbGF0aXZlO2N1cnNvcjpwb2ludGVyO2JvcmRlcjowfQoudG9nZ2xlLm9ue2JhY2tncm91bmQ6dmFyKC0tYWNjZW50KX0KLnRvZ2dsZSBpe3dpZHRoOjE4cHg7aGVpZ2h0OjE4cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZmZmO3Bvc2l0aW9uOmFic29sdXRlO3RvcDozcHg7aW5zZXQtaW5saW5lLXN0YXJ0OjNweDt0cmFuc2l0aW9uOi4xNXN9Ci50b2dnbGUub24gaXtpbnNldC1pbmxpbmUtc3RhcnQ6MjFweH0KLmxvZ3tmb250LWZhbWlseTpDb25zb2xhcyx1aS1tb25vc3BhY2UsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMnB4O2JhY2tncm91bmQ6IzBjMTIxNjtib3JkZXItcmFkaXVzOjEycHg7CiAgcGFkZGluZzoxMnB4O21heC1oZWlnaHQ6MjQwcHg7b3ZlcmZsb3c6YXV0bzt3aGl0ZS1zcGFjZTpwcmUtd3JhcDtjb2xvcjojYjdjNGNifQoudG9hc3R7cG9zaXRpb246Zml4ZWQ7Ym90dG9tOjE4cHg7aW5zZXQtaW5saW5lLWVuZDoxOHB4O2JhY2tncm91bmQ6IzEzMjAyNjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjY2VudCk7CiAgY29sb3I6dmFyKC0tdGV4dCk7cGFkZGluZzoxMnB4IDE2cHg7Ym9yZGVyLXJhZGl1czoxMnB4O2Rpc3BsYXk6bm9uZTt6LWluZGV4OjIwO21heC13aWR0aDozNjBweH0KLmlzc3Vle3BhZGRpbmc6MTBweCAxMnB4O2JvcmRlci1yYWRpdXM6MTJweDtiYWNrZ3JvdW5kOiMxYTE3MTA7Ym9yZGVyOjFweCBzb2xpZCAjM2EzMjIwO2NvbG9yOnZhcigtLXdhcm4pO2ZvbnQtc2l6ZToxM3B4fQoub2tpc2h7YmFja2dyb3VuZDojMTAyMDE4O2JvcmRlci1jb2xvcjojMWU0O2NvbG9yOnZhcigtLW9rKX0KdGFibGV7d2lkdGg6MTAwJTtib3JkZXItY29sbGFwc2U6Y29sbGFwc2U7Zm9udC1zaXplOjEzcHh9CnRoLHRke3BhZGRpbmc6OHB4IDZweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lKTt0ZXh0LWFsaWduOnN0YXJ0fQouY2hlY2t7ZGlzcGxheTpmbGV4O2dhcDoxMHB4O2FsaWduLWl0ZW1zOmZsZXgtc3RhcnQ7cGFkZGluZzoxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMnB4O2JhY2tncm91bmQ6IzEwMTcxY30KLmhlcm8tc2NvcmV7ZGlzcGxheTpmbGV4O2dhcDoxOHB4O2FsaWduLWl0ZW1zOmNlbnRlcn0KLnJpbmd7d2lkdGg6ODhweDtoZWlnaHQ6ODhweH0KLmhpZGV7ZGlzcGxheTpub25lICFpbXBvcnRhbnR9CkBtZWRpYShtYXgtd2lkdGg6OTAwcHgpewogIGJvZHl7b3ZlcmZsb3c6YXV0b30KICAuYXBwe2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtoZWlnaHQ6YXV0bzttaW4taGVpZ2h0OjEwMCV9CiAgLnNpZGV7d2lkdGg6MTAwJTtib3JkZXI6MDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lKTtmbGV4LWRpcmVjdGlvbjpyb3c7ZmxleC13cmFwOndyYXB9CiAgLm5hdntmbGV4LWRpcmVjdGlvbjpyb3c7ZmxleC13cmFwOndyYXB9CiAgLnNwYW40LC5zcGFuNiwuc3Bhbjh7Z3JpZC1jb2x1bW46c3BhbiAxMn0KICAuY29udGVudHtwYWRkaW5nOjE2cHh9Cn0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0iYXBwIj4KICA8YXNpZGUgY2xhc3M9InNpZGUiPgogICAgPGRpdiBjbGFzcz0iYnJhbmQiPgogICAgICA8aW1nIGFsdD0iUmFmaXEiIHNyYz0iZGF0YTppbWFnZS9wbmc7YmFzZTY0LGlWQk9SdzBLR2dvQUFBQU5TVWhFVWdBQUFFQUFBQUJBQ0FZQUFBQ3FhWEhlQUFBYWswbEVRVlI0bkcyYmU1QXRWM1hlZjJ2dDNYM09tWm43UUsrckt3a2s4VklzVEFBakhrRVlMRWdDeUlFeU9KZ3lTUUJYSmNhT0lhNDRxVlM1WEM2Z2tzSk9ESFpTb2hMSHFSVEJnTTNENFdGUXdDRzhSQ0dRRExoQVBJUWVjSVdRcnE1MHVROXA3c3ljYzdyM3loOXI3ZTRlSlZNMTBwbmIzYnYzZW4zclcydnRJNXVMTFFNQkFSQXcvOU9JSC9OUEl2SG44Ty9zKzVGWXd6RC9IRGVKQ0dZMjNEWGNMNEpORnJOaHpYRmhRZnd2OFgySWpNLzdQbjF0RVlaM1dsMExRVVFRczMxYjlUVmpMWU9NdU5CMU03NlFEY29RaExoM3ZFY0V4SWFOV0d4VUFFRkhmWVltaDgxVklXU3lqbzN2c29saVJLWWl5U0Q4SUo3b3NFOWZvaXBIaHQwTTZvcjFwdW8xUUJReWdLaGlwVXhlaCt0SkJLeGdLQUNxSVVRVlRnemkybFFXR2Q1Z2cwQkdlSmJZUHUrcDJ4S1JVUVpzL0d3Uys0bUZiYndlVHVEdkNHTU00b3RoSnRPWERFYXlpWXZuK3FhcGUwMWRtR3FKaWRYTTJHZlpjWVB1U1JZYWtOQ01EQnNYek1vb1BZYW9Bam9xVml5OFNJRXk4Wkx4L2FQR1E3R1QwS2tlWWpZeDFxTThidGdPa04zQ01zU0VEVkUwL3R1Z0JJaDR0cEJhaDhXS0dWWjYrcjVnVmliUjd1NXFFeUZxS0F5ZWE2TnRxZ0ZzMzJjR0R4RlJVRVZWRUkwOW0yRm1xT2lnaGxIRjdzMGlRckVTY3RVSUZqSVdDdzJhcWlqZ0xqVDZ3cmkwQzFSWXIxZFFqSnd6czhXYzNEYmsrUnhKR1UwSmpYVlRTaGhDNlhzWFFNWk4xczFWL1ZRSU5RR3NRREdzRkxxdXArL1dXTmV4V2k1WjdleXg2dGFvS0tuSnFPbytqS29LcjdnMFhwdGdtWlVKQ0U0c1ZrYXZjZEdIVEtDSUdOMXFSVzRhTHJqa0tJY3Z2cGo1NFVOWTI5Q1pnTUtxNitsTDU5YXAyZzRySWNrWEw3MnZxZW9iTGlVd3h5OXJUb083UzRSaVFtaHpRa1dSMVpxZDAyYzRlLzl4enA1NGtQVnFSV3JhOE5vSW5hblJwaTZCSVhWdm14c0hiQUNHaWExbDRwSlZxMzNYSVFKSHJyeVN3NDk3TFAxc3h2YmVManU3dXl4WEsvcXVwKzg2clBTKzdWSWVCVktqcDQyaEZFS2FXMFlydW11a01SSGZxQW9paW9xZ0tiT1l6MWxzYnJLMXNVbGVMamwxMTEyYytNRXh6QXFhODVBZVFTY1lNaHE2eWl5Ym13ZE5tQ0RtQkN2clIxR2xXNjNZUEhpUXkzN202YXhuTFEvOTVDUjc1M1lwcFhnTWltL2VodFFwRk1MU2dTRWl2aGtidks0TTNxY2k4WnhTNDlScStoVVpQY1VNRFlVYVJrNlp6YTFOTHJqZ1BOTE9IdmQ4OVZhMlQ1K2htYzMzR2JES3M1OFRnR3h1SHJMQkplcGxHNjBtS3ZTck5ZKzU5R0l1Zk9wUGMvTGhSemg3K2pTbDlPRzYrK0pselBPVnFKUVNHOUVBcllBNHN3aTFNZjhuVmZjOEE1SlFBbWhCb0JSVVBlV2FnQVVJU29GaVBab1NoODgvand1M0R2SEFyVi9uNUkvdXBablBBNUJyOWhueHJSb2xqL0V5U1gvaGhhTEtlcm5rdk11T2N2N1Ruc3E5RDV4Zzc5eU9JN0FFc0VobGNTRXdJTVZHbng3aXNFRFJRZURCRlljMEc0Z3VRa21HaUlFb09yQkJ3UlFuSTMxQnpLQW9KUXZoU0p3NWRacmxjc1VsejNzMkpuRHFSL2ZTemhlVXZxYlQ0RG1WRkptUmh6dzZrQmpIVFZRb1hjZm1ZdzV4NEtvbmMrL3hCMWp0N0FKR1h6emxqS1NpRE9EbDJTUGNZb3lpMGRZeXNJYUJCQTNKU3NEb0F5ZzlXNVMrOTN0enB2UmRPSk56aEhCYlJBV1ZoS213czF6eDQ0ZE9jUEUxejJDNWZZNmRNMmRKdVFrVE9OS1ZVanprSExOSERkZi9TYVFnVmVId2s1N0l5Yk5uUS9pUllOUllxV2xNVkNKMTJlREdaUnB4TnNuczhSSlBpUUlraEFRcEllckNtNGw3a2lxV2xaSVVheHBVTlI1SlNKTkJRdmlrbUFncXd0N2VrcE83NTdqb21xY0hYb3p1LytpYVFtdEtOcHQ0QXJqMWp4NWhKeWVXait4RUhJM2taT0xFVldQSXNIaTF1VHFyY3pBSm9BdXFMV0JTa0ZMWm5RV2g4UkJTQk5PSWYvTllWd1FUL3gyRVVhVlhDUWJwVmthRjdYUGI3RzF0Y09qeGwxT1dxeW5yR01VMGNTSS83RGxpdUJSUEplbUM4OWs1dHozR09hUE1GaGF1dGNQZ1BoT2RxRlNQQ3ZaRkJjbllqaW1raENZWnNvM0cvWmhoVFhKUHNRcXNnaVgxKzFXOHJsQlFLZTU5cWxqeWV4QjQrTncyc3lkY1FacTFEc2JoSVhXVG5yazgrYUFUMTZRdk5JY09zaFRvbHV0QXpFbmMydWdOWmtheHd0U0JYRmpkNStvcTZwdFdHMXhmVWdKVkNvbzBDYk9DSlVIYUJNa3prK1NFNW95azVOZHdieElaWUNKQ0dJb3E1Q1pTWm1MZHJWaHZ6WmxmZUFGMEhhUG8xV1BkcXdhck9hSzRHTHE1d1dyZERXNUp0VXgxMTVwWHJZeEV3d0ZpSkRrd09OekFnVW9JMzJSSUFVU3FGSXVxc1JUbkZpa2haaWlHWlVWeUlqY0pUZjU4Q1VzV29JaGl5ZGZUU0h1bzF3WEw5WnAwNVB4UlRCa0pGZ0k2TFZLb09raUpmajZqOUwyN3pLQWNxbzJIbEZrQmI0Z2lCTi8ySkY3RXdJSWRxdEJUc0dLZTF3V3czcDlUQlZOS01TaU84bjFPV0FLUmd0Rmpmb3VEcFRhVXBFak9qallxU0U2SVJ0cFZZYjFldytHRFNKUGR3NnJueG04dVpxUnBoV0JBazFtclVucm42NVFxNFNqaW1NZDFuL1pHSWhUcUVRUFNTTFEwa1ZWWWRUM2I1N2JaV0d5UWswSUNwVUZTOFhBSlhpSEJKM3FwNUNXWUpBS2FncE1FT1lyN0pUeE9nQ0pHUDIrUnRzWDJsczRscXJjS2FBVUZxNTBkTTJpYkVkQW02WU5IdWJib2ZuQ3J5aEN6QUROSDg2U1pQSnVSWjNPV3F6Vm5UNStoYVRMLzRNVXZadXZnQVVyd2o3N3ZhWE5EenNrclBDY0NVUkc2SFlwcjNkK2RBMXZDNWV1V0xVSk1teGJWaE0xYVpENExWbHFON1Y2Y0ExekRBU0pKYUJYRU9iaGhVZUFNWnZkcmdYaVYwTmhRZ1JrbVNsSlBmV3ZyT2JlOURjVjQ4dU9md0t0ZitoSmU5NHBYY1BTaWkzanlML3dDcTRjZllYUFJjdEdGNS9IRDQvZFQrcDZ0elExbXM0YU9pU2RHMlN4SnZUSXROaFJLcHVJbGNWSksxNUdDemxwZnNHd3dudzBSR1RrUXMyaUpqZVJBSWpEU2VITWt1K2lIRFdFeVlRRkJnR0psSzJoU3VzNDRkMjRiU3NkNUZ4N2g3ejMvK2J6MitwZnhrdWYvTEFlM3RnQTRlZVlNYW9Za1QxOGYrYU0vNU1jbkh1UlBiL3drWC9qNnJadzRlUkp5Wm1NeEoybWlwNUEwb1FGNFZzU2ZyUTBZTXlTbENDRlhUQkVvT2NHc2RZK3F2WUlveXZJb1NCQU1xUWhhMGY3UlVWL3ZOeXEwanh6UHdXbG5kOG5oclMxZThOeG44ZkxycnVQNkY3eVFLeSs3REhDT1VYL3VmZUE0eTlVZVNUeVZ6dHVXNjYrOWx1dXZ2WllmSFQvT3A3NzZGZjd5cGkveWxlL2N4cG5kSFJhekdaS1RhNzhQeFVuTk1CRUdmWEZqcGVnY2xRSTVJZk5tUXRuSGJKWW5FZzBwcTFTQnpmdHpWV01qVHg3Y1k2eTd4VWlhMmRuWjRUZmU4SHArNi9XdjQvSkxMdVhSUDJiRzUyLzlhOTd6OFk5eTQ1ZS96TTU2aGJTSmRkL1RkZXZobnNjZFBjb2JYL2txM3ZqS1YzSHMrSEhlK2NFUDhGOCs4aUVPekE3UVJ5eGJDS2VhNkN0SVIyUEZNTEwxc1o1bmhJci9rMTVKZElYRHJTZkowdGtYa3libXBIRlJjNTVqQkpnWUlwbVVHN3JTODhKblA0ZkxMN21VM2VXU3hjeGo3OWo5OS9PSkw5ekUrejk5STEvNzFtMzBaVTJ6V05BVlkyTXhSMVY0L2R2ZXlpKy83R1c4OGdYWGNlVWxsd0N3czF4eXhkR2ovT3pUbnNhNy91SURrRWFDVlN0WksyNDRTUWxTSGxwOFBjVkRJbWRvMjFGcUdMd21UNFVicy9sSWNJYSt3T0FwTW5xTEVPV1VWaGNDVlpiTEpjV01ObWMrYy9OWHVPSDk3K09XMjc3Tmc2ZE8wY3puYkcxdVVKSXlhMW91UDNvSjN6bDJOM3M3dTN6dHU5L2xhN2ZmemgrOC83MDg2K3FuOE9aZmVnM1hQZjJaRkRPVzNRcWFIRmhWWFBIUmE3VElBSllWS1M2ZGgzS0dySmdvcGVKYk5YWjRRdlkvSnAxaGwzN0MrZ0lMREdkaGcwdDVwUzY5Qzkwbm83Y2VSR2xTY2dLVkV1LysrTWY0eEkyZjVPQmxsM0wrK1ljd2xDSkN0MXh5L3NGRGZPcUdkM0hQOGZ2NThPYyt5NmR2dllVNzc3bUhCMDZkNWhQLzYwYTJEaHpnUmMrNEJnR3lKcmU0QnZaa3J4T3NDR29DczhZeFlkMWpLcUJRRUxSVUR4OUw4V2xqTEVzRkVNWXhrNnJTVitxTDUzVlVKL0ZPS0VWYzYxRkxtRmNtWTVjWldDem1wTU9IRUJXVzZ3NVJKU1gvN2NJSzExeDlOZGRjZlRWdlhmNHFOOS8yTFQ3MnBadjQyQmMveDhIRkZpbFNjb25TdUlpQ1JoOUFYQkhlSEFIRVFTN2x5Z21Dc1NhTitVT1FwaklPWHRRcVl4dUNnLzlub01Da1R5ZUFtcUlXWlVSWVdqV1ROSU5CMTQyY3dhelFMNWVVcmxDRXFPQThmUzI3TmRzN082T3laak5lZk0yenVPRmYvaXR1ZSs4SGVNNVBYYzEvL2ZoSE9mWHd3OHdYYzJpaVY2QkNpVEl1Sjd3WFlJWWFhSnVjTGlNK0Z6VHo2akQ1MzNYQ05GQmgveU1HakxWaXFYVjVGZEM4UlNYUmpxcWNIblV5NHUwcmN3c0E1MWFyUWFpdHhTYWs1R2pkRjhTZ1EwakpzZUlsdi9sbS92N3puc2N2WG5jZHo3MzZwNW0zTFdhRnd3Y09zRmZXL1BOLyt4Yis4Q01mNXZEaHcyek9GbDRpNUFTTjF3eWxOeStDR3FFelE4VW9KSXBBemtwSy9ybVVPdkNabE84MURlNmI0RnBobVBDR1d5a2pNMFRGeTg3S0VKUmhZVTBaRkI0NmZXcDR4ZU9PWGdvcDBhUk1SOEdMUVJucTkyTW5IK1JkZi9GQi92akdqL09VeTYvZzU1OTNMZGMvOTNsYys1U25jc2Y5OThIR25CT1BuT1hZVDA0eW43ZUlaaXdKYWtabmhxZ2hWdkEyV2xTSkNsbUVsQUkwVlp6T1dhMWdCeHJnZzVHaEcxUzlYdFFwcGt3R2xxbkZHeU1TcENrTlFpSnVoZG9DKzlIeDQ4T2xxNjY4Z3RUT3ZLWVhueXQ0Q0F0OUV1YUxsZzBXbEs3d3ZYdU84YzI3NytRZEgvNXpudjIzbnNKMTExekRjNTk1RGQrOCswNW1rb0tYRkNCNU5TbUc1S2IyVXdlUVMrS3pBOU02NVBINW84aWpDVjNNaktyOC9uekVPK1lOQjFVa05aajFsTEwyNnlMKzhwaithcTZORFpDbTRkdDMzVDE0MU45KzBoTjV6S0dEZFAyYXJFSlNpZjVkZ0ZwZjZFdUhGV1BXempoODhDRHp4UVpmdS9NT2Z1MWxMK2NyZi9TZitkeS8vNDhjdWZBOGxxVUVHQmNrZ1RZWlNUSlVnbWhDbTR4cG9uZG45dDZwNXFETWs4SXRzRUJyUHB5Q25rU2VKZkNkcUx5b3cwY1JiMXBHaDZkb1VGSmd2bWk1L2Q0ZmNPTFVUendFTHI2WXAxMTFGZWVXdTFpakZET0tPREJKWHdKM0hLUThneVIyMWl0KzdoblhjT1F4NTRIQlQxMStCVXVLenhnbG1wK3orY0FETkdYdlVvdlRZMmt6cVltS3Nza3d5MTQ1VWpQYjJNQnhYeCs0OFFnT2xmdzRkSGd5bGFabGFJQWtqK0dTbEZKNlgxU01wcDN4NEVNUDhhVnZmRDI4U25qdFMxL0tldDNSQVd0Nnh4alZxT29BOVE2dlpOOXcxM1c4NXJyclNGR0pmdktXcjNMZlF5ZVp6emRjY1pycHUrSVcxb1RrakdXZkoyclR4TEVGN3laYnNFR0xEcEhaV050NFJodWlnYWp5akdJQW1aS1VQcm5BR20xcTBaandpQk1hcnhROUZaVllTWExEK3o3elZ3aXdYcS81aHkvNnV6ejU4VmV5Yys2YzkraWo2RXJKeDl3cFpjaVpsRElQNys1eTlaVlA0SmVlL3dMNjNxZFBIL3J5RjVIVWtKTFM1RVNUazNkK2NreUZzY0NvNkN1cTBXRStQUW9EalJPcXlBVEJjSFZvU1ZkcWE0SG1RemhNcWtQRFhYVzg0aGtpNTZDZnJvVE5yUU44NXBaYitlWWQzeWVseE1ITlRYN3YxMzZEYnQyaFVjNDZXZElvdmFPSGtJVjF0K2IzM3ZCUDJaak5FUlgrNWdkMzhkbmJ2c0dCclEwc2UzK0NwRVA4MC9qN1UvWlE5Vlp2OUE0eGFESzV5ZTVOWlRSMzVUclJGcTgwZUFTSDJyMVdxU0JqYU9OWVlGbnJSUkFoRmFKM2FDUlJjczdzTFplODdUM3ZSbFhaV3k1NTFjKzlpTjk2M1J0NCtNd3BtdFlIR2tXTkVxQ1lOSEhtOUdsKzV4KzlubGM4NSsrd3M3ZUhpdksyRDc2ZjNiNG50WWxsNlZpTDBXVVFOVFNQZFVvUlFUVFd4VkJKTG1oUGxNYis5emdVa1pvZmJGOGFyQUNIYUhTRHZQdWlTZWp3Z1ltekVaQ2tQcWxSamFsT0hpanpvY09IK2VpWGJ1TFBQdnQvbU05bTdDNlh2T1BYMzhRYlgvUExuRHAxaW1LR05pMDV6eEJObk40K3k1dCs4ZFg4dTMveUsrd3M5OWlZei9uVEwzNld2N3psWmc1dGJOTDFVWlVtb1poNTVxajdqUmFaSllHc3BMYkJSRWc1UTA3MHFoUXhkQ2lKR1VyLzZBcnZ6NCtLcHo4Q3FEekhCNkZJNmdPTG5JSm0rdERTeDJNNlVGVkx5dFppenB2KzB6djQ1dDEzc1pqTjJGc3UrZVBmL05lOC9kZmZ6Rm9LMjZzbFo1WTdyUHVPUC9obmIrS0dONzZaM2VXU2pkbWN2em4yUS83RnUvK0VqVU9IS0NsakthSGVKUGY0VFQ1S013eWlOMmdDMW1SSW1UeExqdjZ6akxUTjBMQ3FIbDdkWERZV1d6WU1NQkRvTzdqNENCdzVnbHJ2TDdGS2NjUTVkVlNDcG9MbDVCV1hTS0N1T05ISkRuRG5WbnRjZXRIRmZQcjMzOGxWbHoyV2M3dTdiQzRXL1BVZHQvTnYvc2QvSTZueUgzN2xWL21aSnp5SnZkV0tlZHZ5dmZ0K3pQVnYvMTBlT0hPRytjeEpWTUdQeWhSTnFCTHQ3NFJZSWJVWks5QUphRllrSlFUb28xVFhyUTI2ejkxSzkvbGJrSTBGMXZjREZaU3RqYTNLK3QxNlhZY2N1WkQwdUVzcGZUK1FoNkwrZ09wa2doVFp3SUorV2hSR1RxM2RaWFBPYksrV0hEbi9mTjcvMjcvTEM1LzZkRmJyTlczVE1QMVpkeDFOem56aE83ZnhqMjk0SnovWmZvU3R4WUsrN3lHcDEvdzVVcmFxbDd2RmFPSjhVRmVNZ3A4aGtGbmpqRFVuN3psdUxsai83NXRaZmVGcnJvQm95d1VyblE0TEl3ejZQbHBpUGtiMmVaeFBaNnJnSmc0OHhGUzJGOEhVNmJGWmNWcWNsTDcwYk00WFBMUzl6YysvNWJkNSs0ZityQjR0WkxsYXNheUZrOERiUC9vaFh2NzdiK1gwemlNc05oYXMxV0tjNXNoZnJBL3c5VGpWN0dqZUk5QW1tdG1NdEpoakNEa250UEVzVXdTNnZhVm5tanJKTW91Mm1kV0NydzRURFBwQ1ozN2twVkpOS1lZMmlwaUV4ZDM2WGZRUDZnU3AxdUdxcmpEQjJkcG1POE1vL001Ny9qdWZ1T1ZtM3ZMYTEvUFNaejRMZ0wvNjVqZDQ2NSsvbDYvZStUME9iQjFnMFdaNmlTbU9LdG9rbnovMkRuU0d6eUxiSmxPU3ovNDFhWFNIQkVrdGh0RmI1SHBBOXRhMXhLc016ekZoWTdGVkQ2MDQ4dmM5Y21nTGUrTGo0K0NCQTBlSk16cG9FQ1gxdWhzSnJrMXRtdUxsYjRramNTbGpiU2JqaXRPY2VHUm5teUxDcTUvL0FreUUvL21WTHlHcWJHeHUwQlBWcDdqMVVsSTBwWGluTjBPTUh0SHNLVlNoeVUxd0M4UEVCeUo5NlJ3M1ZOQ05CZXMvK1FqZEhjZVErV3c0UHl3Q2Vjei9ESFdpcmRhSUZTODlBMGdreVVDR0pFVkRRbjBlWjcwRGxNYTVIdFdFTmUwd3k5Zm9IWmdaWGI5bXNiRkFSUG5nelRjaG1qbThkUUJMUW0rUXRJYVpVcXZ1M2dhRzRwaGo1a1JJRTZYdktaSEZHMG1ZaUhlWGs1QWtvVTJDMVpxOTAyYzlvd1hwcTNMbmFXMDhkSDdYSGJwZVk1RlBpekhNM1VvZitUOW5OQVMzTmlFOTlFMmlIcGIyb3dwS0FwVG9GMnBHSk9GTlRlRzhnNGRjU1NyMFZraWl0UTcxRUV0ZTl2b1UyVlZRVWdKdG9aaVAxSkt6dkNKR0o0YTBpdlZHYXBMN2Z0UFEzM2NDemo3aU5ZTU41Z2FzOWdRWml3RVY2SG80dDRzYzNJSytReVJocGNkRWZjb3E0Z09JV3NqZ3J1a1pJbEdJbzNIQkIvbzRRNndZMW1ReVNoRllZNVRTQWVvdVhNLzNxVE8zSWs1OGZIMnZRWExiWUNZVVp5Wm8yM3BYVG8xZW9NUmd4RFNSUkxCNVEzZmZDZGhidytiY08xbzZWY0R3a2FGQUFLR2NQZ05ITDRpaGcxS1VpRWNCODVxODErUmxjbStRc2c4eGRWSi8xMjVSRVRRcG1xTkhHQTBMaVd1U25HTDNjUzVKR3ZjYkFYUldNd3RCdUVCVVNMTVc2UTF5UTZkOXBER2ZFeFIxclBHeldvbis5bU9UNHlyVEVZaVFMUkw5dm5sL1V1emhiZEp5VGIrNVFNdzVQckZoRW9NckcwWnE1OTRYNk4yMVU0cEtzY1FFT1FVNUVZRUNKUVhXeEZ4UXhZK3VsRktRMUhpWlhZL3ZXNjArRFpxR3RSbGFlbGo3UGxSNlQ1VzkwZVFNVGFJdklEbjdtUC9IRDlEZmZneWROVUhoWlVMN2gzSjQyaVlLVU9nTDViNFR3ZkdETlZXYVc1bGh5cWcyb041QTBUb1BVSWIydU9hRXpscEltZElFTlJXbGk3YWFKai9zYkwwZ2kxbDhkOEdaWGkrTzRrV0Vvc2s5VGhQYXRtaFdMNk5MR1lDNU01OUtONHNaWmoweXk5aVh2Z0c3eXhqdVJna1VibTgybE1QakxMQXFRWm9NRDU0a25Ua0xUZXN1bTdRV1ZSNmJUUXU1d1lwaFJlUE1qL2Y2VEEyZHV6V3RpK0tKRkRXRnM3ZmNKRDhlb3htWk4yZ1B2UWdsdTlkb2s3eUptbDFKaEZlVWhQTjdUVmh1VUUxZUlzLzlzTFN0MXFTTkJkMzM3Mkg5MWR1UWpmbFF3TG1ZbFFUVXN5eVQyQjk3QnRGQnZlTVlzbHBqV1dJUzZ3Qmw5VFJvNlZ5bDg4WmI1VW45dUh5VEEzQVVabWxJUWFJQ015VzFHbms5Uld2TlkxeXplMFVwSldyKzdHMHdDQnhKU01xVUV1VjU2LzFJbFVRS0Q3Um14dnJzTnJ2di9TU1V5YmxBTS9aL1lhTWVrNnU5a0FvUDlmNmsyTGxkeXJlLzd4M0c3SU1QeVo0TmlnQlowSlNRdmdNMSt1UmZuc0NjR2pzVzRLR2p4Y21UT1Y2UXdKSy9WelZGMnZVd28wbElhcjJZU1Y3blM1T1J4by9WYVlCbURQZ2dRK21LbjI1UllmbnVqeU1QbklSWk0zaDJyWHduYUZlUHpVMFB5L2VEaTRnVmIzNzg1QXpsNjkrQjlScmJXSUNFME5IUXRNUlFHd3ludWllVm8xVmFuTE8vdHBSSVk5RlZUbkZlTUZLZGFrWnlTOEZQZkdpVHlJdlp5T3N4TkRXZWVRREpEU20zY09nQVpibG01NGIzVWI3N0E5aFl4Q0NuNmlEYS9OSEtNMEMyTmc0YTRtZHdhaFJVSEJ6UVFnVFdIYmE1UUo1NkZYcnBSYjdvcXZNVFhObmQyRE9JbjltdERSV0pXWjRYVlJMSW96QnJmQ1RibTVPWnRvM1dkWXl5b3VxckFOeTNpcG1DOWFTVXZNT2pRcHN5dGpHblpHWDlyVHRaZmVCVDJJT25QTzU3R3lqNmZzSlh2UUgvd2tSMWlHbFRaRHhkUFZGRzc4MUZmZXhSOUVtWFV3NXZJYk41c0RTckpOT3Bha3BSQzlUODY2MXpVWEY2bXBMUEVick9VOWFzZFc4Unp5WWxDckRVdFBUcS9FR2FqQ1ZvV20rSnAwV0w5WVh1cmgreit2eXQ5Ri8vcm9kSzJ3d0hKUWJQTmh0a0hJbXYxRytNVE9sUWRZUFJHNGI1b0xwd3R1NGQxTTQ3aEJ5OUFMM2dQR3hyQVZ2ejZNaTQ4Q2w1UDk1NWZYWkw1dVRKdHdqYU5oVHJRQndrVTV1eGxLTUtkR2RwNW5OTUN2MnFjMERUUWw3MWRDZE9VWDcwQU12djNnVS92QjlXSGJJeEc4Q09pVVQ3UUhDUTlmK3JnSW0ycXRWcjVUUUZ4MWhNK3Q1VG9Bb3ltM2tqb2tuUU5ENnl5bUZSNHBRR2hiNGV1b2owcTBuR1RacDUvMTZpK1ZXSlM5ZFQxbXRZcnJDOUpaemJ3WGFXMEhWeERNN1BCdENQYWJ4WUhNa2RkejloZ0ZVeGhteHVISnl5b0Nvenc0bWFlbUJ4K3ZURVF3YWZNZk9EZkxYQmFsNFFFUnVwd0dyMTdjTmJ3eVVqakR4a3g3WTFFSFBLNkR6VlhrUWNtUjIra0xXUHpFMjhZQm9HQS82UGpwMm56OVFMVEpXd3orcjdaQjluaXZXL2FiK21qVFFvZEFpamF1MVF4Nzd3czNFMThNR215cmhtZmQ2TW9hMUZQWnc1WU5odzkvQ3ZJL08zL1ZRWXlCWUhqWWJzdUUvU3liSkRFVkhoVHVLT3FSZE10Qy9UdGNLQzFRYVRmZGJSK21pMDhSU1hUQmFmZnE3VzNUZm5nMzNLSEF5SmpGS0V4OVJyRUZSNHJBS0hSK3VLazRYcjhsWDA4WW5wdlJhN0hSeFlOSVN2RzU3UzdxbWxIalcwR01KdERFV2J1UG93b3h4ZlBibXVpRXlSN1ZHdU8xSGlPQU1idnNQRm1QOEhUZThEMXFIdk40WkFQV0F4T1lzM3ZHeGk0K2tYSC93STA2Q1FRYkRKTXpLdXhQQzRqRjVabFRvYzdxajdxaThmVHJtTm15LzFPSDE0NmY4RlFFaEVpckxjL213QUFBQUFTVVZPUks1Q1lJST0iLz4KICAgICAgPGRpdj48aDE+UmFmaXE8L2gxPjxzbWFsbCBpZD0idGFnbGluZSI+2LHZgdmK2YLZgyDZhNil2LXZhNin2K0g2YjZitmG2K/ZiNiyPC9zbWFsbD48L2Rpdj4KICAgIDwvZGl2PgogICAgPG5hdiBjbGFzcz0ibmF2IiBpZD0ibmF2Ij48L25hdj4KICAgIDxkaXYgY2xhc3M9InNpZGUtZm9vdCIgaWQ9InZlciI+UmFmaXEgMS4wLjAgwrcgV2luZG93cyAxMC8xMTwvZGl2PgogIDwvYXNpZGU+CiAgPHNlY3Rpb24gY2xhc3M9Im1haW4iPgogICAgPGhlYWRlciBjbGFzcz0idG9wIj4KICAgICAgPGRpdiBjbGFzcz0iY2hpcHMiPgogICAgICAgIDxzcGFuIGNsYXNzPSJiYWRnZSIgaWQ9Im1vZGVCYWRnZSI+4oCmPC9zcGFuPgogICAgICAgIDxzcGFuIGNsYXNzPSJiYWRnZSIgaWQ9ImFkbWluQmFkZ2UiPjwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNoaXBzIj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjaGlwIiBpZD0iYnRuQXIiPti52LHYqNmKPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2hpcCIgaWQ9ImJ0bkVuIj5FTjwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgIDwvaGVhZGVyPgogICAgPGRpdiBjbGFzcz0iY29udGVudCIgaWQ9InZpZXciPjwvZGl2PgogIDwvc2VjdGlvbj4KPC9kaXY+CjxkaXYgY2xhc3M9InRvYXN0IiBpZD0idG9hc3QiPjwvZGl2Pgo8c2NyaXB0Pgpjb25zdCBUID0gewphcjp7CiB0YWdsaW5lOiLYsdmB2YrZgtmDINmE2KXYtdmE2KfYrSDZiNmK2YbYr9mI2LIgMTAg2YggMTEiLAogbmF2OntkYXNoOiLZhNmI2K3YqSDYp9mE2YXYudmE2YjZhdin2KoiLG5ldDoi2LfYqNmK2Kgg2KfZhNi02KjZg9ipIixzdG9yYWdlOiLYqtmG2LjZitmBINin2YTZhdiz2KfYrdipIixwcml2YWN5OiLYp9mE2K7YtdmI2LXZitipIix0d2Vha3M6Itiq2K7YtdmK2LUg2YjZitmG2K/ZiNiyIixyZXBhaXI6Itin2YTYpdi12YTYp9itINin2YTYs9ix2YrYuSIsc3RhcnR1cDoi2KjYsdin2YXYrCDYp9mE2KXZgtmE2KfYuSIsdG9vbHM6Itin2YTYo9iv2YjYp9iqIixhYm91dDoi2K3ZiNmEIn0sCiBkYXNoOiLZhNmI2K3YqSDYp9mE2YXYudmE2YjZhdin2KoiLCBkYXNoU3ViOiLYtdit2Kkg2KfZhNis2YfYp9iy2Iwg2KfZhNmF2LPYp9it2KnYjCDZiNin2YTYtNio2YPYqSDZgdmKINmF2YPYp9mGINmI2KfYrdivLiIsCiBoZWFsdGg6ItmF2KTYtNixINin2YTYtdit2KkiLCBvczoi2YbYuNin2YUg2KfZhNiq2LTYutmK2YQiLCByYW06Itin2YTYsNin2YPYsdipIiwgZGlzazoi2KfZhNmC2LHYtSBDOiIsIHVwdGltZToi2YjZgtiqINin2YTYqti02LrZitmEIiwgbmV0OiLYp9mE2LTYqNmD2KkiLAogcXVpY2s6Itil2KzYsdin2KHYp9iqINiz2LHZiti52KkiLCBmbHVzaDoi2KrZgdix2YrYuiBETlMiLCBjbGVhbjoi2KrZhti42YrZgSDYp9mE2YXZhNmB2KfYqiDYp9mE2YXYpNmC2KrYqSIsIGV4cGxvcmVyOiLYpdi52KfYr9ipINiq2LTYutmK2YQgRXhwbG9yZXIiLAogaXNzdWVzOiLYqtmG2KjZitmH2KfYqiIsIG5vSXNzdWVzOiLZhNinINiq2YjYrNivINmF2LTYp9mD2YQg2YjYp9i22K3YqS4iLAogbmV0VGl0bGU6Iti32KjZitioINin2YTYtNio2YPYqSIsIG5ldFN1Yjoi2YfYsNmHINmH2Yog2KfZhNmF2LTZg9mE2Kkg2LHZgtmFINmI2KfYrdivINmE2KrYsNin2YPYsSDYp9mE2K/YudmFOiDYp9mE2KXZhtiq2LHZhtiqINmF2YjYrNmI2K8g2YTZg9mGINin2YTZhdmI2KfZgti5INmE2Kcg2KrZj9mB2KrYrS4iLAogZGlhZ25vc2U6Itiq2LTYrtmK2LUg2KfZhNii2YYiLCBkbnNGbHVzaDoi2KrZgdix2YrYuiBETlMiLCByZW5ldzoi2KrYrNiv2YrYryBJUCIsIHdpbnNvY2s6Itil2LnYp9iv2Kkg2LbYqNi3IFdpbnNvY2siLCBpcHJlc2V0OiLYpdi52KfYr9ipINi22KjYtyBUQ1AvSVAiLAogZG5zOiLYrtin2K/ZhSBETlMiLCBjbG91ZGZsYXJlOiJDbG91ZGZsYXJlIDEuMS4xLjEiLCBnb29nbGU6Ikdvb2dsZSA4LjguOC44IiwgYWRndWFyZDoiQWRHdWFyZCIsIHF1YWQ5OiJRdWFkOSIsIGRoY3A6Itiq2YTZgtin2KbZiiAoREhDUCkiLAogYWRhcHRlcnM6Itin2YTZhdit2YjZkdmE2KfYqiIsIHRlc3RzOiLZhtiq2KfYptisINin2YTZgdit2LUiLAogc3RUaXRsZToi2KrZhti42YrZgSDYotmF2YYg2YTZhNmF2LPYp9it2KkiLCBzdFN1Yjoi2YbYudix2LYg2KfZhNit2KzZhSDYo9mI2YTYp9mLLiDZhNinINmG2K3YsNmBINmF2YTZgdin2KrZgyDYp9mE2LTYrti12YrYqSDZiNmE2Kcg2YbZhNmF2LMg2KfZhNix2YrYrNiz2KrYsdmKLiIsCiBzY2FuOiLZgdit2LUg2KfZhNii2YYiLCBjbGVhblNlbDoi2K3YsNmBINin2YTZhdit2K/YryIsIHJlY3ljbGU6Itiz2YTYqSDYp9mE2YXYrdiw2YjZgdin2KoiLCB0ZW1wOiLYp9mE2YXZhNmB2KfYqiDYp9mE2YXYpNmC2KrYqSIsIHVwZGF0ZXM6Itiw2KfZg9ix2Kkg2KfZhNiq2K3Yr9mK2KvYp9iqIiwgZG86IkRlbGl2ZXJ5IE9wdGltaXphdGlvbiIsIHRodW1iczoi2LDYp9mD2LHYqSDYp9mE2LXZiNixINin2YTZhdi12LrYsdipIiwgZHVtcHM6Itiq2YLYp9ix2YrYsSDYp9mE2KPYudi32KfZhCIsCiBwclRpdGxlOiLYr9ix2Lkg2KfZhNiu2LXZiNi12YrYqSIsIHByU3ViOiLZiNmK2YbYr9mI2LIgMTEg2YrYtti5INil2LnZhNin2YbYp9iqINmI2KfZgtiq2LHYp9it2KfYqiDZiCBDb3BpbG90INmB2Yog2KPZhdin2YPZhiDZhNinINmK2KrZiNmC2LnZh9inINij2K3Yry4iLAogYXBwbHlQcml2OiLYqti32KjZitmCINin2YTYrdmF2KfZitipIiwKIHR3VGl0bGU6Itiq2K7YtdmK2LUg2YjZitmG2K/ZiNiyIiwgdHdTdWI6Itin2LPYqtix2KzYuSDZgtin2KbZhdipINin2YTZhtmC2LEg2KfZhNmK2YXZitmG2Yog2KfZhNmD2YTYp9iz2YrZg9mK2Kkg2YjYo9iu2YHZkCDZhdinINmE2Kcg2KrYrdiq2KfYrNmHLiIsCiBycFRpdGxlOiLYpdi12YTYp9itINiz2LHZiti5IiwgcnBTdWI6Itiu2K/Zhdin2Kog2YjZitmG2K/ZiNiyINin2YTYqtmKINiq2LnZhNmCINmK2YjZhdmK2KfZizog2KfZhNi12YjYqtiMINin2YTYt9in2KjYudip2Iwg2KfZhNio2K3Yq9iMINin2YTZhdiq2KzYsS4iLAogc3VUaXRsZToi2KjYsdin2YXYrCDYp9mE2KXZgtmE2KfYuSIsIHN1U3ViOiLZg9mEINio2LHZhtin2YXYrCDZgdmKINin2YTYpdmC2YTYp9i5INmK2KjYt9imINmB2KrYrSDYp9mE2KzZh9in2LIuINi52LfZkdmEINmF2Kcg2YTYpyDYqtit2KrYp9is2YcuIiwKIHRvb2xzVGl0bGU6Itij2K/ZiNin2Kog2LnZhdmE2YrYqSIsIHRvb2xzU3ViOiLZg9mE2YXYp9iqINmF2LHZiNixINin2YTZiNin2Yog2YHYp9mK2Iwg2KfZhNmF2YbYp9mB2LAg2KfZhNmF2LTYutmI2YTYqdiMINmI2YbZgti32Kkg2KfYs9iq2LnYp9iv2KkuIiwKIHdpZmk6ItmD2YTZhdin2Kog2YXYsdmI2LEg2KfZhNmI2KfZiiDZgdin2YoiLCBwb3J0czoi2KfZhNmF2YbYp9mB2LAg2KfZhNmF2YHYqtmI2K3YqSIsIHJlc3RvcmU6Itil2YbYtNin2KEg2YbZgti32Kkg2KfYs9iq2LnYp9iv2KkiLCBnb2Q6ItmB2KrYrSBHb2QgTW9kZSIsCiBhYm91dFRpdGxlOiLYrdmI2YQgUmFmaXEiLCBhYm91dEJvZHk6IlJhZmlxINij2K/Yp9ipINmF2YHYqtmI2K3YqSDYp9mE2YXYtdiv2LEg2YTYpdi12YTYp9itINij2LTZh9ixINmF2LTYp9mD2YQg2YjZitmG2K/ZiNiyIDEwINmIIDExINio2K/ZiNmGINmF2YbYuNmB2KfYqiDYsdmK2KzYs9iq2LHZiiDZiNmH2YXZitipLiDZg9mEINij2YXYsSDZiNin2LbYrSDZiNmK2YXZg9mGINin2YTYqtix2KfYrNi5INi52YYg2KPYutmE2KjZhyDZhdmGINin2YTYpdi52K/Yp9iv2KfYqi4iLAogZGVtbzoi2YjYtti5INin2YTYudix2LYiLCBsaXZlOiLZiNi22Lkg2KfZhNis2YfYp9iyIiwgYWRtaW46Iti12YTYp9it2YrYp9iqINmF2LPYpNmI2YQiLCB1c2VyOiLYqNiv2YjZhiDZhdiz2KTZiNmEIiwKIHJ1bjoi2KrZhtmB2YrYsCIsIG9rOiLYqtmFIiwgZmFpbDoi2YHYtNmEIiwgbmVlZEFkbWluOiLZh9iw2Kcg2KfZhNil2KzYsdin2KEg2YrYrdiq2KfYrCDYqti02LrZitmEINin2YTYqNix2YbYp9mF2Kwg2YPZhdiz2KTZiNmELiIsCiBjb25maXJtQ2xlYW46Itit2LDZgSDYp9mE2YXZhNmB2KfYqiDYp9mE2YXYrdiv2K/YqdifINmE2Kcg2YrYtNmF2YQg2YXYs9iq2YbYr9in2KrZgy4iLAp9LAplbjp7CiB0YWdsaW5lOiJZb3VyIGNvbXBhbmlvbiBmb3IgV2luZG93cyAxMCBhbmQgMTEgcmVwYWlycyIsCiBuYXY6e2Rhc2g6IkRhc2hib2FyZCIsbmV0OiJOZXR3b3JrIGRvY3RvciIsc3RvcmFnZToiU3RvcmFnZSBjbGVhbnVwIixwcml2YWN5OiJQcml2YWN5Iix0d2Vha3M6IldpbmRvd3MgdHdlYWtzIixyZXBhaXI6IlF1aWNrIHJlcGFpciIsc3RhcnR1cDoiU3RhcnR1cCBhcHBzIix0b29sczoiVG9vbGJveCIsYWJvdXQ6IkFib3V0In0sCiBkYXNoOiJEYXNoYm9hcmQiLCBkYXNoU3ViOiJIZWFsdGgsIGRpc2ssIG1lbW9yeSBhbmQgbmV0d29yayDigJQgd2l0aG91dCBodW50aW5nIHRocm91Z2ggU2V0dGluZ3MuIiwKIGhlYWx0aDoiSGVhbHRoIHNjb3JlIiwgb3M6IldpbmRvd3MiLCByYW06Ik1lbW9yeSIsIGRpc2s6IkRyaXZlIEM6IiwgdXB0aW1lOiJVcHRpbWUiLCBuZXQ6Ik5ldHdvcmsiLAogcXVpY2s6IlF1aWNrIGFjdGlvbnMiLCBmbHVzaDoiRmx1c2ggRE5TIiwgY2xlYW46IkNsZWFuIHRlbXAgZmlsZXMiLCBleHBsb3JlcjoiUmVzdGFydCBFeHBsb3JlciIsCiBpc3N1ZXM6IkFsZXJ0cyIsIG5vSXNzdWVzOiJObyBvYnZpb3VzIHByb2JsZW1zLiIsCiBuZXRUaXRsZToiTmV0d29yayBkb2N0b3IiLCBuZXRTdWI6IlRoZSAjMSBob21lLXN1cHBvcnQgdGlja2V0OiBXaS1GaSBpcyBjb25uZWN0ZWQgYnV0IHdlYnNpdGVzIHdpbGwgbm90IGxvYWQuIiwKIGRpYWdub3NlOiJSdW4gZGlhZ25vc2lzIiwgZG5zRmx1c2g6IkZsdXNoIEROUyIsIHJlbmV3OiJSZW5ldyBJUCIsIHdpbnNvY2s6IlJlc2V0IFdpbnNvY2siLCBpcHJlc2V0OiJSZXNldCBUQ1AvSVAiLAogZG5zOiJETlMgc2VydmVyIiwgY2xvdWRmbGFyZToiQ2xvdWRmbGFyZSAxLjEuMS4xIiwgZ29vZ2xlOiJHb29nbGUgOC44LjguOCIsIGFkZ3VhcmQ6IkFkR3VhcmQiLCBxdWFkOToiUXVhZDkiLCBkaGNwOiJBdXRvbWF0aWMgKERIQ1ApIiwKIGFkYXB0ZXJzOiJBZGFwdGVycyIsIHRlc3RzOiJUZXN0IHJlc3VsdHMiLAogc3RUaXRsZToiU2FmZSBzdG9yYWdlIGNsZWFudXAiLCBzdFN1YjoiV2Ugc2hvdyBzaXplcyBmaXJzdC4gTm8gcGVyc29uYWwgZmlsZXMuIE5vIGp1bmsgcmVnaXN0cnkgY2xlYW5lci4iLAogc2NhbjoiU2NhbiBub3ciLCBjbGVhblNlbDoiRGVsZXRlIHNlbGVjdGVkIiwgcmVjeWNsZToiUmVjeWNsZSBiaW4iLCB0ZW1wOiJUZW1wb3JhcnkgZmlsZXMiLCB1cGRhdGVzOiJXaW5kb3dzIFVwZGF0ZSBjYWNoZSIsIGRvOiJEZWxpdmVyeSBPcHRpbWl6YXRpb24iLCB0aHVtYnM6IlRodW1ibmFpbCBjYWNoZSIsIGR1bXBzOiJDcmFzaCBkdW1wcyIsCiBwclRpdGxlOiJQcml2YWN5IHNoaWVsZCIsIHByU3ViOiJXaW5kb3dzIDExIHF1aWV0bHkgYWRkcyBhZHMsIHN1Z2dlc3Rpb25zIGFuZCBDb3BpbG90IGluIHBsYWNlcyB5b3UgZGlkIG5vdCBhc2sgZm9yLiIsCiBhcHBseVByaXY6IkFwcGx5IHByb3RlY3Rpb24iLAogdHdUaXRsZToiV2luZG93cyB0d2Vha3MiLCB0d1N1YjoiQnJpbmcgYmFjayB0aGUgY2xhc3NpYyByaWdodC1jbGljayBtZW51IGFuZCBoaWRlIHRoZSBub2lzZS4iLAogcnBUaXRsZToiUXVpY2sgcmVwYWlyIiwgcnBTdWI6IlRoZSBzZXJ2aWNlcyB0aGF0IGZyZWV6ZSBpbiByZWFsIGxpZmU6IGF1ZGlvLCBwcmludGVyLCBzZWFyY2gsIFN0b3JlLiIsCiBzdVRpdGxlOiJTdGFydHVwIGFwcHMiLCBzdVN1YjoiRXZlcnl0aGluZyB0aGF0IGxhdW5jaGVzIHdpdGggV2luZG93cyBzbG93cyB0aGUgZmlyc3QgbWludXRlcyBvZiB5b3VyIGRheS4iLAogdG9vbHNUaXRsZToiVG9vbGJveCIsIHRvb2xzU3ViOiJTYXZlZCBXaS1GaSBwYXNzd29yZHMsIGxpc3RlbmluZyBwb3J0cywgcmVzdG9yZSBwb2ludC4iLAogd2lmaToiV2ktRmkgcGFzc3dvcmRzIiwgcG9ydHM6Ikxpc3RlbmluZyBwb3J0cyIsIHJlc3RvcmU6IkNyZWF0ZSByZXN0b3JlIHBvaW50IiwgZ29kOiJPcGVuIEdvZCBNb2RlIiwKIGFib3V0VGl0bGU6IkFib3V0IFJhZmlxIiwgYWJvdXRCb2R5OiJSYWZpcSBpcyBhbiBvcGVuLXNvdXJjZSBjb21wYW5pb24gZm9yIHRoZSBXaW5kb3dzIDEwLzExIHByb2JsZW1zIHBlb3BsZSBhY3R1YWxseSBoaXQuIEV2ZXJ5IGFjdGlvbiBpcyBleHBsaWNpdC4gVGhlcmUgaXMgbm8gZmFrZSByZWdpc3RyeSBtYWdpYy4iLAogZGVtbzoiRGVtbyBtb2RlIiwgbGl2ZToiTGl2ZSBQQyIsIGFkbWluOiJBZG1pbmlzdHJhdG9yIiwgdXNlcjoiU3RhbmRhcmQgdXNlciIsCiBydW46IlJ1biIsIG9rOiJEb25lIiwgZmFpbDoiRmFpbGVkIiwgbmVlZEFkbWluOiJUaGlzIGFjdGlvbiBuZWVkcyBSYWZpcSB0byBydW4gYXMgQWRtaW5pc3RyYXRvci4iLAogY29uZmlybUNsZWFuOiJEZWxldGUgdGhlIHNlbGVjdGVkIGp1bmsgZmlsZXM/IERvY3VtZW50cyBhcmUgbmV2ZXIgdG91Y2hlZC4iLAp9fTsKCmNvbnN0IG5hdGl2ZSA9IGxvY2F0aW9uLmhvc3RuYW1lPT09IjEyNy4wLjAuMSIgfHwgbG9jYXRpb24uaG9zdG5hbWU9PT0ibG9jYWxob3N0IjsKbGV0IGxhbmcgPSBsb2NhbFN0b3JhZ2UuZ2V0SXRlbSgicmFmaXEtbGFuZyIpIHx8ICgobmF2aWdhdG9yLmxhbmd1YWdlfHwiIikudG9Mb3dlckNhc2UoKS5zdGFydHNXaXRoKCJhciIpPyJhciI6ImVuIik7CmxldCBTID0ge29rOmZhbHNlLCBkZW1vOnRydWUsIGFkbWluOmZhbHNlLCBpbmZvOm51bGx9OwoKY29uc3QgSUNPTlMgPSB7CmRhc2g6YDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxyZWN0IHg9IjMiIHk9IjMiIHdpZHRoPSI3IiBoZWlnaHQ9IjkiIHJ4PSIxLjUiLz48cmVjdCB4PSIxNCIgeT0iMyIgd2lkdGg9IjciIGhlaWdodD0iNSIgcng9IjEuNSIvPjxyZWN0IHg9IjE0IiB5PSIxMiIgd2lkdGg9IjciIGhlaWdodD0iOSIgcng9IjEuNSIvPjxyZWN0IHg9IjMiIHk9IjE2IiB3aWR0aD0iNyIgaGVpZ2h0PSI1IiByeD0iMS41Ii8+PC9zdmc+YCwKbmV0OmA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI5Ii8+PHBhdGggZD0iTTMgMTJoMThNMTIgM2ExNSAxNSAwIDAxMCAxOE0xMiAzYTE1IDE1IDAgMDAwIDE4Ii8+PC9zdmc+YCwKc3RvcmFnZTpgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PGVsbGlwc2UgY3g9IjEyIiBjeT0iNiIgcng9IjgiIHJ5PSIzIi8+PHBhdGggZD0iTTQgNnY2YzAgMS43IDMuNiAzIDggM3M4LTEuMyA4LTNWNk00IDEydjZjMCAxLjcgMy42IDMgOCAzczgtMS4zIDgtM3YtNiIvPjwvc3ZnPmAsCnByaXZhY3k6YDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0xMiAzbDggM3Y2YzAgNS0zLjQgOC40LTggOS00LjYtLjYtOC00LTgtOVY2bDgtM3oiLz48L3N2Zz5gLAp0d2Vha3M6YDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjMiLz48cGF0aCBkPSJNMTIgM3YyTTEyIDE5djJNNSAxMkgzTTIxIDEyaC0yTTYgNmwxLjUgMS41TTE2LjUgMTYuNUwxOCAxOE0xOCA2bC0xLjUgMS41TTcuNSAxNi41TDYgMTgiLz48L3N2Zz5gLApyZXBhaXI6YDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0xNC43IDYuM2E1IDUgMCAwMC03IDdMNCAxN2wzIDMgMy43LTMuN2E1IDUgMCAwMDctN0wxNiA4bC0xLjMtMS43eiIvPjwvc3ZnPmAsCnN0YXJ0dXA6YDxzdmcgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIxLjgiPjxwYXRoIGQ9Ik0xMyAyTDQgMTRoN2wtMSA4IDEwLTEyaC03bDAtOHoiLz48L3N2Zz5gLAp0b29sczpgPHN2ZyB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjEuOCI+PHBhdGggZD0iTTQgMjF2LTRsMTAtMTAgNCA0TDggMjFINHpNMTQgN2wzLTMgNCA0LTMgMyIvPjwvc3ZnPmAsCmFib3V0OmA8c3ZnIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMS44Ij48Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI5Ii8+PHBhdGggZD0iTTEyIDEwdjZNMTIgN2guMDEiLz48L3N2Zz5gCn07Cgpjb25zdCBQQUdFUyA9IFsiZGFzaCIsIm5ldCIsInN0b3JhZ2UiLCJwcml2YWN5IiwidHdlYWtzIiwicmVwYWlyIiwic3RhcnR1cCIsInRvb2xzIiwiYWJvdXQiXTsKbGV0IHBhZ2UgPSAiZGFzaCI7CgpmdW5jdGlvbiB0KGspe2NvbnN0IHA9ay5zcGxpdCgiLiIpOyBsZXQgbz1UW2xhbmddOyBmb3IoY29uc3QgeCBvZiBwKSBvPW9beF07IHJldHVybiBvO30KZnVuY3Rpb24gJChpZCl7cmV0dXJuIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKX0KZnVuY3Rpb24gdG9hc3QobXNnKXtjb25zdCBlPSQoInRvYXN0Iik7IGUudGV4dENvbnRlbnQ9bXNnOyBlLnN0eWxlLmRpc3BsYXk9ImJsb2NrIjsgc2V0VGltZW91dCgoKT0+ZS5zdHlsZS5kaXNwbGF5PSJub25lIiwzMjAwKX0KYXN5bmMgZnVuY3Rpb24gYXBpKHBhdGgsIGJvZHkpewogIGlmKCFuYXRpdmUpIHJldHVybiBkZW1vQXBpKHBhdGgsIGJvZHkpOwogIGNvbnN0IG9wdCA9IGJvZHk9PW51bGw/e306e21ldGhvZDoiUE9TVCIsIGhlYWRlcnM6eyJDb250ZW50LVR5cGUiOiJhcHBsaWNhdGlvbi9qc29uIn0sIGJvZHk6SlNPTi5zdHJpbmdpZnkoYm9keSl9OwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChwYXRoLCBvcHQpOwogIHJldHVybiBhd2FpdCByLmpzb24oKTsKfQpmdW5jdGlvbiBkZW1vQXBpKHBhdGgsIGJvZHkpewogIHJldHVybiBuZXcgUHJvbWlzZShyZXM9PnNldFRpbWVvdXQoKCk9PnsKICAgIGNvbnN0IGFjdCA9IGJvZHkgJiYgYm9keS5hY3Rpb247CiAgICBpZihwYXRoPT09Ii9hcGkvaGVhbHRoIiB8fCBwYXRoPT09Ii9hcGkvaW5mbyIpewogICAgICByZXMoe29rOnRydWUsIGRlbW86dHJ1ZSwgYWRtaW46ZmFsc2UsIG9zOiJXaW5kb3dzIDExIDIzSDIgKGRlbW8pIiwgYnVpbGQ6IjIyNjMxIiwgY29tcHV0ZXI6IkRFU0tUT1AtUkFGSVEiLAogICAgICAgIHJhbVRvdGFsOjE2KjEwNzM3NDE4MjQsIHJhbUZyZWU6NS4yKjEwNzM3NDE4MjQsIGRpc2tUb3RhbDo1MTIqMTA3Mzc0MTgyNCwgZGlza0ZyZWU6ODQqMTA3Mzc0MTgyNCwKICAgICAgICB1cHRpbWU6IDkzNjAwLCBjcHU6IkludGVsIENvcmUgaTciLCBuZXRVcDp0cnVlLCBkbnNPazp0cnVlLCBwaW5nT2s6dHJ1ZSwKICAgICAgICBhZGFwdGVyczpbe25hbWU6IldpLUZpIiwgc3RhdHVzOiJVcCIsIGlwdjQ6IjE5Mi4xNjguMS4xNCIsIGRuczpbIjEuMS4xLjEiLCIxLjAuMC4xIl19XSwKICAgICAgICBwdWJsaWNIaW50OiJoaWRkZW4gaW4gZGVtbyJ9KTsKICAgICAgcmV0dXJuOwogICAgfQogICAgaWYocGF0aD09PSIvYXBpL3NjYW4iKXsKICAgICAgcmVzKHtvazp0cnVlLCBpdGVtczpbCiAgICAgICAge2lkOiJ0ZW1wIiwgbGFiZWw6dCgidGVtcCIpLCBieXRlczoxNDAwKjEwNDg1NzYsIHNhZmU6dHJ1ZX0sCiAgICAgICAge2lkOiJyZWN5Y2xlIiwgbGFiZWw6dCgicmVjeWNsZSIpLCBieXRlczo0MjAqMTA0ODU3Niwgc2FmZTp0cnVlfSwKICAgICAgICB7aWQ6InVwZGF0ZXMiLCBsYWJlbDp0KCJ1cGRhdGVzIiksIGJ5dGVzOjMxMDAqMTA0ODU3Niwgc2FmZTp0cnVlfSwKICAgICAgICB7aWQ6ImRvIiwgbGFiZWw6dCgiZG8iKSwgYnl0ZXM6ODYwKjEwNDg1NzYsIHNhZmU6dHJ1ZX0sCiAgICAgICAge2lkOiJ0aHVtYnMiLCBsYWJlbDp0KCJ0aHVtYnMiKSwgYnl0ZXM6MTkwKjEwNDg1NzYsIHNhZmU6dHJ1ZX0sCiAgICAgICAge2lkOiJkdW1wcyIsIGxhYmVsOnQoImR1bXBzIiksIGJ5dGVzOjc1KjEwNDg1NzYsIHNhZmU6dHJ1ZX0KICAgICAgXX0pOyByZXR1cm47CiAgICB9CiAgICBpZihwYXRoPT09Ii9hcGkvc3RhcnR1cCIpewogICAgICByZXMoe29rOnRydWUsIGl0ZW1zOlsKICAgICAgICB7bmFtZToiT25lRHJpdmUiLCBsb2M6IkhLQ1UgUnVuIiwgZW5hYmxlZDp0cnVlfSwKICAgICAgICB7bmFtZToiTWljcm9zb2Z0IFRlYW1zIiwgbG9jOiJIS0NVIFJ1biIsIGVuYWJsZWQ6dHJ1ZX0sCiAgICAgICAge25hbWU6IkFkb2JlIFVwZGF0ZXIiLCBsb2M6IkhLTE0gUnVuIiwgZW5hYmxlZDp0cnVlfSwKICAgICAgICB7bmFtZToiU3BvdGlmeSIsIGxvYzoiSEtDVSBSdW4iLCBlbmFibGVkOmZhbHNlfQogICAgICBdfSk7IHJldHVybjsKICAgIH0KICAgIGlmKHBhdGg9PT0iL2FwaS93aWZpIil7CiAgICAgIHJlcyh7b2s6dHJ1ZSwgaXRlbXM6W3tzc2lkOiJIb21lLUZpYmVyIiwga2V5OiLigKLigKLigKLigKLigKLigKLigKLigKIifSx7c3NpZDoiT2ZmaWNlLUd1ZXN0Iiwga2V5OiLigKLigKLigKLigKIifV19KTsgcmV0dXJuOwogICAgfQogICAgaWYocGF0aD09PSIvYXBpL3BvcnRzIil7CiAgICAgIHJlcyh7b2s6dHJ1ZSwgaXRlbXM6W3twb3J0OjQ0MywgcHJvdG86IlRDUCIsIHBpZDoxMjMyLCBuYW1lOiJzdmNob3N0In0se3BvcnQ6MzAwMCwgcHJvdG86IlRDUCIsIHBpZDo0NDEyLCBuYW1lOiJub2RlIn0se3BvcnQ6NTM1NywgcHJvdG86IlRDUCIsIHBpZDo0LCBuYW1lOiJTeXN0ZW0ifV19KTsgcmV0dXJuOwogICAgfQogICAgaWYocGF0aD09PSIvYXBpL3R3ZWFrcyIpewogICAgICByZXMoe29rOnRydWUsIHR3ZWFrczogZGVmYXVsdFR3ZWFrcygpLm1hcCh4PT4oey4uLngsIG9uOiBbImNsYXNzaWNNZW51IiwiZmlsZUV4dCIsImFkc0xvY2siLCJjb3BpbG90Il0uaW5jbHVkZXMoeC5pZCk/ZmFsc2U6eC5pZD09PSJ0YXNrYmFyTGVmdCJ9KSl9KTsgcmV0dXJuOwogICAgfQogICAgaWYocGF0aD09PSIvYXBpL2FjdGlvbiIpewogICAgICByZXMoe29rOnRydWUsIG1lc3NhZ2U6IGxhbmc9PT0iYXIiPyLYqtmFINmB2Yog2YjYtti5INin2YTYudix2LYg2YHZgti3IjoiRGVtbyBvbmx5IOKAlCBub3RoaW5nIGNoYW5nZWQgb24gdGhpcyBkZXZpY2UuIiwgZGVtbzp0cnVlfSk7IHJldHVybjsKICAgIH0KICAgIHJlcyh7b2s6dHJ1ZSwgZGVtbzp0cnVlfSk7CiAgfSwgMjgwKSk7Cn0KZnVuY3Rpb24gZm10Qnl0ZXMobil7aWYobj09bnVsbCkgcmV0dXJuICLigJQiOyBjb25zdCB1PVsiQiIsIktCIiwiTUIiLCJHQiIsIlRCIl07IGxldCBpPTAsdj1uOyB3aGlsZSh2Pj0xMDI0JiZpPHUubGVuZ3RoLTEpe3YvPTEwMjQ7aSsrfSByZXR1cm4gdi50b0ZpeGVkKHY+PTEwfHxpPT09MD8wOjEpKyIgIit1W2ldfQpmdW5jdGlvbiBmbXRVcChzKXtzPU1hdGguZmxvb3Ioc3x8MCk7IGNvbnN0IGQ9TWF0aC5mbG9vcihzLzg2NDAwKSwgaD1NYXRoLmZsb29yKChzJTg2NDAwKS8zNjAwKSwgbT1NYXRoLmZsb29yKChzJTM2MDApLzYwKTsgcmV0dXJuIChkP2QrKGxhbmc9PT0iYXIiPyLZiiAiOiJkICIpOiIiKStoKyhsYW5nPT09ImFyIj8i2LMgIjoiaCAiKSttKyhsYW5nPT09ImFyIj8i2K8iOiJtIil9CmZ1bmN0aW9uIHBjdCh1c2VkLHRvdGFsKXtpZighdG90YWwpIHJldHVybiAwOyByZXR1cm4gTWF0aC5taW4oMTAwLCBNYXRoLnJvdW5kKHVzZWQqMTAwL3RvdGFsKSl9CgpmdW5jdGlvbiBkZWZhdWx0VHdlYWtzKCl7CiAgcmV0dXJuIFsKICAgIHtpZDoiY2xhc3NpY01lbnUiLCBhcjoi2YLYp9im2YXYqSDYp9mE2YbZgtixINin2YTZitmF2YrZhtmKINin2YTZg9mE2KfYs9mK2YPZitipICjZiNmK2YbYr9mI2LIgMTEpIiwgZW46IkNsYXNzaWMgcmlnaHQtY2xpY2sgbWVudSAoV2luZG93cyAxMSkifSwKICAgIHtpZDoidGFza2JhckxlZnQiLCBhcjoi2LTYsdmK2Lcg2KfZhNmF2YfYp9mFINi52YTZiSDYp9mE2YrYs9in2LEiLCBlbjoiTGVmdC1hbGlnbiB0aGUgdGFza2JhciJ9LAogICAge2lkOiJmaWxlRXh0IiwgYXI6Itil2LjZh9in2LEg2KfZhdiq2K/Yp9iv2KfYqiDYp9mE2YXZhNmB2KfYqiIsIGVuOiJTaG93IGZpbGUgZXh0ZW5zaW9ucyJ9LAogICAge2lkOiJoaWRkZW5GaWxlcyIsIGFyOiLYpdi42YfYp9ixINin2YTZhdmE2YHYp9iqINin2YTZhdiu2YHZitipIiwgZW46IlNob3cgaGlkZGVuIGZpbGVzIn0sCiAgICB7aWQ6ImNvcGlsb3QiLCBhcjoi2KXYrtmB2KfYoSDYstixIENvcGlsb3QiLCBlbjoiSGlkZSBDb3BpbG90IGJ1dHRvbiJ9LAogICAge2lkOiJ3aWRnZXRzIiwgYXI6Itil2K7Zgdin2KEg2KfZhNij2K/ZiNin2KogKFdpZGdldHMpIiwgZW46IkhpZGUgV2lkZ2V0cyJ9LAogICAge2lkOiJhZHNMb2NrIiwgYXI6Itil2YrZgtin2YEg2KXYudmE2KfZhtin2Kog2LTYp9i02Kkg2KfZhNmC2YHZhCIsIGVuOiJEaXNhYmxlIGxvY2stc2NyZWVuIGFkcyJ9LAogICAge2lkOiJhZHNTdGFydCIsIGFyOiLYpdmK2YLYp9mBINin2YLYqtix2KfYrdin2Kog2YLYp9im2YXYqSDYp9io2K/YoyIsIGVuOiJEaXNhYmxlIFN0YXJ0IHN1Z2dlc3Rpb25zIn0sCiAgICB7aWQ6ImFkc1NldHRpbmdzIiwgYXI6Itil2YrZgtin2YEg2KfZhNin2YLYqtix2KfYrdin2Kog2YHZiiDYp9mE2KXYudiv2KfYr9in2KoiLCBlbjoiRGlzYWJsZSBTZXR0aW5ncyBzdWdnZXN0aW9ucyJ9LAogICAge2lkOiJ0YWlsb3JlZCIsIGFyOiLYpdmK2YLYp9mBINin2YTYqtis2KfYsdioINin2YTZhdiu2LXYtdipIiwgZW46IkRpc2FibGUgdGFpbG9yZWQgZXhwZXJpZW5jZXMifSwKICAgIHtpZDoiYWRJZCIsIGFyOiLYpdmK2YLYp9mBINmF2LnYsdmR2YEg2KfZhNil2LnZhNin2YbYp9iqIiwgZW46IkRpc2FibGUgYWR2ZXJ0aXNpbmcgSUQifSwKICAgIHtpZDoic2VhcmNoQmluZyIsIGFyOiLYpdmK2YLYp9mBINmG2KrYp9im2KwgQmluZyDZgdmKINin2YTYqNit2KsiLCBlbjoiRGlzYWJsZSBCaW5nIGluIFN0YXJ0IHNlYXJjaCJ9LAogICAge2lkOiJmYXN0U3RhcnR1cCIsIGFyOiLYpdmK2YLYp9mBINin2YTYpdmC2YTYp9i5INin2YTYs9ix2YrYuSIsIGVuOiJEaXNhYmxlIEZhc3QgU3RhcnR1cCJ9LAogICAge2lkOiJlbmRUYXNrIiwgYXI6Itil2YbZh9in2KEg2KfZhNmF2YfZhdipINmF2YYg2LTYsdmK2Lcg2KfZhNmF2YfYp9mFIiwgZW46IkVuZCB0YXNrIGZyb20gdGFza2JhciJ9LAogICAge2lkOiJjb21wYWN0IiwgYXI6Iti52LHYtiBFeHBsb3JlciDYp9mE2YXYr9mF2KwiLCBlbjoiQ29tcGFjdCBGaWxlIEV4cGxvcmVyIHZpZXcifQogIF07Cn0KZnVuY3Rpb24gZGVmYXVsdFJlcGFpcnMoKXsKICByZXR1cm4gWwogICAge2lkOiJleHBsb3JlciIsIGFyOiLYpdi52KfYr9ipINiq2LTYutmK2YQg2YXYs9iq2YPYtNmBINmI2YrZhtiv2YjYsiIsIGVuOiJSZXN0YXJ0IFdpbmRvd3MgRXhwbG9yZXIifSwKICAgIHtpZDoiYXVkaW8iLCBhcjoi2KXYudin2K/YqSDYqti02LrZitmEINiu2K/ZhdipINin2YTYtdmI2KoiLCBlbjoiUmVzdGFydCBXaW5kb3dzIEF1ZGlvIn0sCiAgICB7aWQ6InNwb29sZXIiLCBhcjoi2KXYtdmE2KfYrSBzcG9vbGVyINin2YTYt9in2KjYudipIiwgZW46IkZpeCBQcmludCBTcG9vbGVyIn0sCiAgICB7aWQ6InNlYXJjaCIsIGFyOiLYpdi52KfYr9ipINiq2LTYutmK2YQg2KjYrdirINmI2YrZhtiv2YjYsiIsIGVuOiJSZXN0YXJ0IFdpbmRvd3MgU2VhcmNoIn0sCiAgICB7aWQ6Imljb25zIiwgYXI6Itil2LnYp9iv2Kkg2KjZhtin2KEg2LDYp9mD2LHYqSDYp9mE2KPZitmC2YjZhtin2KoiLCBlbjoiUmVidWlsZCBpY29uIGNhY2hlIn0sCiAgICB7aWQ6InRodW1icyIsIGFyOiLZhdiz2K0g2LDYp9mD2LHYqSDYp9mE2LXZiNixINin2YTZhdi12LrYsdipIiwgZW46IkNsZWFyIHRodW1ibmFpbCBjYWNoZSJ9LAogICAge2lkOiJ3c3Jlc2V0IiwgYXI6Itil2LnYp9iv2Kkg2LbYqNi3INmF2KrYrNixIE1pY3Jvc29mdCIsIGVuOiJSZXNldCBNaWNyb3NvZnQgU3RvcmUifSwKICAgIHtpZDoiZmx1c2hkbnMiLCBhcjoi2KrZgdix2YrYuiBETlMiLCBlbjoiRmx1c2ggRE5TIn0KICBdOwp9CgpmdW5jdGlvbiBhcHBseUNocm9tZSgpewogIGRvY3VtZW50LmRvY3VtZW50RWxlbWVudC5sYW5nID0gbGFuZzsKICBkb2N1bWVudC5kb2N1bWVudEVsZW1lbnQuZGlyID0gbGFuZz09PSJhciI/InJ0bCI6Imx0ciI7CiAgJCgidGFnbGluZSIpLnRleHRDb250ZW50ID0gdCgidGFnbGluZSIpOwogICQoImJ0bkFyIikuY2xhc3NMaXN0LnRvZ2dsZSgib24iLCBsYW5nPT09ImFyIik7CiAgJCgiYnRuRW4iKS5jbGFzc0xpc3QudG9nZ2xlKCJvbiIsIGxhbmc9PT0iZW4iKTsKICAkKCJtb2RlQmFkZ2UiKS50ZXh0Q29udGVudCA9ICghbmF0aXZlfHxTLmRlbW8pP3QoImRlbW8iKTp0KCJsaXZlIik7CiAgJCgibW9kZUJhZGdlIikuY2xhc3NOYW1lID0gImJhZGdlICIrKCghbmF0aXZlfHxTLmRlbW8pPyJkZW1vIjoiIik7CiAgJCgiYWRtaW5CYWRnZSIpLnRleHRDb250ZW50ID0gUy5hZG1pbj90KCJhZG1pbiIpOnQoInVzZXIiKTsKICAkKCJhZG1pbkJhZGdlIikuY2xhc3NOYW1lID0gImJhZGdlICIrKFMuYWRtaW4/ImFkbWluIjoiIik7CiAgJCgibmF2IikuaW5uZXJIVE1MID0gUEFHRVMubWFwKHA9PmA8YnV0dG9uIGRhdGEtcD0iJHtwfSIgY2xhc3M9IiR7cD09PXBhZ2U/ImFjdGl2ZSI6IiJ9Ij4ke0lDT05TW3BdfHwiIn08c3Bhbj4ke3QoIm5hdi4iK3ApfTwvc3Bhbj48L2J1dHRvbj5gKS5qb2luKCIiKTsKICBbLi4uJCgibmF2IikucXVlcnlTZWxlY3RvckFsbCgiYnV0dG9uIildLmZvckVhY2goYj0+Yi5vbmNsaWNrPSgpPT57cGFnZT1iLmRhdGFzZXQucDsgcmVuZGVyKCl9KTsKfQoKZnVuY3Rpb24gc2NvcmVPZihpbmZvKXsKICBpZighaW5mbykgcmV0dXJuIDcwOwogIGxldCBzPTEwMDsKICBjb25zdCBkaXNrUGN0ID0gcGN0KChpbmZvLmRpc2tUb3RhbC1pbmZvLmRpc2tGcmVlKSwgaW5mby5kaXNrVG90YWwpOwogIGlmKGRpc2tQY3Q+OTIpIHMtPTIwOyBlbHNlIGlmKGRpc2tQY3Q+ODApIHMtPTEwOwogIGNvbnN0IHJhbVBjdCA9IHBjdCgoaW5mby5yYW1Ub3RhbC1pbmZvLnJhbUZyZWUpLCBpbmZvLnJhbVRvdGFsKTsKICBpZihyYW1QY3Q+OTApIHMtPTEwOwogIGlmKGluZm8ubmV0VXA9PT1mYWxzZSkgcy09MjU7CiAgaWYoaW5mby5kbnNPaz09PWZhbHNlKSBzLT0xNTsKICByZXR1cm4gTWF0aC5tYXgoMjAscyk7Cn0KCmZ1bmN0aW9uIHJlbmRlckRhc2goKXsKICBjb25zdCBpPVMuaW5mb3x8e307CiAgY29uc3Qgc2M9c2NvcmVPZihpKTsKICBjb25zdCBkaXNrUGN0PXBjdCgoaS5kaXNrVG90YWwtaS5kaXNrRnJlZSksIGkuZGlza1RvdGFsKTsKICBjb25zdCByYW1QY3Q9cGN0KChpLnJhbVRvdGFsLWkucmFtRnJlZSksIGkucmFtVG90YWwpOwogIGNvbnN0IGlzc3Vlcz1bXTsKICBpZihkaXNrUGN0Pjg1KSBpc3N1ZXMucHVzaChsYW5nPT09ImFyIj8i2KfZhNmF2LPYp9it2Kkg2LnZhNmJINin2YTZgtix2LUg2YXZhtiu2YHYttipIOKAlCDYp9mB2KrYrSDYp9mE2KrZhti42YrZgS4iOiJMb3cgZGlzayBzcGFjZSDigJQgcnVuIFN0b3JhZ2UgY2xlYW51cC4iKTsKICBpZighaS5uZXRVcCkgaXNzdWVzLnB1c2gobGFuZz09PSJhciI/ItmE2Kcg2YrZiNis2K8g2KfYqti12KfZhCDYtNio2YPYqS4iOiJObyBuZXR3b3JrIGNvbm5lY3Rpb24uIik7CiAgaWYoaS5kbnNPaz09PWZhbHNlKSBpc3N1ZXMucHVzaChsYW5nPT09ImFyIj8iRE5TINmE2Kcg2YrYudmF2YQuINis2LHZkdioINin2YTYqtmB2LHZiti6INij2YggQ2xvdWRmbGFyZS4iOiJETlMgaXMgZmFpbGluZy4gVHJ5IGZsdXNoIG9yIENsb3VkZmxhcmUuIik7CiAgcmV0dXJuIGA8aDI+JHt0KCJkYXNoIil9PC9oMj48cCBjbGFzcz0ic3ViIj4ke3QoImRhc2hTdWIiKX08L3A+CiAgPGRpdiBjbGFzcz0iZ3JpZCI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIHNwYW42Ij48ZGl2IGNsYXNzPSJoZXJvLXNjb3JlIj4KICAgICAgPHN2ZyBjbGFzcz0icmluZyIgdmlld0JveD0iMCAwIDgwIDgwIj48Y2lyY2xlIGN4PSI0MCIgY3k9IjQwIiByPSIzMiIgc3Ryb2tlPSIjMWMyNzJlIiBzdHJva2Utd2lkdGg9IjgiIGZpbGw9Im5vbmUiLz4KICAgICAgPGNpcmNsZSBjeD0iNDAiIGN5PSI0MCIgcj0iMzIiIHN0cm9rZT0iIzFlYzhiMCIgc3Ryb2tlLXdpZHRoPSI4IiBmaWxsPSJub25lIiBzdHJva2UtbGluZWNhcD0icm91bmQiCiAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iJHtNYXRoLnJvdW5kKHNjLzEwMCoyMDEpfSAyMDEiIHRyYW5zZm9ybT0icm90YXRlKC05MCA0MCA0MCkiLz48L3N2Zz4KICAgICAgPGRpdj48ZGl2IGNsYXNzPSJrIj4ke3QoImhlYWx0aCIpfTwvZGl2PjxkaXYgY2xhc3M9InYiPiR7c2N9LzEwMDwvZGl2PjwvZGl2PgogICAgPC9kaXY+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIHNwYW42Ij48ZGl2IGNsYXNzPSJrIj4ke3QoIm9zIil9PC9kaXY+PGRpdiBjbGFzcz0idiIgc3R5bGU9ImZvbnQtc2l6ZToxOHB4Ij4ke2kub3N8fCLigJQifTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJrIiBzdHlsZT0ibWFyZ2luLXRvcDo4cHgiPiR7aS5jb21wdXRlcnx8IiJ9IMK3ICR7aS5jcHV8fCIifTwvZGl2PjwvZGl2PgogICAgPGRpdiBjbGFzcz0iY2FyZCBzcGFuNCI+PGRpdiBjbGFzcz0iayI+JHt0KCJyYW0iKX08L2Rpdj48ZGl2IGNsYXNzPSJ2Ij4ke2ZtdEJ5dGVzKGkucmFtRnJlZSl9IDxzcGFuIGNsYXNzPSJrIj4vICR7Zm10Qnl0ZXMoaS5yYW1Ub3RhbCl9PC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJiYXIiPjxpIHN0eWxlPSJ3aWR0aDoke3JhbVBjdH0lIj48L2k+PC9kaXY+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIHNwYW40Ij48ZGl2IGNsYXNzPSJrIj4ke3QoImRpc2siKX08L2Rpdj48ZGl2IGNsYXNzPSJ2Ij4ke2ZtdEJ5dGVzKGkuZGlza0ZyZWUpfSA8c3BhbiBjbGFzcz0iayI+LyAke2ZtdEJ5dGVzKGkuZGlza1RvdGFsKX08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJhciI+PGkgc3R5bGU9IndpZHRoOiR7ZGlza1BjdH0lO2JhY2tncm91bmQ6JHtkaXNrUGN0PjkwPyJ2YXIoLS1iYWQpIjoibGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjY2VudDIpLHZhcigtLWFjY2VudCkpIn0iPjwvaT48L2Rpdj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQgc3BhbjQiPjxkaXYgY2xhc3M9ImsiPiR7dCgidXB0aW1lIil9PC9kaXY+PGRpdiBjbGFzcz0idiI+JHtmbXRVcChpLnVwdGltZSl9PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImsiIHN0eWxlPSJtYXJnaW4tdG9wOjEwcHgiPiR7dCgibmV0Iil9OiAke2kubmV0VXA9PT1mYWxzZT8obGFuZz09PSJhciI/Iti62YrYsSDZhdiq2LXZhCI6IkRvd24iKToobGFuZz09PSJhciI/ItmF2KrYtdmEIjoiVXAiKX08L2Rpdj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQgc3BhbjEyIj48ZGl2IGNsYXNzPSJrIj4ke3QoInF1aWNrIil9PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFjdGlvbnMiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0biIgZGF0YS1hY3Q9ImZsdXNoZG5zIj4ke3QoImZsdXNoIil9PC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgZGF0YS1hY3Q9ImNsZWFuX3RlbXAiPiR7dCgiY2xlYW4iKX08L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBkYXRhLWFjdD0iZXhwbG9yZXIiPiR7dCgiZXhwbG9yZXIiKX08L2J1dHRvbj4KICAgICAgPC9kaXY+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIHNwYW4xMiI+PGRpdiBjbGFzcz0iayI+JHt0KCJpc3N1ZXMiKX08L2Rpdj4KICAgICAgJHtpc3N1ZXMubGVuZ3RoP2lzc3Vlcy5tYXAoeD0+YDxkaXYgY2xhc3M9Imlzc3VlIiBzdHlsZT0ibWFyZ2luLXRvcDo4cHgiPiR7eH08L2Rpdj5gKS5qb2luKCIiKTpgPGRpdiBjbGFzcz0iaXNzdWUgb2tpc2giIHN0eWxlPSJtYXJnaW4tdG9wOjhweCI+JHt0KCJub0lzc3VlcyIpfTwvZGl2PmB9CiAgICA8L2Rpdj4KICA8L2Rpdj5gOwp9CmZ1bmN0aW9uIHJlbmRlck5ldCgpewogIGNvbnN0IGFkcz0oUy5pbmZvJiZTLmluZm8uYWRhcHRlcnMpfHxbXTsKICByZXR1cm4gYDxoMj4ke3QoIm5ldFRpdGxlIil9PC9oMj48cCBjbGFzcz0ic3ViIj4ke3QoIm5ldFN1YiIpfTwvcD4KICA8ZGl2IGNsYXNzPSJncmlkIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQgc3BhbjEyIj48ZGl2IGNsYXNzPSJhY3Rpb25zIj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBkYXRhLWFjdD0iZGlhZ25vc2UiPiR7dCgiZGlhZ25vc2UiKX08L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgZGF0YS1hY3Q9ImZsdXNoZG5zIj4ke3QoImRuc0ZsdXNoIil9PC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIGRhdGEtYWN0PSJyZW5ldyI+JHt0KCJyZW5ldyIpfTwvYnV0dG9uPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBkYXRhLWFjdD0id2luc29jayI+JHt0KCJ3aW5zb2NrIil9PC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIGRhdGEtYWN0PSJpcHJlc2V0Ij4ke3QoImlwcmVzZXQiKX08L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPHAgY2xhc3M9ImsiIHN0eWxlPSJtYXJnaW4tdG9wOjE0cHgiPiR7dCgiZG5zIil9PC9wPgogICAgPGRpdiBjbGFzcz0iYWN0aW9ucyI+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIGRhdGEtYWN0PSJkbnNfY2xvdWRmbGFyZSI+JHt0KCJjbG91ZGZsYXJlIil9PC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIGRhdGEtYWN0PSJkbnNfZ29vZ2xlIj4ke3QoImdvb2dsZSIpfTwvYnV0dG9uPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBkYXRhLWFjdD0iZG5zX2FkZ3VhcmQiPiR7dCgiYWRndWFyZCIpfTwvYnV0dG9uPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBkYXRhLWFjdD0iZG5zX3F1YWQ5Ij4ke3QoInF1YWQ5Iil9PC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIGRhdGEtYWN0PSJkbnNfZGhjcCI+JHt0KCJkaGNwIil9PC9idXR0b24+CiAgICA8L2Rpdj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQgc3BhbjEyIj48ZGl2IGNsYXNzPSJrIj4ke3QoImFkYXB0ZXJzIil9PC9kaXY+CiAgICAgICR7YWRzLm1hcChhPT5gPGRpdiBjbGFzcz0iaXRlbSIgc3R5bGU9Im1hcmdpbi10b3A6OHB4Ij48ZGl2PjxiPiR7YS5uYW1lfTwvYj48ZGl2IGNsYXNzPSJrIj4ke2Euc3RhdHVzfHwiIn0gwrcgJHthLmlwdjR8fCIifTwvZGl2PjwvZGl2PjxkaXYgY2xhc3M9ImsiPiR7KGEuZG5zfHxbXSkuam9pbigiIMK3ICIpfTwvZGl2PjwvZGl2PmApLmpvaW4oIiIpfHxgPHAgY2xhc3M9ImsiPiR7bGFuZz09PSJhciI/ItmE2Kcg2KjZitin2YbYp9iqIjoiTm8gYWRhcHRlciBkYXRhIn08L3A+YH0KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iY2FyZCBzcGFuMTIiPjxkaXYgY2xhc3M9ImsiPiR7dCgidGVzdHMiKX08L2Rpdj48ZGl2IGNsYXNzPSJsb2ciIGlkPSJuZXRsb2ciPiR7bGFuZz09PSJhciI/Itin2LbYuti3INiq2LTYrtmK2LUg2KfZhNii2YYuIjoiUnVuIGRpYWdub3NpcyB0byB0ZXN0IHBpbmcgYW5kIEROUy4ifTwvZGl2PjwvZGl2PgogIDwvZGl2PmA7Cn0KZnVuY3Rpb24gcmVuZGVyU3RvcmFnZSgpewogIHJldHVybiBgPGgyPiR7dCgic3RUaXRsZSIpfTwvaDI+PHAgY2xhc3M9InN1YiI+JHt0KCJzdFN1YiIpfTwvcD4KICA8ZGl2IGNsYXNzPSJjYXJkIHNwYW4xMiI+PGRpdiBjbGFzcz0iYWN0aW9ucyI+CiAgICA8YnV0dG9uIGNsYXNzPSJidG4iIGlkPSJzY2FuQnRuIj4ke3QoInNjYW4iKX08L2J1dHRvbj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biB3YXJuIiBpZD0iY2xlYW5CdG4iPiR7dCgiY2xlYW5TZWwiKX08L2J1dHRvbj4KICA8L2Rpdj48ZGl2IGNsYXNzPSJsaXN0IiBpZD0ic2Nhbkxpc3QiIHN0eWxlPSJtYXJnaW4tdG9wOjE0cHgiPjwvZGl2PjwvZGl2PmA7Cn0KZnVuY3Rpb24gcmVuZGVyUHJpdmFjeSgpewogIGNvbnN0IGtleXM9WyJhZHNMb2NrIiwiYWRzU3RhcnQiLCJhZHNTZXR0aW5ncyIsInRhaWxvcmVkIiwiYWRJZCIsImNvcGlsb3QiLCJ3aWRnZXRzIiwic2VhcmNoQmluZyJdOwogIGNvbnN0IHR3PWRlZmF1bHRUd2Vha3MoKS5maWx0ZXIoeD0+a2V5cy5pbmNsdWRlcyh4LmlkKSk7CiAgcmV0dXJuIGA8aDI+JHt0KCJwclRpdGxlIil9PC9oMj48cCBjbGFzcz0ic3ViIj4ke3QoInByU3ViIil9PC9wPgogIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9Imxpc3QiIGlkPSJwcml2TGlzdCI+JHt0dy5tYXAoeD0+cm93VHdlYWsoeCkpLmpvaW4oIiIpfTwvZGl2PgogIDxkaXYgY2xhc3M9ImFjdGlvbnMiPjxidXR0b24gY2xhc3M9ImJ0biIgZGF0YS1hY3Q9InByaXZhY3lfcGFjayI+JHt0KCJhcHBseVByaXYiKX08L2J1dHRvbj48L2Rpdj48L2Rpdj5gOwp9CmZ1bmN0aW9uIHJvd1R3ZWFrKHgpewogIHJldHVybiBgPGRpdiBjbGFzcz0iaXRlbSI+PGRpdj4ke2xhbmc9PT0iYXIiP3guYXI6eC5lbn08L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIGRhdGEtYWN0PSJ0d2Vha18ke3guaWR9Ij4ke3QoInJ1biIpfTwvYnV0dG9uPjwvZGl2PmA7Cn0KZnVuY3Rpb24gcmVuZGVyVHdlYWtzKCl7CiAgcmV0dXJuIGA8aDI+JHt0KCJ0d1RpdGxlIil9PC9oMj48cCBjbGFzcz0ic3ViIj4ke3QoInR3U3ViIil9PC9wPgogIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9Imxpc3QiPiR7ZGVmYXVsdFR3ZWFrcygpLm1hcChyb3dUd2Vhaykuam9pbigiIil9PC9kaXY+PC9kaXY+YDsKfQpmdW5jdGlvbiByZW5kZXJSZXBhaXIoKXsKICByZXR1cm4gYDxoMj4ke3QoInJwVGl0bGUiKX08L2gyPjxwIGNsYXNzPSJzdWIiPiR7dCgicnBTdWIiKX08L3A+CiAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0ibGlzdCI+JHtkZWZhdWx0UmVwYWlycygpLm1hcCh4PT5gPGRpdiBjbGFzcz0iaXRlbSI+PGRpdj4ke2xhbmc9PT0iYXIiP3guYXI6eC5lbn08L2Rpdj48YnV0dG9uIGNsYXNzPSJidG4gc2VjIiBkYXRhLWFjdD0iJHt4LmlkfSI+JHt0KCJydW4iKX08L2J1dHRvbj48L2Rpdj5gKS5qb2luKCIiKX08L2Rpdj48L2Rpdj5gOwp9CmZ1bmN0aW9uIHJlbmRlclN0YXJ0dXAoKXsKICByZXR1cm4gYDxoMj4ke3QoInN1VGl0bGUiKX08L2gyPjxwIGNsYXNzPSJzdWIiPiR7dCgic3VTdWIiKX08L3A+CiAgPGRpdiBjbGFzcz0iY2FyZCI+PGRpdiBjbGFzcz0ibGlzdCIgaWQ9InN1TGlzdCI+JHtsYW5nPT09ImFyIj8i2KzYp9ix2Yog2KfZhNiq2K3ZhdmK2YTigKYiOiJMb2FkaW5n4oCmIn08L2Rpdj48L2Rpdj5gOwp9CmZ1bmN0aW9uIHJlbmRlclRvb2xzKCl7CiAgcmV0dXJuIGA8aDI+JHt0KCJ0b29sc1RpdGxlIil9PC9oMj48cCBjbGFzcz0ic3ViIj4ke3QoInRvb2xzU3ViIil9PC9wPgogIDxkaXYgY2xhc3M9ImdyaWQiPgogICAgPGRpdiBjbGFzcz0iY2FyZCBzcGFuMTIiPjxkaXYgY2xhc3M9ImFjdGlvbnMiPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4iIGRhdGEtYWN0PSJ3aWZpIj4ke3QoIndpZmkiKX08L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgZGF0YS1hY3Q9InBvcnRzIj4ke3QoInBvcnRzIil9PC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBzZWMiIGRhdGEtYWN0PSJyZXN0b3JlIj4ke3QoInJlc3RvcmUiKX08L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgZGF0YS1hY3Q9ImdvZG1vZGUiPiR7dCgiZ29kIil9PC9idXR0b24+CiAgICA8L2Rpdj48ZGl2IGNsYXNzPSJsb2ciIGlkPSJ0b29sbG9nIiBzdHlsZT0ibWFyZ2luLXRvcDoxMnB4Ij48L2Rpdj48L2Rpdj4KICA8L2Rpdj5gOwp9CmZ1bmN0aW9uIHJlbmRlckFib3V0KCl7CiAgcmV0dXJuIGA8aDI+JHt0KCJhYm91dFRpdGxlIil9PC9oMj4KICA8ZGl2IGNsYXNzPSJjYXJkIj48cD4ke3QoImFib3V0Qm9keSIpfTwvcD4KICA8cCBjbGFzcz0iayI+UmFmaXEgMS4wLjAgwrcgTUlUIExpY2Vuc2UgwrcgV2luZG93cyAxMCB2ZXJzaW9uIDE4MDkrIC8gV2luZG93cyAxMTwvcD4KICA8cCBjbGFzcz0iayI+JHtsYW5nPT09ImFyIj8i2KfZhNmF2LXYr9ixINmF2YHYqtmI2K0uINmE2Kcg2KrZiNis2K8g2KrYrdmE2YrZhNin2KouINmE2Kcg2KrZiNis2K8g2LTYqNmD2Kkg2KXZhNinIGxvY2FsaG9zdC4iOiJPcGVuIHNvdXJjZS4gTm8gdGVsZW1ldHJ5LiBUaGUgYXBwIGxpc3RlbnMgb24gbG9jYWxob3N0IG9ubHkuIn08L3A+CiAgPC9kaXY+YDsKfQoKY29uc3QgUkVOREVSUyA9IHtkYXNoOnJlbmRlckRhc2gsIG5ldDpyZW5kZXJOZXQsIHN0b3JhZ2U6cmVuZGVyU3RvcmFnZSwgcHJpdmFjeTpyZW5kZXJQcml2YWN5LCB0d2Vha3M6cmVuZGVyVHdlYWtzLCByZXBhaXI6cmVuZGVyUmVwYWlyLCBzdGFydHVwOnJlbmRlclN0YXJ0dXAsIHRvb2xzOnJlbmRlclRvb2xzLCBhYm91dDpyZW5kZXJBYm91dH07Cgphc3luYyBmdW5jdGlvbiByZW5kZXIoKXsKICBhcHBseUNocm9tZSgpOwogICQoInZpZXciKS5pbm5lckhUTUwgPSBSRU5ERVJTW3BhZ2VdKCk7CiAgJCgidmlldyIpLnF1ZXJ5U2VsZWN0b3JBbGwoIltkYXRhLWFjdF0iKS5mb3JFYWNoKGI9PmIub25jbGljaz0oKT0+cnVuQWN0KGIuZGF0YXNldC5hY3QsYikpOwogIGlmKHBhZ2U9PT0ic3RvcmFnZSIpewogICAgJCgic2NhbkJ0biIpLm9uY2xpY2s9c2NhblN0b3JhZ2U7CiAgICAkKCJjbGVhbkJ0biIpLm9uY2xpY2s9Y2xlYW5TdG9yYWdlOwogIH0KICBpZihwYWdlPT09InN0YXJ0dXAiKSBsb2FkU3RhcnR1cCgpOwp9Cgphc3luYyBmdW5jdGlvbiBydW5BY3QoYWN0LCBidG4pewogIGlmKGJ0bikgYnRuLmRpc2FibGVkPXRydWU7CiAgdHJ5ewogICAgaWYoYWN0PT09ImRpYWdub3NlIil7CiAgICAgIGNvbnN0IHIgPSBhd2FpdCBhcGkoIi9hcGkvYWN0aW9uIix7YWN0aW9uOiJkaWFnbm9zZSJ9KTsKICAgICAgY29uc3QgbG9nPSQoIm5ldGxvZyIpOyBpZihsb2cpIGxvZy50ZXh0Q29udGVudCA9IHIub3V0cHV0IHx8IHIubWVzc2FnZSB8fCBKU09OLnN0cmluZ2lmeShyLG51bGwsMik7CiAgICAgIHRvYXN0KHIub2s/dCgib2siKTp0KCJmYWlsIikpOyByZXR1cm47CiAgICB9CiAgICBpZihhY3Q9PT0id2lmaSJ8fGFjdD09PSJwb3J0cyIpewogICAgICBjb25zdCByID0gYXdhaXQgYXBpKGFjdD09PSJ3aWZpIj8iL2FwaS93aWZpIjoiL2FwaS9wb3J0cyIpOwogICAgICBjb25zdCBsb2c9JCgidG9vbGxvZyIpOwogICAgICBpZihhY3Q9PT0id2lmaSIpIGxvZy50ZXh0Q29udGVudD0oci5pdGVtc3x8W10pLm1hcCh4PT5gJHt4LnNzaWR9ICAke3gua2V5fHwiIn1gKS5qb2luKCJcbiIpfHwi4oCUIjsKICAgICAgZWxzZSBsb2cudGV4dENvbnRlbnQ9KHIuaXRlbXN8fFtdKS5tYXAoeD0+YCR7eC5wcm90b30gJHt4LnBvcnR9ICBwaWQgJHt4LnBpZH0gICR7eC5uYW1lfWApLmpvaW4oIlxuIil8fCLigJQiOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCByID0gYXdhaXQgYXBpKCIvYXBpL2FjdGlvbiIse2FjdGlvbjphY3R9KTsKICAgIHRvYXN0KChyLm1lc3NhZ2V8fCAoci5vaz90KCJvayIpOnQoImZhaWwiKSkpKTsKICAgIGlmKHIub3V0cHV0ICYmICQoInRvb2xsb2ciKSkgJCgidG9vbGxvZyIpLnRleHRDb250ZW50PXIub3V0cHV0OwogICAgaWYoci5vdXRwdXQgJiYgJCgibmV0bG9nIikpICQoIm5ldGxvZyIpLnRleHRDb250ZW50PXIub3V0cHV0OwogIH1jYXRjaChlKXt0b2FzdChTdHJpbmcoZSkpfQogIGZpbmFsbHl7aWYoYnRuKSBidG4uZGlzYWJsZWQ9ZmFsc2V9Cn0KCmFzeW5jIGZ1bmN0aW9uIHNjYW5TdG9yYWdlKCl7CiAgY29uc3QgYm94PSQoInNjYW5MaXN0Iik7IGJveC50ZXh0Q29udGVudD1sYW5nPT09ImFyIj8i2KzYp9ix2Yog2KfZhNmB2K3YteKApiI6IlNjYW5uaW5n4oCmIjsKICBjb25zdCByPWF3YWl0IGFwaSgiL2FwaS9zY2FuIik7CiAgd2luZG93Ll9zY2FuPXIuaXRlbXN8fFtdOwogIGJveC5pbm5lckhUTUwgPSB3aW5kb3cuX3NjYW4ubWFwKChpdCxpKT0+YDxsYWJlbCBjbGFzcz0iY2hlY2siPjxpbnB1dCB0eXBlPSJjaGVja2JveCIgY2hlY2tlZCBkYXRhLWk9IiR7aX0iLz4KICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+PGI+JHtpdC5sYWJlbH08L2I+PGRpdiBjbGFzcz0iayI+JHtpdC5wYXRofHwiIn08L2Rpdj48L2Rpdj48Yj4ke2ZtdEJ5dGVzKGl0LmJ5dGVzKX08L2I+PC9sYWJlbD5gKS5qb2luKCIiKTsKfQphc3luYyBmdW5jdGlvbiBjbGVhblN0b3JhZ2UoKXsKICBpZighY29uZmlybSh0KCJjb25maXJtQ2xlYW4iKSkpIHJldHVybjsKICBjb25zdCBpZHM9Wy4uLmRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoIiNzY2FuTGlzdCBpbnB1dDpjaGVja2VkIildLm1hcCh4PT53aW5kb3cuX3NjYW5bK3guZGF0YXNldC5pXS5pZCk7CiAgY29uc3Qgcj1hd2FpdCBhcGkoIi9hcGkvYWN0aW9uIix7YWN0aW9uOiJjbGVhbiIsIGlkc30pOwogIHRvYXN0KHIubWVzc2FnZXx8dCgib2siKSk7CiAgc2NhblN0b3JhZ2UoKTsKfQphc3luYyBmdW5jdGlvbiBsb2FkU3RhcnR1cCgpewogIGNvbnN0IHI9YXdhaXQgYXBpKCIvYXBpL3N0YXJ0dXAiKTsKICAkKCJzdUxpc3QiKS5pbm5lckhUTUw9KHIuaXRlbXN8fFtdKS5tYXAoaXQ9PmA8ZGl2IGNsYXNzPSJpdGVtIj48ZGl2PjxiPiR7aXQubmFtZX08L2I+PGRpdiBjbGFzcz0iayI+JHtpdC5sb2N8fCIifTwvZGl2PjwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgZGF0YS1hY3Q9InN0YXJ0dXBfdG9nZ2xlIiBkYXRhLW5hbWU9IiR7aXQubmFtZX0iPiR7aXQuZW5hYmxlZD8obGFuZz09PSJhciI/Itiq2LnYt9mK2YQiOiJEaXNhYmxlIik6KGxhbmc9PT0iYXIiPyLYqtmF2YPZitmGIjoiRW5hYmxlIil9PC9idXR0b24+PC9kaXY+YCkuam9pbigiIil8fCLigJQiOwogICQoInN1TGlzdCIpLnF1ZXJ5U2VsZWN0b3JBbGwoIltkYXRhLWFjdF0iKS5mb3JFYWNoKGI9PmIub25jbGljaz1hc3luYygpPT57CiAgICBhd2FpdCBhcGkoIi9hcGkvYWN0aW9uIix7YWN0aW9uOiJzdGFydHVwX3RvZ2dsZSIsIG5hbWU6Yi5kYXRhc2V0Lm5hbWV9KTsKICAgIGxvYWRTdGFydHVwKCk7CiAgfSk7Cn0KCiQoImJ0bkFyIikub25jbGljaz0oKT0+e2xhbmc9ImFyIjsgbG9jYWxTdG9yYWdlLnNldEl0ZW0oInJhZmlxLWxhbmciLCJhciIpOyByZW5kZXIoKX07CiQoImJ0bkVuIikub25jbGljaz0oKT0+e2xhbmc9ImVuIjsgbG9jYWxTdG9yYWdlLnNldEl0ZW0oInJhZmlxLWxhbmciLCJlbiIpOyByZW5kZXIoKX07CgooYXN5bmMoKT0+ewogIHRyeXsgUyA9IGF3YWl0IGFwaSgiL2FwaS9pbmZvIik7IH1jYXRjaChlKXsgUz17b2s6ZmFsc2UsZGVtbzp0cnVlLGluZm86bnVsbH0gfQogIGlmKCFTLmluZm8gJiYgUy5vcykgUy5pbmZvPVM7CiAgYXdhaXQgcmVuZGVyKCk7Cn0pKCk7Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4K
'@
$Html = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($HtmlB64.Trim()))

# Pick a free port
$tcp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$tcp.Start()
$Port = ([Net.IPEndPoint]$tcp.LocalEndpoint).Port
$tcp.Stop()

$Listener = [Net.HttpListener]::new()
$Listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $Listener.Start()
} catch {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("Rafiq could not bind localhost:$Port`n$_", 'Rafiq')
    exit 1
}

Write-RafiqLog "listening on 127.0.0.1:$Port admin=$(Test-RafiqAdmin)"

function Receive-RafiqRequest {
    try { $ctx = $Listener.GetContext() } catch { return }
    try {
        $req = $ctx.Request
        $res = $ctx.Response
        $path = $req.Url.AbsolutePath.TrimEnd('/').ToLower()
        if ($path -eq '') { $path = '/' }
        if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
            Send-Rafiq $res $Html 'text/html; charset=utf-8'
        } elseif ($path -eq '/api/info' -or $path -eq '/api/health') {
            Send-Rafiq $res (Get-RafiqJson (Get-RafiqInfo))
        } elseif ($path -eq '/api/scan') {
            Send-Rafiq $res (Get-RafiqJson (Get-RafiqScan))
        } elseif ($path -eq '/api/startup') {
            Send-Rafiq $res (Get-RafiqJson (Get-RafiqStartup))
        } elseif ($path -eq '/api/wifi') {
            Send-Rafiq $res (Get-RafiqJson (Get-RafiqWifi))
        } elseif ($path -eq '/api/ports') {
            Send-Rafiq $res (Get-RafiqJson (Get-RafiqPorts))
        } elseif ($path -eq '/api/action' -and $req.HttpMethod -eq 'POST') {
            $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
            $raw = $sr.ReadToEnd(); $sr.Close()
            try { $body = $raw | ConvertFrom-Json } catch { $body = @{ action = '' } }
            $result = Invoke-RafiqAction $body
            Send-Rafiq $res (Get-RafiqJson $result)
        } elseif ($path -eq '/api/quit') {
            Send-Rafiq $res '{"ok":true}'
            $script:RafiqStop = $true
        } else {
            Send-Rafiq $res '{"ok":false}' 'application/json' 404
        }
    } catch {
        Write-RafiqLog "http $_"
        try { Send-Rafiq $ctx.Response (Get-RafiqJson @{ ok = $false; message = "$_" }) } catch {}
    }
}

function Find-RafiqBrowser {
    $cands = @(
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

$url = "http://127.0.0.1:$Port/"
$browser = Find-RafiqBrowser
$edgeProfile = Join-Path $RafiqRoot 'edge-profile'
New-Item -ItemType Directory -Force -Path $edgeProfile | Out-Null
$script:RafiqStop = $false
$proc = $null

if ($browser) {
    $bArgs = @("--app=$url", "--user-data-dir=$edgeProfile", '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--window-size=1280,800')
    $proc = Start-Process -FilePath $browser -ArgumentList $bArgs -PassThru
    Write-RafiqLog "browser $($proc.Id) $browser"
} else {
    Start-Process $url
    Write-RafiqLog 'opened default browser'
}

while (-not $script:RafiqStop) {
    if ($proc -and $proc.HasExited) { break }
    if ($Listener.Pending) {
        Receive-RafiqRequest
    } else {
        Start-Sleep -Milliseconds 40
    }
}

try { $Listener.Stop() } catch {}
try { $Listener.Close() } catch {}
Write-RafiqLog 'exit'
