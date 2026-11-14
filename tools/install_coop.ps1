<#
Savage Wind with the BotW co-op mod, on Windows: the setup window and the updater.

  "Install BotW Co-op.cmd"   a window asks for your base game, its 1.9.0 update and your keys (filled in when Ryujinx
                             or an earlier run has them) and your co-op settings, then everything is installed and built
  "Update BotW Co-op.cmd"    a window shows what's installed and what's newest on GitHub, then updates the co-op mod
                             (and, ticked, this Savage Wind source) and builds again
  install-coop.cmd <base game> <1.9.0 update>   the same install without a window (the files given on the line)

The work, in a console window that stays open:
  1. the build tools, if they aren't there yet (tools\setup_windows.ps1: MSYS2 and Python 3.12)
  2. your keys, put where the co-op setup reads them (%USERPROFILE%\.switch)
  3. the newest co-op mod release from https://github.com/Jaiden56YT/botw-coop, into coop\package
  4. its setup: your dump read into extracted\ (once), the mod's game files built and put in, Savage Wind built
  5. your co-op settings written into coop\romfs\botw-coop\config.ini, a desktop shortcut if you asked for one

Options: -Update (the updater), -BaseGame / -GameUpdate (no window), -Snapshot <png> (draws the window into a picture
and stops without doing anything: for checking the window on a machine without a person).
#>
param(
    [Parameter(Position = 0)][string]$BaseGame,
    [Parameter(Position = 1)][string]$GameUpdate,
    [switch]$Update,
    [string]$Snapshot
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Repo = 'Jaiden56YT/SavageWindRecomp'
$Branch = 'coop-mods'
$ModRepo = 'Jaiden56YT/botw-coop'
$ModAsset = 'botw-coop-windows-x64.zip'
$Title = 'BotW Co-op for Savage Wind'
$CoopDir = Join-Path $Root 'coop'
$Config = Join-Path $CoopDir 'romfs\botw-coop\config.ini'
$Answers = Join-Path $CoopDir 'install.ini'
$ExeFs = Join-Path $Root 'extracted\exefs'
$RomFs = Join-Path $Root 'extracted\romfs'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

function Write-Step { param([string]$Text) Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Info { param([string]$Text) Write-Host "   $Text" }
function Write-Warn { param([string]$Text) Write-Host "   $Text" -ForegroundColor Yellow }
function Stop-Setup {
    param([string]$Text)
    Write-Host ''
    Write-Host "Setup stopped: $Text" -ForegroundColor Red
    exit 1
}

# ---- what is here already --------------------------------------------------------------------------------------
function Test-GameExtracted {
    (Test-Path -LiteralPath (Join-Path $ExeFs 'main')) -and (Test-Path -LiteralPath (Join-Path $RomFs 'Pack\Bootup.pack'))
}
function Test-BuildTools {
    (Test-Path -LiteralPath 'C:\msys64\usr\bin\bash.exe') -and (Test-Path -LiteralPath (Join-Path $Root 'tools\venv\Scripts\python.exe'))
}
function Read-Ini {
    <# key = value lines (# comments) of a file, as a hashtable; empty if it isn't there #>
    param([string]$Path)
    $out = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $out[$Matches[1]] = $Matches[2] }
        }
    }
    return $out
}
function Get-InstalledVersion {
    $f = Join-Path $CoopDir 'installed_version.txt'
    if (Test-Path -LiteralPath $f) { return ([IO.File]::ReadAllText($f)).Trim() }
    return ''
}
function Get-SourceCommit {
    <# The commit of this Savage Wind source: git's, else the one the updater recorded #>
    $git = Get-Git
    if ($git -and (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        $c = & $git -C $Root rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $c) { return $c.Trim() }
    }
    $f = Join-Path $CoopDir 'source_commit.txt'
    if (Test-Path -LiteralPath $f) { return ([IO.File]::ReadAllText($f)).Trim() }
    return ''
}
function Get-Git {
    $g = Get-Command git -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

# ---- finding the game and the keys ---------------------------------------------------------------------------
function Get-KeyCandidates {
    @(
        (Join-Path $env:USERPROFILE '.switch\prod.keys'),
        (Join-Path $env:APPDATA 'Ryujinx\system\prod.keys'),
        (Join-Path $env:APPDATA 'yuzu\keys\prod.keys'),
        (Join-Path $env:APPDATA 'suyu\keys\prod.keys'),
        (Join-Path $env:APPDATA 'sudachi\keys\prod.keys'),
        (Join-Path $env:APPDATA 'citron\keys\prod.keys'),
        (Join-Path $env:APPDATA 'eden\keys\prod.keys')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
}
function Get-GameFolders {
    <# Ryujinx's game folders (Config.json game_dirs), then the usual places #>
    $dirs = @()
    $cfg = Join-Path $env:APPDATA 'Ryujinx\Config.json'
    if (Test-Path -LiteralPath $cfg) {
        try { $dirs += @((Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).game_dirs) } catch { }
    }
    $dirs += @((Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'Documents'))
    return @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)
}
function Find-GameFiles {
    <# @{Base; Update}: BotW's base game (title 01007EF00011E000) and update (...E800) files in those folders and one
       level below. By the title id in the name, else by the name and size. #>
    $found = @{ Base = $null; Update = $null }
    $files = @()
    foreach ($d in Get-GameFolders) {
        $files += @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.nsp', '.xci' })
        foreach ($sub in @(Get-ChildItem -LiteralPath $d -Directory -ErrorAction SilentlyContinue | Select-Object -First 200)) {
            $files += @(Get-ChildItem -LiteralPath $sub.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.nsp', '.xci' })
        }
    }
    foreach ($f in $files) {
        $n = $f.Name
        if (-not $found.Base -and ($n -match '01007EF00011E000' -or ($n -match 'Breath of the Wild' -and $n -notmatch 'Update|v1114112|DLC|01007EF00011F' -and $f.Length -gt 10GB))) { $found.Base = $f.FullName }
        if (-not $found.Update -and ($n -match '01007EF00011E800' -or ($n -match 'Breath of the Wild' -and $n -match 'Update|v1114112' -and $n -match '1\.9|v1114112'))) { $found.Update = $f.FullName }
    }
    return $found
}

# ---- checking what was chosen ----------------------------------------------------------------------------------
function Format-Size { param([long]$Bytes) if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) } else { '{0:N0} MB' -f ($Bytes / 1MB) } }
function Test-BaseFile {
    param([string]$Path)
    if (-not $Path) {
        if (Test-GameExtracted) { return @{ Ok = $true; Text = "Not needed: the game's files are already set up in extracted\." } }
        return @{ Ok = $false; Text = 'Choose your Breath of the Wild game file (.nsp or .xci).' }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Ok = $false; Text = 'There is no file here.' } }
    $f = Get-Item -LiteralPath $Path
    if ($f.Extension -notin '.nsp', '.xci') { return @{ Ok = $false; Text = 'This is not an .nsp or .xci file.' } }
    if ($f.Length -lt 5GB) { return @{ Ok = $false; Text = "Only $(Format-Size $f.Length): the base game is about 13.5 GB. Is this the update?" } }
    return @{ Ok = $true; Text = "$(Format-Size $f.Length). Read once into extracted\ (about 15 GB of free space needed)." }
}
function Test-UpdateFile {
    param([string]$Path, [string]$BasePath)
    if (-not $Path) {
        if (Test-GameExtracted) { return @{ Ok = $true; Text = 'Not needed: the game is already set up.' } }
        return @{ Ok = $false; Text = 'Choose your 1.9.0 update file (.nsp).' }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Ok = $false; Text = 'There is no file here.' } }
    $f = Get-Item -LiteralPath $Path
    if ($f.Extension -ne '.nsp') { return @{ Ok = $false; Text = 'The update is an .nsp file.' } }
    if ($BasePath -and $Path -eq $BasePath) { return @{ Ok = $false; Text = 'This is the same file as the base game.' } }
    if ($f.Length -gt 5GB) { return @{ Ok = $false; Text = "$(Format-Size $f.Length): too big for the update. Is this the base game?" } }
    $note = if ($f.Name -match '1\.9\.0|v1114112|01007EF00011E800') { 'looks like the 1.9.0 update' } else { 'the version is checked when it is read' }
    return @{ Ok = $true; Text = "$(Format-Size $f.Length), $note." }
}
function Test-KeysFile {
    param([string]$Path)
    if (-not $Path) {
        if (Test-GameExtracted) { return @{ Ok = $true; Text = 'Not needed: the game is already set up.' } }
        return @{ Ok = $false; Text = 'Choose the prod.keys dumped from your own Switch (the same file Ryujinx asks for).' }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Ok = $false; Text = 'There is no file here.' } }
    $text = [IO.File]::ReadAllText($Path)
    if ($text -notmatch '(?m)^\s*header_key\s*=') { return @{ Ok = $false; Text = 'This file has no header_key line: it is not a prod.keys.' } }
    $title = Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Path) 'title.keys')
    $t = if ($title) { 'prod.keys, with title.keys beside it.' } else { 'prod.keys.' }
    return @{ Ok = $true; Text = $t }
}

