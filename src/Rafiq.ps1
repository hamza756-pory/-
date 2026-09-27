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
__HTML_B64__
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
