# geode-sync.ps1
# Makes the Geode loader and every installed Geode mod match one Geometry Dash
# version. Dot-sourced by gd-downgrade.ps1. Written for Windows PowerShell 5.1.

$GeodeApi = "https://api.geode-sdk.org/v1"
$GeodeHeaders = @{ "User-Agent" = "gd-downgrade" }
$LoaderFiles = @("Geode.dll", "Geode.pdb", "GeodeUpdater.exe", "XInput1_4.dll", "GeodeUninstaller.exe")

# PE header timestamp of the Steam 2.2081 GeometryDash.exe (depot manifest 3816559102876907245).
$GD2081Timestamp = 1768959392

Add-Type -AssemblyName System.IO.Compression.FileSystem
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"

function Say($text, $color = "White") { Write-Host $text -ForegroundColor $color }

function Get-ExeTimestamp($exe) {
    $fs = [IO.File]::OpenRead($exe)
    try {
        $buf = New-Object byte[] 4096
        [void]$fs.Read($buf, 0, $buf.Length)
        $pe = [BitConverter]::ToInt32($buf, 0x3C)
        return [BitConverter]::ToUInt32($buf, $pe + 8)
    } finally { $fs.Dispose() }
}

function Split-Version([string]$v) {
    $v = "$v".Trim().TrimStart("v")
    $parts = $v -split "-", 2
    $nums = @($parts[0] -split "\." | ForEach-Object { [int]("0" + ($_ -replace "[^\d]", "")) })
    while ($nums.Count -lt 3) { $nums += 0 }
    $pre = $null
    if ($parts.Count -gt 1 -and $parts[1]) { $pre = $parts[1] }
    return [pscustomobject]@{ Major = $nums[0]; Minor = $nums[1]; Patch = $nums[2]; Pre = $pre }
}

# Returns -1, 0 or 1, following semver rules (1.0.0-beta.2 < 1.0.0).
function Compare-Version([string]$a, [string]$b) {
    $x = Split-Version $a
    $y = Split-Version $b
    foreach ($k in "Major", "Minor", "Patch") {
        if ($x.$k -lt $y.$k) { return -1 }
        if ($x.$k -gt $y.$k) { return 1 }
    }
    if (-not $x.Pre -and -not $y.Pre) { return 0 }
    if (-not $x.Pre) { return 1 }
    if (-not $y.Pre) { return -1 }
    $xp = $x.Pre -split "\."
    $yp = $y.Pre -split "\."
    for ($i = 0; $i -lt [Math]::Max($xp.Count, $yp.Count); $i++) {
        if ($i -ge $xp.Count) { return -1 }
        if ($i -ge $yp.Count) { return 1 }
        $xn = 0; $yn = 0
        $xIsNum = [int]::TryParse($xp[$i], [ref]$xn)
        $yIsNum = [int]::TryParse($yp[$i], [ref]$yn)
        if ($xIsNum -and $yIsNum) {
            if ($xn -ne $yn) { return [Math]::Sign($xn - $yn) }
        } elseif ($xp[$i] -ne $yp[$i]) {
            return [Math]::Sign([string]::CompareOrdinal($xp[$i], $yp[$i]))
        }
    }
    return 0
}

# A mod loads when it targets this GD version (or any, "*") and was built
# against the same Geode major version, no newer than the installed loader.
function Test-ModFits($gd, $geode, $targetGd, $loaderVersion) {
    if ($gd -ne $targetGd -and $gd -ne "*") { return $false }
    if (-not $geode) { return $false }
    if ((Split-Version $geode).Major -ne (Split-Version $loaderVersion).Major) { return $false }
    return (Compare-Version $geode $loaderVersion) -le 0
}

function Get-WinGd($gd) {
    if ($gd -is [string]) { return $gd }
    if ($gd -and $gd.win) { return $gd.win }
    return $null
}

function Read-ModJson($file) {
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($file)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq "mod.json" } | Select-Object -First 1
            if (-not $entry) { return $null }
            $reader = New-Object IO.StreamReader($entry.Open())
            try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
        } finally { $zip.Dispose() }
    } catch { return $null }
}