# ---- the windows --------------------------------------------------------------------------------------------------
function New-Form {
    param([string]$Text, [int]$Width, [int]$Height)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text = $Text
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $form.ClientSize = New-Object Drawing.Size($Width, $Height)
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = New-Object Drawing.Font('Segoe UI', 9.75)
    $ico = Join-Path $Root 'docs\icon\icon.ico'
    if (Test-Path -LiteralPath $ico) { try { $form.Icon = New-Object Drawing.Icon($ico) } catch { } }
    return $form
}
function Add-Label {
    param($Form, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [switch]$Bold)
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object Drawing.Point($X, $Y)
    $l.Size = New-Object Drawing.Size($W, $H)
    if ($Bold) { $l.Font = New-Object Drawing.Font('Segoe UI', 9.75, [Drawing.FontStyle]::Bold) }
    $Form.Controls.Add($l)
    return $l
}
function Add-Button {
    param($Form, [string]$Text, [int]$X, [int]$Y, [int]$W)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Size = New-Object Drawing.Size($W, 32)
    $Form.Controls.Add($b)
    return $b
}
function Save-Snapshot {
    <# -Snapshot: once the window is up, draw it into the picture and close it (as Cancel) #>
    param($Form)
    if (-not $Snapshot) { return }
    $path = $Snapshot  # (a closure sees the function's variables, not the script's)
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 1500
    $timer.Add_Tick({
        $timer.Stop()
        $bmp = New-Object Drawing.Bitmap($Form.Width, $Form.Height)
        $Form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $Form.Width, $Form.Height)))
        $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        $Form.DialogResult = [Windows.Forms.DialogResult]::Cancel
        $Form.Close()
    }.GetNewClosure())
    $timer.Start()
}

