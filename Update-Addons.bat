<# : batch part (Windows runs this first; the rest is PowerShell)
@echo off
title Family addons updater
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = Get-Content -LiteralPath '%~f0' -Raw; Invoke-Expression $s"
if errorlevel 1 pause
exit /b
#>

# ---------------------------------------------------------------------------
#  Family addons updater for World of Warcraft "_forever_"
#  Made for the Family, by Claude and EonJoe.
#
#  Downloads the newest addons from
#    https://github.com/ATHOMEAPPS/wow-forever-addons
#  and updates the ones in your _forever_\Interface\AddOns folder.
#  It never touches your saved settings or history (the WTF folder), except to
#  carry GoldLedger's history over to Ledger once.
#  Replaced folders are kept in %LOCALAPPDATA%\ForeverAddonsUpdater\backup.
#
#  Questions: just pressing Enter means YES. An addon you say no to is
#  remembered and not asked again; at the end you can type A to add it after all.
#
#  For testing only: FA_SOURCE = a local zip instead of GitHub,
#  FA_ADDONS = another AddOns folder, FA_YES = 1 answers every question with Enter,
#  FA_ANSWERS = answers to use in order, separated by commas (empty = Enter).
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$RepoZip   = 'https://github.com/ATHOMEAPPS/wow-forever-addons/archive/refs/heads/main.zip'
$Renamed   = @{ 'GoldLedger' = 'Ledger' }      # old folder -> new folder
$SavedVarRename = @{ 'GoldLedger' = @('GoldLedgerDB', 'LedgerDB') }
$Home2     = Join-Path $env:LOCALAPPDATA 'ForeverAddonsUpdater'
$PathFile  = Join-Path $Home2 'addons-folder.txt'
$SkipFile  = Join-Path $Home2 'not-wanted.txt'   # addons the player said no to
$script:Answers = $null
if ($env:FA_ANSWERS -ne $null) { $script:Answers = [System.Collections.Queue]::new([string[]]($env:FA_ANSWERS -split ',')) }

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

function Read-Answer($prompt) {
    if ($script:Answers) {
        $a = ''
        if ($script:Answers.Count -gt 0) { $a = $script:Answers.Dequeue() }
        Say "${prompt}: $a"
        return $a
    }
    if ($env:FA_YES -eq '1') { Say "${prompt}:"; return '' }
    return Read-Host $prompt
}

# Enter (or y) = yes, n = no
function Ask($question) {
    $a = Read-Answer "$question [Enter = yes, n = no]"
    return -not ($a -match '^\s*[nN]')
}

function Get-NotWanted {
    if (Test-Path -LiteralPath $SkipFile) { return @(Get-Content -LiteralPath $SkipFile | Where-Object { $_.Trim() -ne '' }) }
    return @()
}

function Set-NotWanted($names) {
    New-Item -ItemType Directory -Force -Path $Home2 | Out-Null
    Set-Content -LiteralPath $SkipFile -Value ($names | Sort-Object -Unique)
}

function Get-TocVersion($tocPath) {
    if (-not (Test-Path -LiteralPath $tocPath)) { return $null }
    $line = Select-String -LiteralPath $tocPath -Pattern '^##\s*Version:\s*([0-9][0-9.]*)' | Select-Object -First 1
    if ($line) { return $line.Matches[0].Groups[1].Value }
    return $null
}

function ConvertTo-Version($text) {
    if (-not $text) { return [version]'0.0' }
    $parts = @($text.Trim('.').Split('.') | Where-Object { $_ -ne '' })
    while ($parts.Count -lt 2) { $parts += '0' }
    return [version]($parts[0..([Math]::Min(3, $parts.Count - 1))] -join '.')
}

Say ''
Say '  Family addons updater (WoW Forever)' Cyan
Say '  Made for the Family, by Claude and EonJoe.' DarkGray
Say ''

