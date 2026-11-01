#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Url = 'https://lms.astanait.edu.kz',
    [string]$Profile = 'Default',
    [string]$Size,
    [switch]$Help,
    [switch]$Force,
    [switch]$KeepProfile,
    [switch]$NoPreview,
    [ValidateSet('Required', 'MonitorOnly')][string]$DesktopMode = 'Required',
    [string]$DisplayName
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Show-OesHelp {
    @'
oes-babl-win - Chrome on a dedicated Virtual Display Driver monitor
Usage: oes-babl-win.ps1 [-Url https://...] [-Profile Default] [-Size 1920x1080]
       [-Force] [-KeepProfile] [-DesktopMode Required|MonitorOnly]
       [-DisplayName \\.\DISPLAY2] [-NoPreview] [-Verbose] [-Help]
Size priority: -Size > OES_BABL_SIZE > saved screen-size > 1920x1080.
Profile priority: explicit -Profile > CHROME_PROFILE > Default.
-Force permits termination of existing Chrome processes in your Windows session.
-KeepProfile retains this run's NEW, temporary profile (contains private data).
-DesktopMode MonitorOnly explicitly skips Windows virtual desktop automation.
-DisplayName selects one verified VDD, never an arbitrary secondary monitor.
In Meet, select Entire screen and ONLY the VDD monitor. This is not a sandbox.
Existing Chrome cookies/passwords are NOT copied into the fresh profile.
Preview opens on the physical monitor. Click the image, then type into Chrome.
Preview supports clicks and scrolling, not dragging. Close preview to stop.
-NoPreview disables the built-in viewer (use your own VDD viewer).
'@
}

function Get-OesWindowsVersion {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows 10 1809+ or Windows 11 is required.' }
    $v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($v.InstallationType -ne 'Client') { throw 'Windows client editions are required; Windows Server is not supported.' }
    if ([int]$v.CurrentBuildNumber -lt 17763) { throw 'Windows 10 1809 (build 17763) or newer is required.' }
    if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Use native x64 PowerShell on x64 Windows. ARM64/x86 VDA binaries are not supported by this package.'
    }
    [pscustomobject]@{ Build = [int]$v.CurrentBuildNumber; UBR = [int]$v.UBR }
}

function Get-OesVdaRelease($Version) {
    # Проверка недокументированного ABI / never load a random latest on older Windows.
    if ($Version.Build -lt 22000) { return '2019-windows10' }
    if (($Version.Build -eq 26100 -and $Version.UBR -ge 2605) -or $Version.Build -eq 26200) { return '2024-12-16-windows11' }
    if (($Version.Build -eq 22631 -or $Version.Build -eq 22621) -and $Version.UBR -ge 3085) { return '2024-01-25-windows11' }
    if (($Version.Build -eq 22621 -and $Version.UBR -ge 2215) -or ($Version.Build -eq 22631 -and $Version.UBR -ge 2506)) {
        return '2023-11-10-windows11'
    }
    return $null
}

function Resolve-OesSize([string]$Explicit, [string]$EnvironmentSize, [string]$SettingsFile) {
    $value = $Explicit
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $EnvironmentSize }
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = '1920x1080'
        if (Test-Path -LiteralPath $SettingsFile) {
            $saved = (Get-Content -LiteralPath $SettingsFile -Raw).Trim()
            if ($saved -match '^([1-9]\d{0,4})x([1-9]\d{0,4})$' -and [int]$Matches[1] -le 16384 -and [int]$Matches[2] -le 16384) { $value = $saved }
            else { Write-Warning 'Invalid saved screen-size; using 1920x1080. Re-run install.ps1.' }
        }
    }
    if ($value -notmatch '^([1-9]\d{0,4})x([1-9]\d{0,4})$') {
        throw 'Invalid size. Use positive WIDTHxHEIGHT, for example -Size 1920x1080.'
    }
    $width = [int]$Matches[1]; $height = [int]$Matches[2]
    if ($width -gt 16384 -or $height -gt 16384) { throw 'Size exceeds 16384 pixels per dimension.' }
    [pscustomobject]@{ Width = $width; Height = $height }
}

