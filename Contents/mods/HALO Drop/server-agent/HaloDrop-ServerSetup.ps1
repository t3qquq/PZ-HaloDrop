# Halo Drop - dedicated server setup (Windows)
# Installs or removes HaloDropAgent.jar for a Project Zomboid dedicated server.
#   You pick the .bat file you use to start the server (StartServer64.bat,
#   or your own copy such as API-Test.bat).
#   Install: copies HaloDropAgent.jar next to that .bat and adds
#            -javaagent:"<full path>\HaloDropAgent.jar" to its java line
#            (a backup <name>.bat.halodrop-backup is made once).
#   Remove : takes the option out of that .bat and deletes the copied jar.
# Run it again after a SteamCMD server update (StartServer64.bat may be reset)
# or after a Halo Drop update (the copied jar may be old).
# ASCII only on purpose: Windows PowerShell 5 reads BOM-less files as CP949.

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$jarSrc = Join-Path $here 'HaloDropAgent.jar'
$jarName = 'HaloDropAgent.jar'

# java launcher at the start of a line: "...\java.exe", ...\java.exe, java.exe or java (javaw too)
$javaRe  = New-Object System.Text.RegularExpressions.Regex('(?im)^(\s*(?:"[^"\r\n]*\\?javaw?\.exe"|[^\s"\r\n]*\\javaw?\.exe|javaw?\.exe|javaw?))(?=\s)')
# our option, quoted or not, with the space before it
$agentRe = New-Object System.Text.RegularExpressions.Regex(' ?-javaagent:(?:"[^"\r\n]*HaloDropAgent\.jar"|[^\s"\r\n]*HaloDropAgent\.jar)', 'IgnoreCase')

function Say([string]$m)  { Write-Host ('[HaloDrop] ' + $m) }
function Fail([string]$m) { Write-Host ('[HaloDrop] ERROR: ' + $m) -ForegroundColor Red }

function Pick-BatFile {
    $path = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Title = 'Select the .bat file you use to start the dedicated server (e.g. StartServer64.bat)'
        $d.Filter = 'Batch files (*.bat;*.cmd)|*.bat;*.cmd|All files (*.*)|*.*'
        $d.CheckFileExists = $true
        $d.Multiselect = $false
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $path = $d.FileName }
    } catch {
        Say 'File window could not open. Type or paste the path of the .bat instead.'
        $path = Read-Host 'Server start .bat file'
    }
    if ($path) { $path = $path.Trim().Trim('"') }
    return $path
}

function Read-Bat([string]$file) {
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object System.Text.UTF8Encoding($bom)
    $text = $enc.GetString($bytes)
    if ($bom) { $text = $text.Substring(1) }
    return @{ Text = $text; Enc = $enc }
}

function Write-Bat([string]$file, $bat, [string]$text) {
    [System.IO.File]::WriteAllText($file, $text, $bat.Enc)
}

function Check-Bat([string]$file) {
    if (-not $file) { Fail 'No file selected.'; return $false }
    if (-not [System.IO.File]::Exists($file)) { Fail ('File not found: ' + $file); return $false }
    $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
    if ($ext -ne '.bat' -and $ext -ne '.cmd') { Fail ('Not a .bat / .cmd file: ' + $file); return $false }
    $bat = Read-Bat $file
    if (-not $javaRe.IsMatch($bat.Text) -and -not $agentRe.IsMatch($bat.Text)) {
        Fail 'This file has no line that starts with java / java.exe. Pick the .bat that actually starts the server.'
        return $false
    }
    return $true
}

function Install([string]$batFile) {
    if (-not [System.IO.File]::Exists($jarSrc)) { Fail ('HaloDropAgent.jar not found next to this script: ' + $jarSrc); return }
    $dir    = Split-Path -Parent $batFile
    $jarDst = Join-Path $dir $jarName
    if ($jarDst -match '[^\x00-\x7F]') {
        Say 'WARNING: the folder path has non-English characters. If the server cannot find the agent, move the server to an English-only path.'
    }

    [System.IO.File]::Copy($jarSrc, $jarDst, $true)
    Say ('Copied agent  -> ' + $jarDst)

    $backup = $batFile + '.halodrop-backup'
    if (-not [System.IO.File]::Exists($backup)) {
        [System.IO.File]::Copy($batFile, $backup, $false)
        Say ('Backup made   -> ' + $backup)
    }

    # full path, so it works whatever folder the .bat changes into (cd /d ...)
    $option = '-javaagent:"' + $jarDst + '"'
    $bat = Read-Bat $batFile
    $text = $agentRe.Replace($bat.Text, '')          # drop an older option first (path may have changed)
    $m = $javaRe.Match($text)
    if (-not $m.Success) {
        Fail 'Could not find the java line in the .bat. Nothing was changed.'
        Say  ('Add ' + $option + ' right after java.exe by hand.')
        return
    }
    $new = $text.Substring(0, $m.Index + $m.Length) + ' ' + $option + $text.Substring($m.Index + $m.Length)
    if ($new -ne $bat.Text) {
        Write-Bat $batFile $bat $new
        if (-not $agentRe.IsMatch((Read-Bat $batFile).Text)) { Fail 'Writing the .bat failed.'; return }
        Say ('Agent option set in ' + [System.IO.Path]::GetFileName($batFile) + ':  ' + $option)
    } else {
        Say ([System.IO.Path]::GetFileName($batFile) + ' already has the agent option (only the jar was updated).')
    }
    Say ('Done. Start the server with ' + [System.IO.Path]::GetFileName($batFile) + ' as usual.')
    Say 'Check server-console.txt for "[HaloDropAgent] registered HaloDropNative.state/preload".'
}

function Remove([string]$batFile) {
    $dir    = Split-Path -Parent $batFile
    $jarDst = Join-Path $dir $jarName
    $bat = Read-Bat $batFile
    if ($agentRe.IsMatch($bat.Text)) {
        Write-Bat $batFile $bat ($agentRe.Replace($bat.Text, ''))
        Say ('Removed the agent option from ' + [System.IO.Path]::GetFileName($batFile) + '.')
    } else {
        Say ([System.IO.Path]::GetFileName($batFile) + ' has no agent option.')
    }
    if ([System.IO.File]::Exists($jarDst)) {
        [System.IO.File]::Delete($jarDst)
        Say ('Deleted       -> ' + $jarDst)
    }
    Say 'Done.'
}

try {
    Write-Host ''
    Write-Host '  Halo Drop - dedicated server setup'
    Write-Host '  1) Install / update the agent'
    Write-Host '  2) Remove the agent'
    Write-Host '  other) Quit'
    Write-Host ''
    $choice = (Read-Host 'Choose').Trim()
    if ($choice -ne '1' -and $choice -ne '2') { Say 'Nothing done.'; return }
    Say 'Select the .bat file you start the dedicated server with.'
    $batFile = Pick-BatFile
    if (-not (Check-Bat $batFile)) { return }
    Say ('Server start file: ' + $batFile)
    if ($choice -eq '1') { Install $batFile } else { Remove $batFile }
} catch {
    Fail $_.Exception.Message
}