function Get-RequiredDeps($json) {
    $deps = $json.dependencies
    $out = @()
    if (-not $deps) { return $out }
    if ($deps -is [array]) {
        foreach ($d in $deps) {
            $optional = ($d.importance -eq "recommended" -or $d.importance -eq "suggested" -or $d.required -eq $false)
            if (-not $optional -and $d.id) { $out += $d.id }
        }
    } else {
        foreach ($p in $deps.PSObject.Properties) {
            $v = $p.Value
            $optional = $false
            if ($v -isnot [string]) {
                $optional = ($v.importance -eq "recommended" -or $v.importance -eq "suggested" -or $v.required -eq $false)
            }
            if (-not $optional) { $out += $p.Name }
        }
    }
    return $out | Where-Object { $_ -ne "geode.loader" }
}

function Invoke-GeodeApi($path) {
    try {
        return (Invoke-RestMethod -Uri "$GeodeApi$path" -Headers $GeodeHeaders -UseBasicParsing).payload
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and [int]$resp.StatusCode -eq 404) { return $null }
        throw
    }
}

# Every accepted version of a mod on the Geode index, or $null if the index doesn't have the mod.
function Get-IndexVersions($id) {
    $all = @()
    $page = 1
    while ($true) {
        $payload = Invoke-GeodeApi "/mods/$id/versions?per_page=100&page=$page"
        if (-not $payload) { if ($page -eq 1) { return $null } else { break } }
        $data = @($payload.data)
        $all += $data
        if ($data.Count -eq 0 -or $all.Count -ge $payload.count) { break }
        $page++
    }
    return @($all | Where-Object { $_.status -eq "accepted" })
}

# Newest version that fits, preferring stable releases over betas.
function Find-FittingVersion($versions, $targetGd, $loaderVersion) {
    $fits = @($versions | Where-Object { Test-ModFits (Get-WinGd $_.gd) $_.geode $targetGd $loaderVersion })
    foreach ($pool in @(@($fits | Where-Object { -not (Split-Version $_.version).Pre }), $fits)) {
        $best = $null
        foreach ($v in $pool) {
            if (-not $best -or (Compare-Version $v.version $best.version) -gt 0) { $best = $v }
        }
        if ($best) { return $best }
    }
    return $null
}

function Save-Verified($url, $hash, $dest) {
    Invoke-WebRequest -Uri $url -OutFile $dest -Headers $GeodeHeaders -UseBasicParsing
    # .NET directly: Get-FileHash goes missing when PowerShell 7's module path leaks into 5.1.
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($dest)
    try { $actual = -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString("x2") }) } finally { $fs.Dispose(); $sha.Dispose() }
    if ($actual -ne "$hash".ToLower()) {
        Remove-Item -LiteralPath $dest -Force
        throw "Download of $url didn't match its published hash"
    }
}

function Expand-Zip($zipFile, $destDir, [string[]]$skipExtensions = @()) {
    $zip = [IO.Compression.ZipFile]::OpenRead($zipFile)
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName.EndsWith("/")) { continue }
            if ($skipExtensions -contains [IO.Path]::GetExtension($e.Name)) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $destDir ($e.FullName -replace "/", "\")))
            if (-not $target.StartsWith([IO.Path]::GetFullPath($destDir).TrimEnd("\") + "\")) {
                throw "Refusing to extract '$($e.FullName)' outside $destDir"
            }
            $parent = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $zip.Dispose() }
}

function Get-LoaderVersion($gdDir) {
    $dll = Join-Path $gdDir "Geode.dll"
    if (-not (Test-Path -LiteralPath $dll)) { return $null }
    $v = (Get-Item -LiteralPath $dll).VersionInfo.FileVersion
    if (-not $v) { return "unknown" }
    $n = @($v -split "[,.]" | ForEach-Object { $_.Trim() })
    return "$($n[0]).$($n[1]).$($n[2])"
}

function Test-ModId($id) { return ("$id" -match '^[A-Za-z0-9_\-]+\.[A-Za-z0-9_.\-]+$') }

function Clear-ModCache($unzippedDir, $id) {
    if (-not (Test-ModId $id)) { return }
    $cache = Join-Path $unzippedDir $id
    if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force }
}