function Resolve-OesProfile([string]$Requested, [bool]$Explicit, [string]$EnvironmentProfile) {
    $result = $Requested
    if (-not $Explicit -and -not [string]::IsNullOrWhiteSpace($EnvironmentProfile)) { $result = $EnvironmentProfile }
    if ([string]::IsNullOrWhiteSpace($result) -or $result -match '[\\/:*?"<>|\x00-\x1f]' -or
        $result -eq '.' -or $result -eq '..' -or $result.EndsWith('.') -or $result.EndsWith(' ')) {
        throw 'Profile must be a directory name, for example Default or Profile 1; paths are not allowed.'
    }
    $result
}

function ConvertTo-OesArgument([string]$Value) {
    # Windows argument quoting: spaces, embedded quotes and trailing backslashes.
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Initialize-OesNative {
    if ('Oes.Native' -as [type]) { return }
    Add-Type -Path (Join-Path $PSScriptRoot 'lib\OesNative.cs')
}

function Test-OesVddDevice($Device) {
    # PnP instance is often ROOT\DISPLAY\0000, while its hardware ID identifies VDD.
    # UMDF service WUDFRd is shared by unrelated drivers; do not identify by that service.
    $hardwareMatch = @($Device.HardwareID | Where-Object { $_ -match '(?i)^(ROOT\\)?MttVDD$' }).Count -gt 0
    $hardwareMatch -or $Device.PNPDeviceID -match '(?i)(^|\\)MTTVDD(\\|$)' -or $Device.Service -eq 'MttVDD'
}

function Get-OesVddDevice {
    @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass = 'Display'" | Where-Object { Test-OesVddDevice $_ })
}

function Assert-OesVddInstalled {
    $devices = @(Get-OesVddDevice)
    if ($devices.Count -eq 0) {
        throw 'VDD is not installed. Run: winget install --id=VirtualDrivers.Virtual-Display-Driver -e . Then install/enable its driver in Virtual Driver Control if necessary.'
    }
    if (@($devices | Where-Object { $_.ConfigManagerErrorCode -eq 0 }).Count -eq 0) {
        throw 'VDD is installed but disabled or has a device error. Enable Virtual Display Driver in Device Manager as administrator, or repair it in Virtual Driver Control. Reboot if installation requested it.'
    }
}

function Select-OesDisplay($Displays, [string]$Requested) {
    $candidates = @($Displays | Where-Object { $_.IsVdd })
    if ($Requested) { $candidates = @($candidates | Where-Object { $_.Name -eq $Requested }) }
    if ($candidates.Count -eq 0) {
        throw 'No verified VDD display endpoint found. Add/enable one monitor in Virtual Driver Control, then select Extend these displays in Windows Settings. Physical secondary monitors are not eligible.'
    }
    if ($candidates.Count -gt 1) {
        throw ('Several VDD displays exist. Select one with -DisplayName. Candidates: ' + (($candidates | ForEach-Object { $_.Name }) -join ', '))
    }
    if ($candidates[0].Primary) { throw 'VDD is primary. Make your physical monitor primary in Windows Display Settings before running.' }
    $candidates[0]
}

function Assert-OesDisplayLayout($Target, $Displays) {
    if ($Target.Primary) { throw 'VDD became the primary monitor. Make the physical monitor primary before restarting.' }
    foreach ($other in @($Displays | Where-Object { $_.Active -and $_.Name -ne $Target.Name })) {
        if ($Target.Mode.X -lt ($other.Mode.X + $other.Mode.Width) -and ($Target.Mode.X + $Target.Mode.Width) -gt $other.Mode.X -and
            $Target.Mode.Y -lt ($other.Mode.Y + $other.Mode.Height) -and ($Target.Mode.Y + $Target.Mode.Height) -gt $other.Mode.Y) {
            throw 'VDD overlaps/mirrors another screen. Set Extend these displays and arrange non-overlapping monitors in Windows Settings.'
        }
    }
}

function Enable-VirtualDisplay($Display, $RequestedSize) {
    # Меняем только выбранный VDD / no global DisplaySwitch topology change.
    $mode = [Oes.Native]::FindMode($Display.Name, $RequestedSize.Width, $RequestedSize.Height)
    $mode.Fields = 0x180020
    if ($Display.Active) { $mode.X = $Display.Mode.X; $mode.Y = $Display.Mode.Y }
    else {
        $screens = @([Oes.Native]::Displays() | Where-Object { $_.Active })
        if ($screens.Count -eq 0) { throw 'No active physical display. Use a local interactive Windows session.' }
        $edge = $screens | Sort-Object { $_.Mode.X + $_.Mode.Width } -Descending | Select-Object -First 1
        $mode.X = $edge.Mode.X + [int]$edge.Mode.Width; $mode.Y = $edge.Mode.Y
    }
    if (-not $Display.Active -or $Display.Mode.Width -ne $RequestedSize.Width -or $Display.Mode.Height -ne $RequestedSize.Height) {
        [Oes.Native]::ApplyMode($Display.Name, $mode, (-not $Display.Active))
    }
    $actual = @([Oes.Native]::Displays() | Where-Object { $_.Name -eq $Display.Name -and $_.IsVdd -and $_.Active })
    if ($actual.Count -ne 1 -or $actual[0].Mode.Width -ne $RequestedSize.Width -or $actual[0].Mode.Height -ne $RequestedSize.Height) {
        throw 'VDD activation/size verification failed. Select Extend these displays in Windows Settings and retry.'
    }
    $target = $actual[0]
    Assert-OesDisplayLayout $target ([Oes.Native]::Displays())
    $target
}

function Disable-VirtualDisplay([string]$Name) {
    $display = Select-OesDisplay ([Oes.Native]::Displays()) $Name
    if ($display.Active) { [Oes.Native]::Detach($Name) }
    if (@([Oes.Native]::Displays() | Where-Object { $_.Name -eq $Name -and $_.Active }).Count) {
        throw 'VDD is still active. Disconnect this display in Windows Settings.'
    }
}

function Find-OesChrome {
    $paths = @(
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
        if (Test-Path $key) { $paths += (Get-Item $key).GetValue('') }
    }
    foreach ($path in $paths) { if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path } }
    throw 'Google Chrome was not found. Install Google Chrome, then retry.'
}

