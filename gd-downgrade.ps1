param([switch]$Undo, [switch]$GeodeOnly, [string]$Manifest = "")

# Rolls Steam Geometry Dash back to 2.2081 and puts Geode and every installed
# mod on their 2.2081 versions, so mods keep working until Geode supports the
# newest GD. Run with -Undo to go back to the newest version, or -GeodeOnly to
# only fix Geode and mods on a GD that's already on 2.2081.

$ToolVersion = "1.0.0"
$TargetGd = "2.2081"
$DefaultManifest = "3816559102876907245"
$AppId = 322170
$DepotId = 322171

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "geode-sync.ps1")

function Done($code) {
    Write-Host ""
    Read-Host "Press Enter to close" | Out-Null
    exit $code
}

function Find-Steam {
    $path = $null
    try { $path = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -Name SteamPath).SteamPath } catch { }
    if (-not $path) { $path = Join-Path ${env:ProgramFiles(x86)} "Steam" }
    return ($path -replace "/", "\")
}

function Find-Library($steam) {
    $libs = @($steam)
    $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"')) {
            $libs += ($m.Matches[0].Groups[1].Value -replace '\\\\', '\')
        }
    }
    foreach ($lib in $libs) {
        if (Test-Path (Join-Path $lib "steamapps\appmanifest_$AppId.acf")) { return $lib }
    }
    return $null
}

function Can-Write($dir) {
    try {
        $f = Join-Path $dir ".gd-downgrade-test"
        [IO.File]::WriteAllText($f, "x")
        Remove-Item $f -Force
        return $true
    } catch { return $false }
}

function Wait-GDClosed {
    while (Get-Process -Name "GeometryDash" -ErrorAction SilentlyContinue) {
        Say "Geometry Dash is open. Close it, then press Enter." Yellow
        Read-Host | Out-Null
    }
}

$script:logPos = 0
function Read-NewLog($log) {
    if (-not (Test-Path $log)) { return "" }
    $fs = [IO.File]::Open($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -lt $script:logPos) { $script:logPos = 0 }
        [void]$fs.Seek($script:logPos, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($fs)
        $text = $reader.ReadToEnd()
        $script:logPos = $fs.Length
        return $text
    } finally { $fs.Dispose() }
}

function Folder-Size($dir) {
    if (-not (Test-Path $dir)) { return 0 }
    $sum = (Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [int64]$sum } else { return 0 }
}

function New-BackupDir {
    $dir = Join-Path ([Environment]::GetFolderPath("Desktop")) ("GD downgrade backup " + (Get-Date -Format "yyyy-MM-dd HH-mm"))
    New-Item -ItemType Directory -Force $dir | Out-Null
    return $dir
}

# Geode problems never undo the GD part, so they're reported instead of thrown.
function Sync-GeodeSafely($gd, $target, $backup) {
    try {
        [void](Sync-Geode -GdDir $gd -TargetGd $target -BackupDir $backup)
        return $true
    } catch {
        Say ""
        Say "     Couldn't update Geode and your mods: $($_.Exception.Message)" Red
        Say "     Your mods are untouched. Check your internet, then run 'Fix Geode mods only.bat'." Red
        Say "     If it keeps failing, open an issue with a screenshot: https://github.com/dan2756/gd-downgrade/issues" Red
        return $false
    }
}

