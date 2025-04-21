Param(
    [Parameter(Mandatory=$true)]
    [string] $RepoListPath,

    [Parameter(Mandatory=$true)]
    [string] $TargetGroup,

    [string]  $TempRoot     = "$env:TEMP\GitMirror",
    [int]     $RetryCount   = 2,
    [switch]  $Incremental,
    [switch]  $VerboseLogs,
    [switch]  $DryRun,
    [string]  $LogFile      = ".\migration.log"
)

function Write-Log {
    Param(
        [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string] $Level = 'INFO'
    )
    $ts = Get-Date -Format 's'
    $line = "$ts [$Level] $Message"
    # write INFO/WARN/ERROR to console and file
    if ($Level -ne 'DEBUG') {
        Write-Host $line
    }
    # write DEBUG only to file when verbose is on
    if ($Level -eq 'DEBUG' -and -not $VerboseLogs) {
        return
    }
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Clone-Mirror {
    Param($SrcUrl, $DstPath)
    if ($DryRun) {
        Write-Log "DRY-RUN: would run git clone --mirror $SrcUrl $DstPath" 'INFO'
        return $true
    }
    for ($i=0; $i -lt ($RetryCount+1); $i++) {
        Write-Log "Cloning mirror (attempt $($i+1)) from $SrcUrl" 'INFO'
        try {
            $out = git clone --mirror $SrcUrl $DstPath 2>&1
            $out | ForEach-Object { Write-Log $_ 'DEBUG' }
            Write-Log "Clone succeeded: $SrcUrl" 'INFO'
            return $true
        }
        catch {
            Write-Log "Clone failed on attempt $($i+1): $_" 'WARN'
        }
    }
    Write-Log "All clone attempts failed: $SrcUrl" 'ERROR'
    return $false
}

function Update-Mirror {
    Param($DstPath)
    if ($DryRun) {
        Write-Log "DRY-RUN: would run git remote update --prune in $DstPath" 'INFO'
        return $true
    }
    Write-Log "Updating existing mirror at $DstPath" 'INFO'
    Push-Location $DstPath
    try {
        $out = git remote update --prune 2>&1
        $out | ForEach-Object { Write-Log $_ 'DEBUG' }
        Write-Log "Update succeeded: $DstPath" 'INFO'
        return $true
    }
    catch {
        Write-Log "Update failed: $_" 'ERROR'
        return $false
    }
    finally {
        Pop-Location
    }
}

function Push-Mirror {
    Param($DstPath, $TargetUrl)
    if ($DryRun) {
        Write-Log "DRY-RUN: would run git push --mirror $TargetUrl --force" 'INFO'
        return $true
    }
    Write-Log "Pushing mirror (force) from $DstPath to $TargetUrl" 'INFO'
    Push-Location $DstPath
    try {
        $out = git push --mirror $TargetUrl --force 2>&1
        $out | ForEach-Object { Write-Log $_ 'DEBUG' }
        Write-Log "Push succeeded: $TargetUrl" 'INFO'
        return $true
    }
    catch {
        Write-Log "Push failed: $_" 'ERROR'
        return $false
    }
    finally {
        Pop-Location
    }
}

function Remove-Temp {
    Param($Path)
    if ($DryRun) {
        Write-Log "DRY-RUN: would remove $Path" 'INFO'
        return
    }
    try {
        Remove-Item $Path -Recurse -Force
        Write-Log "Removed temp dir: $Path" 'DEBUG'
    }
    catch {
        Write-Log "Failed to remove temp dir: $_" 'WARN'
    }
}

# === MAIN ===

# initialize log file
if (-not (Test-Path $LogFile)) {
    New-Item $LogFile -ItemType File | Out-Null
}

Write-Log ("Starting migration (Incremental={0}, VerboseLogs={1}, DryRun={2})" -f $Incremental, $VerboseLogs, $DryRun) 'INFO'

# ensure temp folder
if (-not (Test-Path $TempRoot)) {
    if (-not $DryRun) { New-Item $TempRoot -ItemType Directory | Out-Null }
    Write-Log "Temp folder prepared: $TempRoot" 'DEBUG'
}

# read and filter repo list
if (-not (Test-Path $RepoListPath)) {
    Write-Log ("File not found: {0}" -f $RepoListPath) 'ERROR'
    Exit 1
}
$lines = Get-Content -Path $RepoListPath -Encoding UTF8
$repos = $lines |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' -and ($_ -notmatch '^\s*#') }

Write-Log ("Found {0} repos to process: {1}" -f $repos.Count, ($repos -join ', ')) 'INFO'

$success = 0
$failed  = 0

foreach ($src in $repos) {
    $name      = [IO.Path]::GetFileNameWithoutExtension($src)
    $dst       = Join-Path $TempRoot ("$name.git")
    $targetUrl = "$TargetGroup/$name.git"

    if ($Incremental -and (Test-Path $dst)) {
        $ok = Update-Mirror -DstPath $dst
    }
    else {
        if (Test-Path $dst) { Remove-Temp -Path $dst }
        $ok = Clone-Mirror -SrcUrl $src -DstPath $dst
    }

    if ($ok) {
        if (Push-Mirror -DstPath $dst -TargetUrl $targetUrl) {
            Write-Log ("Repository '{0}' migrated successfully" -f $name) 'INFO'
            $success++
        }
        else {
            Write-Log ("Repository '{0}' failed to push" -f $name) 'ERROR'
            $failed++
        }
    }
    else {
        Write-Log ("Repository '{0}' failed to clone/update" -f $name) 'ERROR'
        $failed++
    }

    if (-not $Incremental) {
        Remove-Temp -Path $dst
    }
}

Write-Log ("Migration finished: {0} succeeded, {1} failed" -f $success, $failed) 'INFO'