function Get-OesExistingChrome {
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    @(Get-Process -Name chrome -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
}

function Confirm-OesChromeClosed([bool]$AllowForce) {
    $running = @(Get-OesExistingChrome)
    if ($running.Count -eq 0) { return }
    Write-Warning 'Chrome is running. Closing it can discard unsaved work in all Chrome windows of this Windows session.'
    if (-not $AllowForce -and (Read-Host 'Close all these Chrome processes? Type YES to continue') -cne 'YES') {
        throw 'Cancelled. Close Chrome yourself and retry, or use -Force to authorize termination.'
    }
    foreach ($process in $running) { if ($process.MainWindowHandle -ne [IntPtr]::Zero) { [void]$process.CloseMainWindow() } }
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (@(Get-OesExistingChrome).Count -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
    foreach ($process in @(Get-OesExistingChrome)) {
        try { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
        catch { if (-not $process.HasExited) { throw } }
    }
    if (@(Get-OesExistingChrome).Count) { throw 'Chrome is still running. Close it in Task Manager and retry.' }
}

function Remove-OesTemporaryProfile([string]$Path, [string]$Root) {
    # Только свой GUID-каталог / reject junctions and symlinks before recursive removal.
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parsed = [Guid]::Empty
    if ([IO.Path]::GetDirectoryName($pathFull) -ine $rootFull -or
        -not [Guid]::TryParseExact([IO.Path]::GetFileName($pathFull), 'D', [ref]$parsed)) {
        throw 'Refusing to remove a directory outside the owned GUID profile root.'
    }
    if (-not (Test-Path -LiteralPath $pathFull)) { return }
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($pathFull)
    while ($queue.Count) {
        $dir = Get-Item -LiteralPath $queue.Dequeue() -Force
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Profile contains a reparse point; remove it manually after review.' }
        foreach ($child in @(Get-ChildItem -LiteralPath $dir.FullName -Force)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Profile contains a reparse point; remove it manually after review.' }
            if ($child.PSIsContainer) { $queue.Enqueue($child.FullName) }
        }
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try { Remove-Item -LiteralPath $pathFull -Recurse -Force; return }
        catch { if ($attempt -eq 19) { throw }; [Threading.Thread]::Sleep(250) }
    }
}

function Get-OesVdaHash([string]$Tag) {
    # Pinned official release assets, verified 2026-10-31; never trust a replaced asset.
    $hashes = @{
        '2024-12-16-windows11' = '8740C572A1C000E3B87FFEB1E4C397EAE9AF3BD4A2ABDC3BCFFACAB4493F8FF5'
        '2024-01-25-windows11' = 'F78FF6334F6C0EF5175EC0819026CEC31D421A564B9ED1EE1AC4B6ED98D4F999'
        '2023-11-10-windows11' = '6FDE6F5F409B026688F01AC44973A9D95FB37AE71632E4CBDD8BDD8C7F7C9C17'
        '2019-windows10' = '145431BC2090281838DE31824BC829DD35688B13488F4850F4BC5F25F5E599DA'
    }
    if (-not $hashes.ContainsKey($Tag)) { throw "Unapproved VDA release: $Tag. Update the compatibility table first." }
    $hashes[$Tag]
}

function Open-OesDesktops($Version) {
    $tag = Get-OesVdaRelease $Version
    if (-not $tag -or $Version.Build -lt 22000) {
        throw "Desktop automation is not supported for Windows build $($Version.Build).$($Version.UBR). Use -DesktopMode MonitorOnly explicitly, or a supported Windows 11 build. Public COM cannot create/remove desktops."
    }
    $lib = Join-Path $env:LOCALAPPDATA 'oes-babl-win\lib'
    $dll = Join-Path $lib 'VirtualDesktopAccessor.dll'
    $manifest = Join-Path $lib 'vda.json'
    if (-not (Test-Path $dll) -or -not (Test-Path $manifest)) { throw 'VDA files are missing. Run install.ps1 first.' }
    $metadata = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    if ($metadata.Tag -ne $tag -or $metadata.Sha256 -ne (Get-OesVdaHash $tag) -or
        (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $metadata.Sha256) {
        throw 'VDA version/hash does not match this Windows build. Re-run install.ps1.'
    }
    New-Object Oes.Desktops -ArgumentList $dll
}

function Get-OesPreviewPoint([int]$ViewWidth, [int]$ViewHeight, [int]$ImageWidth, [int]$ImageHeight, [int]$X, [int]$Y) {
    if ($ViewWidth -le 0 -or $ViewHeight -le 0) { return $null }
    $scale = [Math]::Min($ViewWidth / [double]$ImageWidth, $ViewHeight / [double]$ImageHeight)
    $left = ($ViewWidth - $ImageWidth * $scale) / 2
    $top = ($ViewHeight - $ImageHeight * $scale) / 2
    if ($X -lt $left -or $Y -lt $top -or $X -ge ($ViewWidth - $left) -or $Y -ge ($ViewHeight - $top)) { return $null }
    [pscustomobject]@{
        X = [Math]::Min($ImageWidth - 1, [int][Math]::Floor(($X - $left) / $scale))
        Y = [Math]::Min($ImageHeight - 1, [int][Math]::Floor(($Y - $top) / $scale))
    }
}

function New-OesPreview {
    param($Display, [switch]$Hidden)
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    $form = New-Object Windows.Forms.Form
    $picture = New-Object Windows.Forms.PictureBox
    $bitmap = $null
    try {
        $form.Text = 'oes-babl-win | Click image, then type in Chrome | Close to stop'
        $form.StartPosition = 'Manual'
        $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Bounds = New-Object Drawing.Rectangle($area.X, $area.Y, [Math]::Min(1200,$area.Width), [Math]::Min(800,$area.Height))
        $form.MinimumSize = New-Object Drawing.Size(320,240)
        $picture.Dock = 'Fill'; $picture.SizeMode = 'Zoom'; $picture.BackColor = [Drawing.Color]::Black
        $form.Controls.Add($picture)
        $bitmap = New-Object Drawing.Bitmap([int]$Display.Mode.Width, [int]$Display.Mode.Height)
        $picture.Image = $bitmap
        $state = [pscustomobject]@{ Form=$form; Picture=$picture; Bitmap=$bitmap; Display=$Display; Error=$null }
        $pointMapper = (Get-Command Get-OesPreviewPoint).ScriptBlock
        $click = {
            param($sender,$eventArgs)
            try {
                $point = & $pointMapper $sender.ClientSize.Width $sender.ClientSize.Height $state.Bitmap.Width $state.Bitmap.Height $eventArgs.X $eventArgs.Y
                if ($null -eq $point) { return }
                $button = 1
                if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Right) { $button = 2 }
                if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Middle) { $button = 3 }
                [Oes.Native]::PreviewInput(($state.Display.Mode.X + $point.X), ($state.Display.Mode.Y + $point.Y), $button, 0)
            } catch { $state.Error = $_.Exception.Message }
        }.GetNewClosure()
        $wheel = {
            param($sender,$eventArgs)
            try {
                $point = & $pointMapper $sender.ClientSize.Width $sender.ClientSize.Height $state.Bitmap.Width $state.Bitmap.Height $eventArgs.X $eventArgs.Y
                if ($null -ne $point) {
                    [Oes.Native]::PreviewInput(($state.Display.Mode.X + $point.X), ($state.Display.Mode.Y + $point.Y), 0, $eventArgs.Delta)
                }
            } catch { $state.Error = $_.Exception.Message }
        }.GetNewClosure()
        $picture.Add_MouseClick($click)
        $picture.Add_MouseWheel($wheel)
        if (-not $Hidden) {
            $form.Show()
            [Oes.Native]::ShowPreview($form.Handle)
        }
        $state
    } catch {
        $form.Dispose()
        if ($bitmap) { $bitmap.Dispose() }
        throw
    }
}

function Update-OesPreview($Preview) {
    if ($Preview.Form.IsDisposed) { return $false }
    if ($Preview.Error) { throw ('Preview input: ' + $Preview.Error) }
    # Зеркало остаётся на физическом экране / prevent recursive VDD capture.
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if (-not $area.Contains($Preview.Form.Bounds)) {
        $Preview.Form.WindowState = 'Normal'
        $Preview.Form.Bounds = New-Object Drawing.Rectangle($area.X,$area.Y,[Math]::Min(1200,$area.Width),[Math]::Min(800,$area.Height))
    }
    $graphics = [Drawing.Graphics]::FromImage($Preview.Bitmap)
    try {
        $graphics.CopyFromScreen([int]$Preview.Display.Mode.X,[int]$Preview.Display.Mode.Y,0,0,$Preview.Bitmap.Size)
    } finally { $graphics.Dispose() }
    $Preview.Picture.Refresh()
    [Windows.Forms.Application]::DoEvents()
    return (-not $Preview.Form.IsDisposed)
}

function Invoke-OesRun {
    param([string]$TargetUrl, [string]$TargetProfile, [string]$TargetSize, [string]$Mode,
        [string]$TargetDisplay, [bool]$CloseExisting, [bool]$PreserveProfile, [bool]$ProfileExplicit, [bool]$DisablePreview)
    $version = Get-OesWindowsVersion
    $uri = $null
    if (-not [Uri]::TryCreate($TargetUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('https','http')) {
        throw 'Url must be an absolute http:// or https:// URL.'
    }
    $settings = Join-Path $env:APPDATA 'oes-babl-win\screen-size'
    $dimensions = Resolve-OesSize $TargetSize $env:OES_BABL_SIZE $settings
    $selectedProfile = Resolve-OesProfile $TargetProfile $ProfileExplicit $env:CHROME_PROFILE
    Assert-OesVddInstalled
    Initialize-OesNative
    $mutex = New-Object Threading.Mutex($false, 'Local\oes-babl-win-session')
    $locked = $false; $job = $null; $desktops = $null; $temporary = $null; $preview = $null
    $originalDesktop = [Guid]::Empty; $ownedDesktop = [Guid]::Empty
    $previousDisplay = $null; $displayChanged = $false; $oldDpi = [IntPtr]::Zero
    $runError = $null
    $cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another oes-babl-win run or installation is active in this Windows session.' }
        $oldDpi = [Oes.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))
        if ($oldDpi -eq [IntPtr]::Zero) { throw 'Cannot enable per-monitor DPI awareness.' }
        $previousDisplay = Select-OesDisplay ([Oes.Native]::Displays()) $TargetDisplay
        [void][Oes.Native]::FindMode($previousDisplay.Name, $dimensions.Width, $dimensions.Height)
        if ($Mode -eq 'Required') {
            $desktops = Open-OesDesktops $version
            $originalDesktop = $desktops.Current()
        } else { Write-Warning 'MonitorOnly: no separate Windows virtual desktop. Keep unrelated windows off the VDD.' }
        $chrome = Find-OesChrome
        Confirm-OesChromeClosed $CloseExisting
        # Владение фиксируется до изменения / recover partial activation failure.
        $displayChanged = -not $previousDisplay.Active -or $previousDisplay.Mode.Width -ne $dimensions.Width -or $previousDisplay.Mode.Height -ne $dimensions.Height
        $display = Enable-VirtualDisplay $previousDisplay $dimensions
        Add-Type -AssemblyName System.Windows.Forms
        $screen = @([Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $display.Name })
        Write-Verbose ("Screen.AllScreens matches: {0}; native physical bounds: {1},{2} {3}x{4}" -f
            $screen.Count, $display.Mode.X, $display.Mode.Y, $display.Mode.Width, $display.Mode.Height)
        $profileRoot = Join-Path $env:LOCALAPPDATA 'oes-babl-win\chrome-data'
        [void][IO.Directory]::CreateDirectory($profileRoot)
        $temporary = Join-Path $profileRoot ([Guid]::NewGuid().ToString('D'))
        [void][IO.Directory]::CreateDirectory($temporary)
        if ($desktops) { $ownedDesktop = $desktops.Create(); $desktops.Switch($ownedDesktop) }
        $arguments = @(
            "--user-data-dir=$temporary", "--profile-directory=$selectedProfile",
            '--new-window', '--no-first-run', '--no-default-browser-check', '--disable-background-mode',
            "--window-position=$($display.Mode.X),$($display.Mode.Y)",
            "--window-size=$($dimensions.Width),$($dimensions.Height)", $uri.AbsoluteUri
        )
        $commandLine = ($arguments | ForEach-Object { ConvertTo-OesArgument $_ }) -join ' '
        $job = New-Object Oes.ChromeJob -ArgumentList $chrome,$commandLine
        if (-not $DisablePreview) { $preview = New-OesPreview $display }
        if ($preview) {
            if ($desktops) { $desktops.AttachPreview($preview.Form.Handle, $ownedDesktop) }
            $preview.Form.Activate()
            Write-Verbose ("Preview HWND={0}; visible={1}; managedVisible={2}" -f $preview.Form.Handle, [Oes.Native]::IsWindowVisible($preview.Form.Handle), $preview.Form.Visible)
            if ($desktops) { Write-Verbose ("Preview desktop={0}; session desktop={1}" -f $desktops.WindowDesktop($preview.Form.Handle), $ownedDesktop) }
        }
        Write-Host "Chrome started on VDD $($display.Name), $($dimensions.Width)x$($dimensions.Height)."
        Write-Host 'In Meet: Entire screen -> select ONLY this VDD monitor. Stop sharing before closing Chrome or switching desktops.'
        Write-Host "Temporary profile: $temporary"
        $seen = New-Object 'System.Collections.Generic.HashSet[long]'
        $startupDeadline = [DateTime]::UtcNow.AddSeconds(45)
        $lastWindowTime = [DateTime]::UtcNow; $hadWindow = $false
        while ($true) {
            $allDisplays = [Oes.Native]::Displays()
            $activeDisplays = @($allDisplays | Where-Object { $_.Name -eq $display.Name -and $_.IsVdd -and $_.Active })
            if ($activeDisplays.Count -ne 1 -or $activeDisplays[0].Mode.X -ne $display.Mode.X -or
                $activeDisplays[0].Mode.Y -ne $display.Mode.Y -or
                $activeDisplays[0].Mode.Width -ne $dimensions.Width -or $activeDisplays[0].Mode.Height -ne $dimensions.Height) {
                throw 'VDD disappeared or its layout changed. Stopping this Chrome session; verify the capture source before restarting.'
            }
            Assert-OesDisplayLayout $activeDisplays[0] $allDisplays
            if ($desktops -and $desktops.Current() -ne $ownedDesktop) {
                throw 'The active Windows desktop changed. Stopping this Chrome session to avoid continuing on a different desktop.'
            }
            $windows = @([Oes.Native]::Windows($job.Handle))
            foreach ($window in $windows) {
                $isNew = $seen.Add($window.Handle.ToInt64())
                if ($isNew -and $desktops) { $desktops.Move($window.Handle, $ownedDesktop) }
                $b = $window.Bounds; $m = $display.Mode
                if ($isNew -or $b.Left -lt $m.X -or $b.Top -lt $m.Y -or
                    $b.Right -gt ($m.X + $m.Width) -or $b.Bottom -gt ($m.Y + $m.Height)) {
                    [Oes.Native]::Place($window.Handle, $m.X, $m.Y, $dimensions.Width, $dimensions.Height)
                }
            }
            if ($preview -and -not (Update-OesPreview $preview)) { break }
            if ($windows.Count) { $hadWindow = $true; $lastWindowTime = [DateTime]::UtcNow }
            elseif ($hadWindow -and ([DateTime]::UtcNow - $lastWindowTime).TotalSeconds -ge 3) { break }
            if ($job.ActiveCount -eq 0) {
                if (-not $hadWindow) { throw 'Chrome exited before creating a window. Check Chrome installation and profile permissions.' }
                break
            }
            if (-not $hadWindow -and [DateTime]::UtcNow -gt $startupDeadline) { throw 'Chrome window did not appear within 45 seconds.' }
            Start-Sleep -Milliseconds 125
        }
    } catch {
        $runError = $_
        throw
    } finally {
        # Независимая очистка / normal PowerShell Ctrl+C also enters finally.
        if ($preview) {
            try { $preview.Form.Dispose(); $preview.Bitmap.Dispose() }
            catch { $cleanupErrors.Add('Preview: ' + $_.Exception.Message) }
        }
        if ($job) {
            try {
                foreach ($window in @([Oes.Native]::Windows($job.Handle))) { [Oes.Native]::CloseWindow($window.Handle) }
                $until = [DateTime]::UtcNow.AddSeconds(5)
                while ($job.ActiveCount -gt 0 -and [DateTime]::UtcNow -lt $until) { [Threading.Thread]::Sleep(100) }
                $job.Stop()
                $until = [DateTime]::UtcNow.AddSeconds(5)
                while ($job.ActiveCount -gt 0 -and [DateTime]::UtcNow -lt $until) { [Threading.Thread]::Sleep(100) }
                if ($job.ActiveCount -gt 0) { throw 'Chrome children are still exiting; profile deletion may fail.' }
            } catch { $cleanupErrors.Add('Chrome: ' + $_.Exception.Message) }
            finally { $job.Dispose() }
        }
        if ($desktops) {
            try { if ($ownedDesktop -ne [Guid]::Empty) { $desktops.Remove($ownedDesktop, $originalDesktop) } }
            catch { $cleanupErrors.Add('Desktop removal: ' + $_.Exception.Message) }
            try {
                if ($originalDesktop -ne [Guid]::Empty -and $desktops.Index($originalDesktop) -ge 0) { $desktops.Switch($originalDesktop) }
            } catch { $cleanupErrors.Add('Desktop restore: ' + $_.Exception.Message) }
            finally { $desktops.Dispose() }
        }
        if ($displayChanged -and $previousDisplay) {
            try {
                if ($previousDisplay.Active) { [Oes.Native]::ApplyMode($previousDisplay.Name, $previousDisplay.Mode, $false) }
                else {
                    $stillActive = @([Oes.Native]::Displays() | Where-Object { $_.Name -eq $previousDisplay.Name -and $_.Active })
                    if ($stillActive.Count) { Disable-VirtualDisplay $previousDisplay.Name }
                }
            } catch { $cleanupErrors.Add('Display restore: ' + $_.Exception.Message) }
        }
        if ($temporary) {
            try {
                if ($PreserveProfile) { Write-Host "Profile retained (private data): $temporary" }
                else { Remove-OesTemporaryProfile $temporary $profileRoot }
            } catch { $cleanupErrors.Add("Profile cleanup ($temporary): " + $_.Exception.Message) }
        }
        if ($oldDpi -ne [IntPtr]::Zero) { [void][Oes.Native]::SetThreadDpiAwarenessContext($oldDpi) }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        foreach ($cleanupError in $cleanupErrors) { Write-Warning $cleanupError }
        if ($cleanupErrors.Count -and -not $runError) { throw 'Cleanup was incomplete. Follow the warnings above; see README-Windows.md recovery steps.' }
    }
}

# Function definitions are importable without side effects for installation/tests.
# Функции можно импортировать без запуска Chrome.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Help) { Show-OesHelp; exit 0 }
    try {
        $options = @{
            TargetUrl = $Url; TargetProfile = $Profile; TargetSize = $Size; Mode = $DesktopMode
            TargetDisplay = $DisplayName; CloseExisting = $Force.IsPresent
            PreserveProfile = $KeepProfile.IsPresent; ProfileExplicit = $PSBoundParameters.ContainsKey('Profile')
            DisablePreview = $NoPreview.IsPresent
        }
        Invoke-OesRun @options
        exit 0
    }
    catch { [Console]::Error.WriteLine(('oes-babl-win: ' + $_.Exception.Message)); exit 1 }
}