# Mods that don't fit the current GD are parked (geode\parked-mods), never deleted,
# so switching GD back restores the exact versions, including mods not on the index.
function Park-Mod($file, $json, $parkedDir) {
    if (-not (Test-ModId $json.id)) { throw "Unexpected mod id '$($json.id)' in $file" }
    New-Item -ItemType Directory -Force -Path $parkedDir | Out-Null
    $ver = ("$($json.version)".TrimStart("v")) -replace "[^\w.+-]", "_"
    Move-Item -LiteralPath $file -Destination (Join-Path $parkedDir "$($json.id)@$ver.geode") -Force
}

function Get-ParkedMods($parkedDir) {
    if (-not (Test-Path -LiteralPath $parkedDir)) { return }
    foreach ($f in Get-ChildItem -LiteralPath $parkedDir -Filter *.geode) {
        $j = Read-ModJson $f.FullName
        if ($j) { [pscustomobject]@{ mod_id = $j.id; version = $j.version; gd = $j.gd; geode = $j.geode; Path = $f.FullName } }
    }
}

# Best version of a mod for this GD: a parked copy first, then the Geode index.
function Get-FittingMod($id, $parkedDir, $targetGd, $loaderVersion) {
    $parked = @(Get-ParkedMods $parkedDir | Where-Object { $_.mod_id -eq $id })
    $pick = Find-FittingVersion $parked $targetGd $loaderVersion
    if ($pick) { return $pick }
    $versions = Get-IndexVersions $id
    if ($versions) { return Find-FittingVersion $versions $targetGd $loaderVersion }
    return $null
}

# Puts $pick into the mods folder. The download happens before the old file is
# parked, so a failed download leaves the old mod where it was.
function Install-Mod($pick, $modsDir, $unzippedDir, $tmp, $parkedDir, $oldFile, $oldJson) {
    if (-not (Test-ModId $pick.mod_id)) { throw "Unexpected mod id '$($pick.mod_id)'" }
    $src = $pick.Path
    if (-not $src) {
        $src = Join-Path $tmp "$($pick.mod_id).geode"
        Save-Verified $pick.download_link $pick.hash $src
    }
    if ($oldFile) { Park-Mod $oldFile $oldJson $parkedDir }
    Move-Item -LiteralPath $src -Destination (Join-Path $modsDir "$($pick.mod_id).geode") -Force
    Clear-ModCache $unzippedDir $pick.mod_id
}

function Get-ModList($modsDir) {
    foreach ($f in Get-ChildItem -LiteralPath $modsDir -Filter *.geode) {
        $j = Read-ModJson $f.FullName
        if ($j) { [pscustomobject]@{ File = $f.FullName; Json = $j } }
        else { Say "     Skipping $($f.Name): couldn't read it" Yellow }
    }
}

function Write-ModReport($title, $items, $color) {
    if (-not $items.Count) { return }
    Say "     $title" $color
    $items | ForEach-Object { Say "       $_" }
}