try {
    # --- 1. find the AddOns folder ------------------------------------------
    $addons = $env:FA_ADDONS
    if (-not $addons -and (Test-Path -LiteralPath $PathFile)) {
        $saved = (Get-Content -LiteralPath $PathFile -Raw).Trim()
        if (Test-Path -LiteralPath $saved) { $addons = $saved }
    }
    if (-not $addons) {
        $guesses = @(
            (Join-Path ${env:ProgramFiles(x86)} 'World of Warcraft\_forever_\Interface\AddOns'),
            (Join-Path $env:ProgramFiles 'World of Warcraft\_forever_\Interface\AddOns')
        )
        try {
            $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft' -ErrorAction Stop
            if ($reg.InstallPath) {
                $root = Split-Path ($reg.InstallPath.TrimEnd('\')) -Parent
                $guesses += (Join-Path $root '_forever_\Interface\AddOns')
            }
        } catch { }
        foreach ($g in $guesses) {
            if ($g -and (Test-Path -LiteralPath (Split-Path $g -Parent))) { $addons = $g; break }
        }
    }
    if (-not $addons) {
        Say 'I could not find World of Warcraft _forever_.' Yellow
        Say 'A window will open: pick the "_forever_" folder inside your World of Warcraft folder.' Yellow
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Pick the _forever_ folder inside World of Warcraft'
        if ($dlg.ShowDialog() -ne 'OK') { throw 'No folder picked.' }
        $picked = $dlg.SelectedPath
        if ((Split-Path $picked -Leaf) -eq 'AddOns') { $addons = $picked }
        elseif ((Split-Path $picked -Leaf) -eq 'Interface') { $addons = Join-Path $picked 'AddOns' }
        else { $addons = Join-Path $picked 'Interface\AddOns' }
        if (-not (Test-Path -LiteralPath (Join-Path $addons '..\..\Wow.exe'))) {
            throw "That doesn't look like the _forever_ folder (no Wow.exe in it): $picked"
        }
    }
    if (-not $env:FA_ADDONS) {
        New-Item -ItemType Directory -Force -Path $Home2 | Out-Null
        Set-Content -LiteralPath $PathFile -Value $addons
    }
    if (-not (Test-Path -LiteralPath $addons)) { New-Item -ItemType Directory -Force -Path $addons | Out-Null }
    $addons = (Resolve-Path -LiteralPath $addons).Path
    $forever = Split-Path (Split-Path $addons -Parent) -Parent
    Say "AddOns folder: $addons"

    # --- 2. WoW must be closed ----------------------------------------------
    if (-not $env:FA_ADDONS) {
        $running = Get-Process -Name 'Wow' -ErrorAction SilentlyContinue | Where-Object {
            -not $_.Path -or $_.Path.StartsWith($forever, [StringComparison]::OrdinalIgnoreCase)
        }
        if ($running) { throw 'World of Warcraft is running. Please close it (log out and exit), then run this again.' }
    }

    # --- 3. download ---------------------------------------------------------
    $work = Join-Path $Home2 'download'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $zip = Join-Path $work 'addons.zip'
    if ($env:FA_SOURCE) {
        Copy-Item -LiteralPath $env:FA_SOURCE -Destination $zip
        Say "Using test file $($env:FA_SOURCE)" DarkGray
    } else {
        Say 'Downloading the newest addons from GitHub...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $RepoZip -OutFile $zip
        } catch {
            throw "Could not download from GitHub. Check your internet connection and run this again. ($($_.Exception.Message))"
        }
    }
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x') -Force
    } catch {
        throw 'The download was broken or incomplete. Check your internet connection and run this again.'
    }

    # every addon in the download: <repo>\<Addon>\<Addon>\<Addon>.toc
    $available = @{}
    Get-ChildItem -LiteralPath (Join-Path $work 'x') -Directory | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object {
            $inner = Join-Path $_.FullName $_.Name
            $toc = Join-Path $inner ($_.Name + '.toc')
            if (Test-Path -LiteralPath $toc) {
                $available[$_.Name] = @{ Folder = $inner; Version = (Get-TocVersion $toc) }
            }
        }
    }
    if ($available.Count -eq 0) { throw 'The download had no addons in it. Try again later.' }

    # --- 4. update -----------------------------------------------------------
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $backup = Join-Path $Home2 "backup\$stamp"
    $summary = New-Object System.Collections.Generic.List[string]
    $handled = @{}

    function Backup-Folder($path) {
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        Copy-Item -LiteralPath $path -Destination $backup -Recurse -Force
    }

    function Install-Addon($name) {
        $target = Join-Path $addons $name
        if (Test-Path -LiteralPath $target) {
            Backup-Folder $target
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        Copy-Item -LiteralPath $available[$name].Folder -Destination $target -Recurse -Force
    }

    # renamed addons (GoldLedger -> Ledger): history comes along, old folder goes
    foreach ($old in $Renamed.Keys) {
        $new = $Renamed[$old]
        $oldPath = Join-Path $addons $old
        if ((Test-Path -LiteralPath $oldPath) -and $available.ContainsKey($new)) {
            Say ''
            Say "$old is now called $new." Yellow
            $vars = $SavedVarRename[$old]
            Get-ChildItem -LiteralPath (Join-Path $forever 'WTF\Account') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $sv = Join-Path $_.FullName 'SavedVariables'
                $oldFile = Join-Path $sv "$old.lua"
                $newFile = Join-Path $sv "$new.lua"
                if ((Test-Path -LiteralPath $oldFile) -and -not (Test-Path -LiteralPath $newFile)) {
                    $text = [IO.File]::ReadAllText($oldFile)
                    $text = [regex]::Replace($text, '(?m)^' + [regex]::Escape($vars[0]) + ' = \{', $vars[1] + ' = {')
                    [IO.File]::WriteAllText($newFile, $text, (New-Object Text.UTF8Encoding($false)))
                    Say "  history copied to $new ($($_.Name))" Green
                }
            }
            Backup-Folder $oldPath
            Remove-Item -LiteralPath $oldPath -Recurse -Force
            $haveNew = Get-TocVersion (Join-Path $addons "$new\$new.toc")
            if ((ConvertTo-Version $available[$new].Version) -gt (ConvertTo-Version $haveNew)) {
                Install-Addon $new
            }
            $handled[$new] = $true
            $summary.Add("$old is now $new $(Get-TocVersion (Join-Path $addons "$new\$new.toc")) (old folder removed)")
        }
    }

    $installedNow = @($available.Keys | Where-Object { Test-Path -LiteralPath (Join-Path $addons $_) })
    $firstTime = $installedNow.Count -eq 0
    $notWanted = @(Get-NotWanted)
    $skipped = New-Object System.Collections.Generic.List[string]

    foreach ($name in ($available.Keys | Sort-Object)) {
        if ($handled[$name]) { continue }   # done above (renamed)
        $newVer = $available[$name].Version
        $target = Join-Path $addons $name
        $haveVer = Get-TocVersion (Join-Path $target "$name.toc")
        if (-not (Test-Path -LiteralPath $target)) {
            if ($notWanted -contains $name) {
                $skipped.Add($name)          # said no before: don't ask again
                continue
            }
            if ($firstTime) { $q = "Install $name $($newVer)?" } else { $q = "New addon available: $name $($newVer). Install it?" }
            if (Ask $q) {
                Install-Addon $name
                $summary.Add("$name $newVer installed")
            } else {
                $notWanted += $name
                Set-NotWanted $notWanted
                $skipped.Add($name)
            }
        } elseif ((ConvertTo-Version $newVer) -gt (ConvertTo-Version $haveVer)) {
            Install-Addon $name
            $summary.Add("$name $haveVer -> $newVer updated")
        } elseif ((ConvertTo-Version $newVer) -lt (ConvertTo-Version $haveVer)) {
            $summary.Add("$name $haveVer kept (newer than GitHub's $newVer)")
        } else {
            $summary.Add("$name $haveVer already up to date")
        }
    }

    Say ''
    Say 'Done:' Cyan
    foreach ($line in $summary) {
        if ($line -match 'updated|installed') { Say "  $line" Green } else { Say "  $line" }
    }
    foreach ($name in $skipped) { Say "  $name not installed (you said no; you won't be asked again)" DarkGray }
    if (Test-Path -LiteralPath $backup) { Say "Old versions were saved in $backup" DarkGray }
    Say ''
    Say 'Start WoW. New addons are on by default (check the AddOns button at character select).'

    # changed your mind? one key adds the skipped addons
    if ($skipped.Count -gt 0) {
        Say ''
        $a = Read-Answer "Press Enter to close, or type A and press Enter to add: $($skipped -join ', ')"
        if ($a -match '^\s*[aA]') {
            foreach ($name in $skipped) {
                Install-Addon $name
                Say "  $name $($available[$name].Version) installed" Green
            }
            Set-NotWanted @($notWanted | Where-Object { $skipped -notcontains $_ })
        }
        $script:closed = $true
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Say ''
    Say "Something went wrong: $($_.Exception.Message)" Red
    Say 'Nothing was changed unless it says so above. Send a screenshot of this window to EonJoe.' Yellow
}
if (-not $script:closed) {
    Say ''
    [void](Read-Answer 'Press Enter to close')
}