try {
    $steam = Find-Steam
    $lib = Find-Library $steam
    if (-not $lib) {
        Say "Couldn't find Geometry Dash in your Steam library. This only works for the Steam version." Red
        Done 10
    }
    $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
    $gd = Join-Path $lib "steamapps\common\Geometry Dash"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not ((Can-Write $gd) -and (Can-Write (Join-Path $steam "steamapps")))) {
        Say "Asking for permission to change the Geometry Dash folder..." Yellow
        $relaunch = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Undo) { $relaunch += " -Undo" }
        if ($GeodeOnly) { $relaunch += " -GeodeOnly" }
        if ($Manifest) { $relaunch += " -Manifest $Manifest" }
        Start-Process (Join-Path $PSHOME "powershell.exe") -Verb RunAs -ArgumentList $relaunch
        exit 0
    }

    if ($Undo) {
        Say "Putting Geometry Dash, Geode and your mods back on the newest versions" Cyan
        Say ""
        Wait-GDClosed
        $before = Get-ExeTimestamp (Join-Path $gd "GeometryDash.exe")
        Say "1/2  Letting Steam update GD again"
        Set-ItemProperty -LiteralPath $acf -Name IsReadOnly -Value $false
        Start-Process "steam://validate/$AppId"
        Say "     Steam is checking the game files and will update GD to the newest version." Yellow
        Say "     When Steam has finished (GD shows Play in your library), press Enter here." Yellow
        Read-Host | Out-Null
        Wait-GDClosed
        if ((Get-ExeTimestamp (Join-Path $gd "GeometryDash.exe")) -eq $before) {
            Say "     GD's files didn't change. If Steam is still working, wait for it and run this again." Yellow
        }

        Say "2/2  Updating Geode and your mods for the newest GD"
        $latest = Invoke-GeodeApi "/loader/versions/latest?platform=win"
        $newGd = $latest.gd.win
        $backup = New-BackupDir
        if (Sync-GeodeSafely $gd $newGd $backup) {
            Say ""
            Say "Done. GD, Geode and your mods are set up for GD $newGd." Green
            Say "If GD updated past $newGd, Geode doesn't support it yet and your mods won't load until it does."
        }
        Done 0
    }

    if ($GeodeOnly) {
        Say "Fixing Geode and your mods for GD $TargetGd" Cyan
        Say ""
        Wait-GDClosed
        if ((Get-ExeTimestamp (Join-Path $gd "GeometryDash.exe")) -ne $GD2081Timestamp) {
            Say "Your Geometry Dash doesn't look like $TargetGd." Yellow
            Say "Run 'Downgrade GD to 2.2081.bat' instead, which downgrades GD and fixes your mods." Yellow
            if ((Read-Host "Type Y to fix the mods for $TargetGd anyway") -ne "Y") { Done 10 }
        }
        $backup = New-BackupDir
        if (Sync-GeodeSafely $gd $TargetGd $backup) {
            Say ""
            Say "Done! Open GD from Steam like normal and your mods will load." Green
        }
        Done 0
    }

    Say "GD Downgrade v${ToolVersion}: rolls Geometry Dash, Geode and your mods back to $TargetGd" Cyan
    Say ""
    Say "Found GD in: $gd"
    Say "Your save, Geode and mods get backed up to your Desktop first."
    Say ""
    Read-Host "Press Enter to start" | Out-Null

    if (-not $Manifest) { $Manifest = $DefaultManifest }
    while ($Manifest -notmatch '^\d{10,25}$') {
        $Manifest = (Read-Host "Paste the $TargetGd manifest ID").Trim()
    }

    Wait-GDClosed

    $backup = New-BackupDir
    $save = Join-Path $env:LOCALAPPDATA "GeometryDash"
    if (Test-Path -LiteralPath $save) {
        Say "1/5  Backing up your save to: $backup"
        Copy-Item -LiteralPath $save -Destination (Join-Path $backup "save") -Recurse -Force
    } else {
        Say "1/5  No save folder found, skipping the backup" Yellow
    }

    $exe = Join-Path $gd "GeometryDash.exe"
    $alreadyThere = ($Manifest -eq $DefaultManifest) -and (Test-Path -LiteralPath $exe) -and ((Get-ExeTimestamp $exe) -eq $GD2081Timestamp)
    if ($alreadyThere) {
        Say "2/5  GD is already on $TargetGd, skipping the download" Green
        Say "3/5  Nothing to copy"
    } else {
        $depot = Join-Path $steam "steamapps\content\app_$AppId\depot_$DepotId"
        if (Test-Path -LiteralPath $depot) { Remove-Item -LiteralPath $depot -Recurse -Force }
        $log = Join-Path $steam "logs\content_log.txt"
        if (Test-Path $log) { $script:logPos = (Get-Item $log).Length }

        $command = "download_depot $AppId $DepotId $Manifest"
        Set-Clipboard -Value $command
        Start-Process "steam://open/console"
        Say ""
        Say "2/5  Steam's console just opened. Click the box at the bottom of it," Yellow
        Say "     press Ctrl+V and then Enter. (It pastes: $command)" Yellow
        Say "     Then come back here and wait. Don't close this window." Yellow
        Say ""

        $seen = ""
        $lastSize = -1
        $stableSince = $null
        $deadline = (Get-Date).AddMinutes(45)
        while ($true) {
            Start-Sleep -Seconds 2
            $seen += Read-NewLog $log
            if ($seen -match "Depot download failed[^\r\n]*") {
                Say ""
                Say "Steam couldn't download it: $($Matches[0])" Red
                Say "Check that the manifest ID is right and that you own GD on this Steam account." Red
                Done 10
            }
            $size = Folder-Size $depot
            if ($size -gt 0) { Write-Host -NoNewline ("`r     Downloading... {0:N0} MB   " -f ($size / 1MB)) }
            $complete = $seen -match "Depot download complete[^\r\n]*depot_$DepotId"
            if ($size -gt 0 -and $size -eq $lastSize -and (Test-Path (Join-Path $depot "GeometryDash.exe"))) {
                if (-not $stableSince) { $stableSince = Get-Date }
            } else { $stableSince = $null }
            $lastSize = $size
            if ($complete -or ($stableSince -and ((Get-Date) - $stableSince).TotalSeconds -ge 30)) { break }
            if ((Get-Date) -gt $deadline) {
                Say ""
                Say "This is taking too long. Make sure you pasted the command into Steam's console and pressed Enter, then run this again." Red
                Done 10
            }
        }
        Write-Host ""

        Wait-GDClosed
        Say "3/5  Copying the $TargetGd files into your GD folder"
        Copy-Item -Path (Join-Path $depot "*") -Destination $gd -Recurse -Force
        Remove-Item -LiteralPath $depot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Say "4/5  Stopping Steam from updating GD again"
    Set-ItemProperty -LiteralPath $acf -Name IsReadOnly -Value $true

    Say "5/5  Putting Geode and your mods on their $TargetGd versions"
    $geodeOk = Sync-GeodeSafely $gd $TargetGd $backup

    Say ""
    if ($geodeOk) {
        Say "Done! Geometry Dash, Geode and your mods are on $TargetGd. Open GD from Steam like normal." Green
    } else {
        Say "Geometry Dash is on $TargetGd, but Geode and your mods still need fixing (see above)." Yellow
    }
    Say "If Steam says it needs an update, open GeometryDash.exe in the GD folder instead (keep Steam open)."
    Say "When Geode supports the new GD version, run 'Undo GD downgrade.bat' to update everything again."
    Done 0
} catch {
    Say ""
    Say "Something went wrong: $($_.Exception.Message)" Red
    Say "Nothing in your save was deleted, and your mods are backed up on your Desktop." Red
    Say "Report it with a screenshot of this window: https://github.com/dan2756/gd-downgrade/issues" Red
    Done 10
}