function Show-InstallWindow {
    <# @{BaseGame; GameUpdate; Keys; Name; Server; Port; Password; Shortcut}, or $null if cancelled #>
    param([hashtable]$Start)
    $form = New-Form "$Title - setup" 760 650
    Add-Label $form ("Savage Wind is built on this PC from your own copy of the game, with the co-op mod in it. Choose your files " +
        "(what was found on this PC is filled in); the line under each says what was found.") 16 12 728 40 | Out-Null

    $rows = @{}
    $y = 60
    foreach ($spec in @(
        @{ Key = 'BaseGame'; Title = 'Base game'; Hint = 'Breath of the Wild, .nsp or .xci (about 13.5 GB)'; Filter = 'Switch game (*.nsp;*.xci)|*.nsp;*.xci|All files (*.*)|*.*' },
        @{ Key = 'GameUpdate'; Title = '1.9.0 update'; Hint = 'the update file, .nsp'; Filter = 'Switch update (*.nsp)|*.nsp|All files (*.*)|*.*' },
        @{ Key = 'Keys'; Title = 'Keys'; Hint = 'prod.keys from your own Switch (title.keys beside it is used too)'; Filter = 'Keys (prod.keys)|prod.keys;*.keys|All files (*.*)|*.*' }
    )) {
        Add-Label $form "$($spec.Title):  $($spec.Hint)" 16 $y 728 20 -Bold | Out-Null
        $box = New-Object Windows.Forms.TextBox
        $box.Location = New-Object Drawing.Point(16, ($y + 24))
        $box.Size = New-Object Drawing.Size(620, 26)
        $box.Text = [string]$Start[$spec.Key]
        $form.Controls.Add($box)
        $browse = Add-Button $form 'Browse...' 644 ($y + 22) 100
        $status = Add-Label $form '' 16 ($y + 54) 728 22
        $status.ForeColor = [Drawing.Color]::DimGray
        $rows[$spec.Key] = @{ Box = $box; Status = $status; Browse = $browse; Filter = $spec.Filter; Title = $spec.Title }
        $y += 84
    }

    $y += 4
    Add-Label $form 'Co-op:  what the other players use too (you can change these later in coop\romfs\botw-coop\config.ini)' 16 $y 728 20 -Bold | Out-Null
    $y += 28
    $fields = @{}
    foreach ($spec in @(
        @{ Key = 'Name'; Text = 'Your name'; X = 16; W = 210; Max = 24 },
        @{ Key = 'Password'; Text = 'Password'; X = 392; W = 200; Max = 64 }
    )) {
        Add-Label $form $spec.Text $spec.X ($y + 3) 90 20 | Out-Null
        $b = New-Object Windows.Forms.TextBox
        $b.Location = New-Object Drawing.Point(($spec.X + 92), $y)
        $b.Size = New-Object Drawing.Size($spec.W, 26)
        $b.MaxLength = $spec.Max
        $b.Text = [string]$Start[$spec.Key]
        $form.Controls.Add($b)
        $fields[$spec.Key] = $b
    }
    $y += 34
    Add-Label $form 'Server' 16 ($y + 3) 90 20 | Out-Null
    $server = New-Object Windows.Forms.TextBox
    $server.Location = New-Object Drawing.Point(108, $y)
    $server.Size = New-Object Drawing.Size(278, 26)
    $server.Text = [string]$Start['Server']
    $form.Controls.Add($server)
    $fields['Server'] = $server
    Add-Label $form 'Port' 392 ($y + 3) 90 20 | Out-Null
    $port = New-Object Windows.Forms.TextBox
    $port.Location = New-Object Drawing.Point(484, $y)
    $port.Size = New-Object Drawing.Size(80, 26)
    $port.MaxLength = 5
    $port.Text = [string]$Start['Port']
    $form.Controls.Add($port)
    $fields['Port'] = $port
    $y += 30
    $hint = Add-Label $form "Server: the address of the computer running the relay (127.0.0.1 if it's this one). The same password puts you in the same game." 16 $y 728 40
    $hint.ForeColor = [Drawing.Color]::DimGray
    $y += 46

    $shortcut = New-Object Windows.Forms.CheckBox
    $shortcut.Text = "Put a 'Play BotW Co-op' shortcut on the desktop"
    $shortcut.Checked = $Start['Shortcut']
    $shortcut.Location = New-Object Drawing.Point(16, $y)
    $shortcut.Size = New-Object Drawing.Size(728, 24)
    $form.Controls.Add($shortcut)
    $y += 30
    $note = Add-Label $form ('Then a console window does the work: the build tools (the first time; Windows may ask for permission), ' +
        'the newest co-op mod from GitHub, your game files, and the build (20 to 40 minutes the first time). To update later, run Update BotW Co-op.cmd.') 16 $y 728 60
    $note.ForeColor = [Drawing.Color]::DimGray

    $ok = Add-Button $form 'Install' 488 604 150
    $cancel = Add-Button $form 'Cancel' 644 604 100
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $cancel
    $form.AcceptButton = $ok

    $results = @{}
    $refresh = {
        $b = $rows['BaseGame'].Box.Text.Trim().Trim('"')
        $results['BaseGame'] = Test-BaseFile $b
        $results['GameUpdate'] = Test-UpdateFile $rows['GameUpdate'].Box.Text.Trim().Trim('"') $b
        $results['Keys'] = Test-KeysFile $rows['Keys'].Box.Text.Trim().Trim('"')
        foreach ($k in @('BaseGame', 'GameUpdate', 'Keys')) {
            $rows[$k].Status.Text = $results[$k].Text
            $rows[$k].Status.ForeColor = if ($results[$k].Ok) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::Firebrick }
        }
    }
    foreach ($k in @('BaseGame', 'GameUpdate', 'Keys')) {
        $row = $rows[$k]
        $row.Browse.Add_Click({
            $dlg = New-Object Windows.Forms.OpenFileDialog
            $dlg.Title = "Choose the $($row.Title.ToLower()) file"
            $dlg.Filter = $row.Filter
            $cur = $row.Box.Text.Trim().Trim('"')
            if ($cur -and (Test-Path -LiteralPath $cur)) { $dlg.InitialDirectory = Split-Path -Parent $cur }
            if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $row.Box.Text = $dlg.FileName; & $refresh }
        }.GetNewClosure())
        $row.Box.Add_Leave({ & $refresh })
    }
    $ok.Add_Click({
        & $refresh
        $bad = @()
        foreach ($k in @('BaseGame', 'GameUpdate', 'Keys')) { if (-not $results[$k].Ok) { $bad += $rows[$k].Title } }
        $p = 0
        if (-not [int]::TryParse($fields['Port'].Text.Trim(), [ref]$p) -or $p -lt 1 -or $p -gt 65535) { $bad += 'Port (a number, 7777 unless told otherwise)' }
        if (-not $fields['Server'].Text.Trim()) { $bad += 'Server' }
        if (-not $fields['Name'].Text.Trim()) { $bad += 'Your name' }
        if ($bad.Count -gt 0) {
            [Windows.Forms.MessageBox]::Show($form, "Please fix: $($bad -join ', ').", $Title, 'OK', 'Warning') | Out-Null
            return
        }
        $form.DialogResult = [Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Add_Shown({ $form.Activate(); & $refresh })
    Save-Snapshot $form
    if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return $null }
    return @{
        BaseGame = $rows['BaseGame'].Box.Text.Trim().Trim('"'); GameUpdate = $rows['GameUpdate'].Box.Text.Trim().Trim('"')
        Keys = $rows['Keys'].Box.Text.Trim().Trim('"'); Name = $fields['Name'].Text.Trim(); Server = $fields['Server'].Text.Trim()
        Port = $fields['Port'].Text.Trim(); Password = $fields['Password'].Text.Trim(); Shortcut = $shortcut.Checked
    }
}

function Get-Latest {
    <# What GitHub has: @{ModTag; ModName; ModDate; Commit; CommitDate; Error} #>
    $out = @{}
    $headers = @{ 'User-Agent' = 'savagewind-coop-installer'; 'Accept' = 'application/vnd.github+json' }
    try {
        $r = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$ModRepo/releases/latest" -TimeoutSec 20
        $out.ModTag = $r.tag_name; $out.ModName = $r.name; $out.ModDate = ([datetime]$r.published_at).ToString('yyyy-MM-dd')
    } catch { $out.Error = "Couldn't reach GitHub ($($_.Exception.Message))." }
    try {
        $c = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/commits/$Branch" -TimeoutSec 20
        $out.Commit = $c.sha; $out.CommitDate = ([datetime]$c.commit.committer.date).ToString('yyyy-MM-dd'); $out.CommitText = ($c.commit.message -split "`n")[0]
    } catch { if (-not $out.Error) { $out.Error = "Couldn't reach GitHub ($($_.Exception.Message))." } }
    return $out
}

function Show-UpdateWindow {
    <# @{Source = bool}, or $null if closed #>
    param([hashtable]$Latest)
    $form = New-Form "$Title - update" 720 330
    $installed = Get-InstalledVersion
    $commit = Get-SourceCommit
    Add-Label $form 'Co-op mod' 16 16 200 20 -Bold | Out-Null
    $iv = if ($installed) { $installed } else { 'not installed by this updater yet' }
    (Add-Label $form "Installed:  $iv" 32 40 670 20).AutoEllipsis = $true
    $newest = if ($Latest.ModTag) { "$($Latest.ModName) ($($Latest.ModTag), $($Latest.ModDate))" } else { 'unknown' }
    (Add-Label $form "Newest:      $newest" 32 62 670 20).AutoEllipsis = $true
    $modNew = $Latest.ModTag -and -not $installed.StartsWith("$($Latest.ModTag) ")

    Add-Label $form 'Savage Wind (this program)' 16 96 300 20 -Bold | Out-Null
    $cv = if ($commit) { $commit.Substring(0, [Math]::Min(7, $commit.Length)) } else { 'unknown' }
    (Add-Label $form "This folder:  $cv" 32 120 670 20).AutoEllipsis = $true
    $lv = if ($Latest.Commit) { "$($Latest.Commit.Substring(0, 7)) ($($Latest.CommitDate)): $($Latest.CommitText)" } else { 'unknown' }
    (Add-Label $form "Newest:       $lv" 32 142 670 20).AutoEllipsis = $true
    $srcNew = $Latest.Commit -and ($commit -ne $Latest.Commit)

    $src = New-Object Windows.Forms.CheckBox
    $src.Text = 'Also update Savage Wind from GitHub (your game files, saves and settings stay)'
    $src.Checked = [bool]$srcNew
    $src.Location = New-Object Drawing.Point(16, 176)
    $src.Size = New-Object Drawing.Size(688, 24)
    $form.Controls.Add($src)

    $msg = if ($Latest.Error) { $Latest.Error + ' Updating needs the internet.' }
           elseif ($modNew -or $srcNew) { 'An update is ready. Updating builds the game again (a few minutes; longer if Savage Wind changed). Everyone who plays together needs the same co-op version.' }
           else { "Everything is up to date. 'Update and build' builds the game again anyway." }
    $status = Add-Label $form $msg 16 210 688 60
    $status.ForeColor = if ($Latest.Error) { [Drawing.Color]::Firebrick } elseif ($modNew -or $srcNew) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::DimGray }

    $ok = Add-Button $form 'Update and build' 448 284 150
    $close = Add-Button $form 'Close' 604 284 100
    $close.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $close
    if ($Latest.Error) { $ok.Enabled = $false }
    $ok.Add_Click({ $form.DialogResult = [Windows.Forms.DialogResult]::OK; $form.Close() })
    $form.Add_Shown({ $form.Activate() })
    Save-Snapshot $form
    if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return $null }
    return @{ Source = $src.Checked }
}