# Main entry point. Returns $true when Geode was found and synced.
function Sync-Geode {
    param([string]$GdDir, [string]$TargetGd, [string]$BackupDir)

    $current = Get-LoaderVersion $GdDir
    if (-not $current) {
        Say "     Geode isn't installed, nothing to do for mods."
        return $false
    }

    $geodeDir = Join-Path $GdDir "geode"
    $modsDir = Join-Path $geodeDir "mods"
    $parkedDir = Join-Path $geodeDir "parked-mods"
    $unzippedDir = Join-Path $geodeDir "unzipped"
    # Not %TEMP%: it can be an 8.3 short path (C:\Users\AB'CD~1) that PowerShell 5.1 can't delete from.
    $tmp = Join-Path $BackupDir "_downloads"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    try {
        $loader = Invoke-GeodeApi "/loader/versions/latest?gd=$TargetGd&platform=win"
        if (-not $loader) { throw "Geode has no release for GD $TargetGd yet" }

        Say "     Backing up Geode and your mods to: $BackupDir"
        $bkLoader = Join-Path $BackupDir "geode-loader"
        New-Item -ItemType Directory -Force -Path $bkLoader | Out-Null
        foreach ($f in $LoaderFiles) {
            $src = Join-Path $GdDir $f
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src $bkLoader -Force }
        }
        foreach ($sub in "mods", "config") {
            $src = Join-Path $geodeDir $sub
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src (Join-Path $BackupDir "geode-$sub") -Recurse -Force }
        }

        if ($current -ne $loader.version) {
            Say "     Installing Geode v$($loader.version) (was v$current)"
            $zip = Join-Path $tmp "geode-win.zip"
            $res = Join-Path $tmp "resources.zip"
            Save-Verified $loader.downloads.win.url $loader.downloads.win.hash $zip
            Save-Verified $loader.downloads.resources.url $loader.downloads.resources.hash $res
            Expand-Zip $zip $GdDir @(".lib")
            $resDir = Join-Path $geodeDir "resources\geode.loader"
            if (Test-Path -LiteralPath $resDir) { Remove-Item -LiteralPath $resDir -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $resDir | Out-Null
            Expand-Zip $res $resDir
        } else {
            Say "     Geode v$current already matches GD $TargetGd"
        }
        $loaderVersion = $loader.version

        New-Item -ItemType Directory -Force -Path $modsDir | Out-Null
        $changed = @(); $parked = @(); $restored = @(); $added = @(); $fine = 0

        foreach ($m in @(Get-ModList $modsDir)) {
            $json = $m.Json
            if (Test-ModFits (Get-WinGd $json.gd) $json.geode $TargetGd $loaderVersion) { $fine++; continue }
            $pick = Get-FittingMod $json.id $parkedDir $TargetGd $loaderVersion
            if ($pick) {
                Install-Mod $pick $modsDir $unzippedDir $tmp $parkedDir $m.File $json
                $changed += "$($json.id)  $($json.version) -> $($pick.version)"
            } else {
                Park-Mod $m.File $json $parkedDir
                Clear-ModCache $unzippedDir $json.id
                $parked += $json.id
            }
        }

        # Bring back parked mods that fit this GD and aren't installed.
        $present = @{}
        foreach ($m in @(Get-ModList $modsDir)) { $present[$m.Json.id] = $true }
        foreach ($id in @(Get-ParkedMods $parkedDir | ForEach-Object { $_.mod_id } | Sort-Object -Unique)) {
            if ($present[$id]) { continue }
            $pick = Find-FittingVersion @(Get-ParkedMods $parkedDir | Where-Object { $_.mod_id -eq $id }) $TargetGd $loaderVersion
            if ($pick) {
                Install-Mod $pick $modsDir $unzippedDir $tmp $parkedDir $null $null
                $restored += "$id  $($pick.version)"
            }
        }

        # Pull in required dependencies that aren't installed.
        $noFit = @()
        for ($pass = 0; $pass -lt 5; $pass++) {
            $present = @{}
            $needs = @{}
            foreach ($m in @(Get-ModList $modsDir)) {
                $present[$m.Json.id] = $true
                foreach ($dep in Get-RequiredDeps $m.Json) { if (-not $needs[$dep]) { $needs[$dep] = $m.Json.id } }
            }
            $missing = @($needs.Keys | Where-Object { -not $present[$_] -and $noFit -notcontains $_ })
            if ($missing.Count -eq 0) { break }
            foreach ($id in $missing) {
                $pick = Get-FittingMod $id $parkedDir $TargetGd $loaderVersion
                if ($pick) {
                    Install-Mod $pick $modsDir $unzippedDir $tmp $parkedDir $null $null
                    $added += "$id  $($pick.version)  (needed by $($needs[$id]))"
                } else {
                    $noFit += $id
                    Say "     $($needs[$id]) needs $id, which has no version for GD $TargetGd" Yellow
                }
            }
        }

        Say "     $fine mods were already fine."
        Write-ModReport "Switched $($changed.Count) mods to their GD $TargetGd versions:" $changed Green
        Write-ModReport "Brought back $($restored.Count) mods you had before:" $restored Green
        Write-ModReport "Installed $($added.Count) missing dependencies:" $added Green
        Write-ModReport "Set aside $($parked.Count) mods that have no GD $TargetGd version (in geode\parked-mods, they come back when you switch GD back):" $parked Yellow
        if ($parked -contains "absolllute.megahack") {
            Say "       Mega Hack is a paid mod that isn't on the Geode index. Reinstall it for GD $TargetGd with its own installer." Yellow
        }
        return $true
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