# ---- the steps ------------------------------------------------------------------------------------------------------
function Step-BuildTools {
    Write-Step 'Build tools'
    if (Test-BuildTools) { Write-Info 'MSYS2 and Python are there.'; return }
    Write-Info 'Installing MSYS2 and Python 3.12 (once; this takes a while, and Windows may ask for permission)'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\setup_windows.ps1')
    $rc = $LASTEXITCODE
    if (-not (Test-BuildTools)) { Stop-Setup 'installing the build tools failed: see the messages above. Running this again carries on.' }
    # (its last step sets git's line endings for a clone; a folder downloaded as a zip on a PC without Git fails it, harmlessly)
    if ($rc -ne 0) { Write-Warn 'The tools setup ended with an error after installing everything (see above); carrying on.' }
}

function Step-Keys {
    param([string]$Keys)
    if (-not $Keys) { return }
    Write-Step 'Your keys'
    $dir = Join-Path $env:USERPROFILE '.switch'
    $dest = Join-Path $dir 'prod.keys'
    $src = (Resolve-Path -LiteralPath $Keys).Path
    if ((Test-Path -LiteralPath $dest) -and ((Resolve-Path -LiteralPath $dest).Path -eq $src)) { Write-Info "Using $dest"; return }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ((Test-Path -LiteralPath $dest) -and ((Get-FileHash -LiteralPath $dest).Hash -ne (Get-FileHash -LiteralPath $src).Hash)) {
        Copy-Item -LiteralPath $dest -Destination "$dest.bak" -Force
        Write-Info "There was another prod.keys in ${dir}: kept as prod.keys.bak"
    }
    Copy-Item -LiteralPath $src -Destination $dest -Force
    $title = Join-Path (Split-Path -Parent $src) 'title.keys'
    if (Test-Path -LiteralPath $title) { Copy-Item -LiteralPath $title -Destination (Join-Path $dir 'title.keys') -Force }
    Write-Info "Copied to $dest (where the co-op setup reads them)"
}

function Step-Source {
    Write-Step 'Updating Savage Wind from GitHub'
    $git = Get-Git
    if ($git -and (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        & $git -C $Root pull --ff-only origin $Branch
        if ($LASTEXITCODE -ne 0) { Stop-Setup "git couldn't update this folder (see above; files of the source changed by hand stop it). Undo those changes, or download the folder again." }
        return
    }
    # A folder downloaded as a zip: the newest zip of the branch, copied over (game files, saves, builds stay)
    $zip = Join-Path $CoopDir 'source.zip'
    $tmp = Join-Path $CoopDir 'source-new'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $CoopDir | Out-Null
    Write-Info 'Downloading the source'
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip
    Unblock-File -LiteralPath $zip -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $top = @(Get-ChildItem -LiteralPath $tmp -Directory)[0].FullName
    $skip = @('extracted', 'save', 'coop', 'build', 'generated', 'cache', '.git') | ForEach-Object { Join-Path $top $_ }
    & robocopy.exe $top $Root /E /NFL /NDL /NJH /NJS /NP /XD @skip | Out-Null
    if ($LASTEXITCODE -ge 8) { Stop-Setup "copying the new source failed (robocopy $LASTEXITCODE)." }
    Remove-Item -LiteralPath $tmp -Recurse -Force
    Remove-Item -LiteralPath $zip -Force
    $latest = Get-Latest
    if ($latest.Commit) { [IO.File]::WriteAllText((Join-Path $CoopDir 'source_commit.txt'), $latest.Commit) }
    Write-Info 'Done'
}

function Find-Python {
    <# The python.org Python 3.12 that tools\setup_windows.ps1 installs, else the launcher, else python on PATH #>
    $p = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
    if (Test-Path -LiteralPath $p) { return @($p) }
    if (Get-Command py -ErrorAction SilentlyContinue) { return @('py', '-3') }
    $c = Get-Command python -ErrorAction SilentlyContinue
    if ($c -and $c.Source -notmatch 'WindowsApps') { return @($c.Source) }
    return $null
}

function Step-Mod {
    param([string]$BaseGame, [string]$GameUpdate)
    Write-Step 'Downloading the newest co-op mod release'
    $pkg = Join-Path $CoopDir 'package'
    if (Test-Path -LiteralPath $pkg) { Remove-Item -LiteralPath $pkg -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $pkg | Out-Null
    $zip = Join-Path $pkg 'mod.zip'
    $latest = Get-Latest
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$ModRepo/releases/latest/download/$ModAsset" -OutFile $zip
        Unblock-File -LiteralPath $zip -ErrorAction SilentlyContinue
        Expand-Archive -LiteralPath $zip -DestinationPath $pkg -Force
    } catch {
        Stop-Setup "downloading the co-op mod failed ($($_.Exception.Message)). Check the internet connection and run this again."
    }
    $version = ([IO.File]::ReadAllText((Join-Path $pkg 'botw-coop\VERSION'))).Trim()
    if ($latest.ModTag) { $version = "$($latest.ModTag) $($latest.ModName) (build $version)" }
    Write-Info $version

    Write-Step 'Setting up the co-op mod and building the game'
    if (-not (Test-GameExtracted)) { Write-Info "Your game files are read into extracted\ first (about 15 GB, several minutes)." }
    Write-Info 'The build takes 15 to 20 minutes the first time, a few minutes after that.'
    # (Python 3.12 from setup_windows.ps1: a window opened before it was installed doesn't have it on PATH)
    $env:PATH = "$env:LOCALAPPDATA\Programs\Python\Launcher;$env:LOCALAPPDATA\Programs\Python\Python312;$env:PATH"
    $setupArgs = @()
    if ($BaseGame -and $GameUpdate -and -not (Test-GameExtracted)) { $setupArgs += @($BaseGame, $GameUpdate) }
    $setupArgs += @('--no-ryujinx', '--recomp', $Root)
    $script = Join-Path $pkg 'botw-coop\tools\coop_setup.py'
    if (-not (Test-Path -LiteralPath $script)) { $script = Join-Path $pkg 'botw-coop\coop_setup.py' }
    $py = Find-Python
    if (-not $py) { Stop-Setup 'Python 3.12 is not installed (the build tools step should have installed it). Run this again.' }
    $exe = $py[0]
    $pre = @($py | Select-Object -Skip 1)
    & $exe @pre $script @setupArgs
    if ($LASTEXITCODE -ne 0) { Stop-Setup 'the co-op setup or the build stopped (see the messages above). Copy the last 30 lines and share them.' }
    [IO.File]::WriteAllText((Join-Path $CoopDir 'installed_version.txt'), $version)
}

function Step-Settings {
    param([hashtable]$A)
    if (-not (Test-Path -LiteralPath $Config)) { Write-Warn "No $Config to write your co-op settings into."; return }
    Write-Step 'Your co-op settings'
    $want = [ordered]@{ name = $A.Name; server = $A.Server; port = $A.Port; password = $A.Password }
    $lines = [Collections.Generic.List[string]]::new([IO.File]::ReadAllLines($Config))
    foreach ($k in @($want.Keys)) {
        if (-not $want[$k]) { continue }
        $i = -1
        for ($j = 0; $j -lt $lines.Count; $j++) { if ($lines[$j] -match "^\s*$k\s*=") { $i = $j; break } }
        if ($i -ge 0) { $lines[$i] = "$k = $($want[$k])" } else { $lines.Add("$k = $($want[$k])") }
    }
    [IO.File]::WriteAllText($Config, (($lines -join "`n") + "`n"))
    Write-Info "name = $($A.Name), server = $($A.Server):$($A.Port) (in $Config)"
    # (the answers for next time: the files and the shortcut choice; the co-op settings live in config.ini)
    $save = @("base_game = $($A.BaseGame)", "game_update = $($A.GameUpdate)", "keys = $($A.Keys)", "shortcut = $([int][bool]$A.Shortcut)")
    [IO.File]::WriteAllText($Answers, (($save -join "`r`n") + "`r`n"))
}

function Step-Shortcut {
    Write-Step 'Desktop shortcut'
    $play = Join-Path $Root 'play-coop.cmd'
    if (-not (Test-Path -LiteralPath $play)) { Write-Warn 'play-coop.cmd is missing: no shortcut.'; return }
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Play BotW Co-op.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = $play
    $s.WorkingDirectory = $Root
    $ico = Join-Path $Root 'docs\icon\icon.ico'
    if (Test-Path -LiteralPath $ico) { $s.IconLocation = $ico }
    $s.Description = 'Savage Wind with the BotW co-op mod'
    $s.Save()
    Write-Info $lnk
}

function Test-Disk {
    param([double]$NeedGb)
    $drive = (Get-Item -LiteralPath $Root).PSDrive
    $free = $drive.Free / 1GB
    if ($free -lt $NeedGb) { Stop-Setup ("about {0:N0} GB of free space is needed on {1}:, and {2:N0} GB are free." -f $NeedGb, $drive.Name, $free) }
}

# ---- main ---------------------------------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath (Join-Path $Root 'tools\mod_add.py'))) {
    Write-Host "This isn't the Savage Wind source that loads code mods (no tools\mod_add.py)." -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Force -Path $CoopDir | Out-Null

if ($Update) {
    if (-not (Test-GameExtracted)) {
        if ($Snapshot) { Write-Host 'No game files here: the window would say to install first.' }
        else {
            Add-Type -AssemblyName System.Windows.Forms
            [Windows.Forms.MessageBox]::Show("Savage Wind isn't set up in this folder yet. Run 'Install BotW Co-op.cmd' first.", $Title, 'OK', 'Information') | Out-Null
            exit 1
        }
    }
    Write-Host 'Asking GitHub what is newest...'
    $latest = Get-Latest
    $choice = Show-UpdateWindow $latest
    if ($Snapshot -or -not $choice) { exit 0 }
    Test-Disk 5
    if ($choice.Source) { Step-Source }
    Step-BuildTools
    Step-Mod
    Write-Host ''
    Write-Host 'Updated. Start the game with play-coop.cmd (or the desktop shortcut).' -ForegroundColor Green
    exit 0
}

# Install: the window, unless the files were given on the command line
$saved = Read-Ini $Answers
$cfg = Read-Ini $Config
if ($BaseGame -or $GameUpdate) {
    $a = @{ BaseGame = $BaseGame; GameUpdate = $GameUpdate; Keys = ''; Name = ''; Server = ''; Port = ''; Password = ''; Shortcut = $false }
} else {
    $found = if (Test-GameExtracted) { @{ Base = ''; Update = '' } } else { Find-GameFiles }
    $pick = { param($a, $b) if ($a -and (Test-Path -LiteralPath $a)) { $a } else { $b } }
    $keys = & $pick $saved['keys'] (@(Get-KeyCandidates) | Select-Object -First 1)
    if ((Test-GameExtracted) -and -not $saved['keys']) { $keys = '' }
    $start = @{
        BaseGame = if (Test-GameExtracted) { '' } else { & $pick $saved['base_game'] $found.Base }
        GameUpdate = if (Test-GameExtracted) { '' } else { & $pick $saved['game_update'] $found.Update }
        Keys = $keys
        Name = if ($cfg['name'] -and $cfg['name'] -ne 'Link') { $cfg['name'] } else { $env:USERNAME }
        Server = if ($cfg['server']) { $cfg['server'] } else { '127.0.0.1' }
        Port = if ($cfg['port']) { $cfg['port'] } else { '7777' }
        Password = if ($cfg['password']) { $cfg['password'] } else { 'hyrule' }
        Shortcut = if ($saved.ContainsKey('shortcut')) { $saved['shortcut'] -eq '1' } else { $true }
    }
    $a = Show-InstallWindow $start
    if ($Snapshot -or -not $a) { exit 0 }
}

Test-Disk $(if (Test-GameExtracted) { 5 } else { 25 })
Step-BuildTools
Step-Keys $a.Keys
Step-Mod $a.BaseGame $a.GameUpdate
if ($a.Name) { Step-Settings $a }
if ($a.Shortcut) { Step-Shortcut }
Write-Host ''
Write-Host 'Done. Start the game with play-coop.cmd in this folder (or the desktop shortcut) and load a save:' -ForegroundColor Green
Write-Host 'a banner says "Co-op: connected". To update later, run Update BotW Co-op.cmd.' -ForegroundColor Green
exit 0
