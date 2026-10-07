<#
.SYNOPSIS
    Install quackling, the DuckDB Quack protocol client.

.DESCRIPTION
    The Windows counterpart to scripts/install.sh. Downloads a release binary,
    verifies its SHA-256, and installs it to a user-writable location so no
    elevation is required.

.EXAMPLE
    irm https://raw.githubusercontent.com/OWNER/Quackling/main/scripts/install.ps1 | iex

.EXAMPLE
    .\install.ps1 -Version v0.1.0 -BinDir "$env:USERPROFILE\bin"

.EXAMPLE
    .\install.ps1 -Build          # build from source with Zig instead

.EXAMPLE
    .\install.ps1 -NoAlias        # install only `quackling`, no `qkl`
#>
[CmdletBinding()]
param(
    # Version to install, or "latest".
    [string] $Version = $(if ($env:QUACK_VERSION) { $env:QUACK_VERSION } else { 'latest' }),

    # Where to install. Defaults to a user-owned dir, so no admin rights needed.
    [string] $BinDir = $env:QUACK_BIN_DIR,

    # GitHub repository to download from.
    [string] $Repo = $(if ($env:QUACK_REPO) { $env:QUACK_REPO } else { 'OWNER/Quackling' }),

    # Build from source with Zig rather than downloading.
    [switch] $Build,

    # Skip checksum verification. Not recommended.
    [switch] $NoVerify,

    # Skip installing the short `qkl` alias.
    [switch] $NoAlias,

    # Print what would happen without changing anything.
    [switch] $DryRun,

    # Replace an existing install without commenting on it.
    [switch] $Force
)

# Stop on the first error, and make non-terminating errors terminating, so a
# failed download can never fall through into "installed successfully".
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "OK  $Message" -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Warning $Message }
function Stop-Install { param([string] $Message) throw $Message }

# ---------------------------------------------------------------------------
# platform
# ---------------------------------------------------------------------------

function Get-Target {
    # PROCESSOR_ARCHITECTURE reports the *process* architecture, so a 32-bit
    # PowerShell on 64-bit Windows would mislead us; prefer the OS value.
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }

    switch ($arch) {
        'AMD64' { return 'x86_64-windows' }
        'ARM64' { return 'aarch64-windows' }
        default { Stop-Install "unsupported architecture: $arch (supported: AMD64, ARM64)" }
    }
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Resolve-Version {
    param([string] $Requested, [string] $Repository)
    if ($Requested -ne 'latest') { return $Requested }

    Write-Step 'Resolving latest release'
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" `
            -Headers @{ 'User-Agent' = 'quackling-installer' }
        if ($release.tag_name) { return $release.tag_name }
    } catch {
        # Fall through to the explicit guidance below.
    }
    Stop-Install @"
could not determine the latest release of $Repository.
  Pass an explicit version:  -Version v0.1.0
  Or build from source:      -Build
"@
}

function Get-DefaultBinDir {
    # A user-owned location keeps the common path elevation-free.
    Join-Path $env:LOCALAPPDATA 'Programs\quackling'
}

function Test-Checksum {
    param([string] $File, [string] $BaseUrl, [string] $Asset)

    if ($NoVerify) {
        Write-Warn 'skipping checksum verification (-NoVerify)'
        return
    }

    $sums = $null
    try {
        $raw = Invoke-WebRequest -Uri "$BaseUrl/SHA256SUMS" -UseBasicParsing `
            -Headers @{ 'User-Agent' = 'quackling-installer' } | Select-Object -ExpandProperty Content
        # `.Content` is text on PowerShell 5.1 but a byte sequence on 7 - and
        # there it arrives as Object[] of boxed bytes, not Byte[], so an
        # `-is [byte[]]` check misses it and the bytes get stringified as
        # "99 54 97 ...". That silently produced a "no entry for asset" warning
        # instead of verifying, so normalise explicitly.
        $sums = if ($raw -is [string]) {
            $raw
        } else {
            [System.Text.Encoding]::UTF8.GetString([byte[]] @($raw))
        }
    } catch {
        # Say so rather than implying the download was verified.
        Write-Warn "no SHA256SUMS published for $Version; cannot verify the download"
        return
    }

    $expected = $null
    foreach ($line in ($sums -split "`r?`n")) {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($Asset))\s*$") {
            $expected = $Matches[1].ToLower()
            break
        }
    }
    if (-not $expected) {
        Write-Warn "SHA256SUMS has no entry for $Asset; cannot verify"
        return
    }

    $actual = (Get-FileHash -Path $File -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Stop-Install @"
checksum mismatch for $Asset
  expected $expected
  actual   $actual
  Refusing to install. This could be a corrupted download or a tampered asset.
"@
    }
    Write-Ok 'checksum verified'
}

function Install-Binary {
    param([string] $Source, [string] $Destination)

    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path $dir)) {
        Write-Host "  creating $dir"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ((Test-Path $Destination) -and -not $Force) {
        $existing = 'unknown'
        try { $existing = (& $Destination --version 2>&1 | Out-String).Trim() } catch { }
        Write-Host "  replacing existing install ($existing)"
    }

    # Copy to a sibling temp path then move, so an interrupted install cannot
    # leave a half-written exe where the shell will find it.
    $staged = "$Destination.new"
    Copy-Item -Path $Source -Destination $staged -Force
    Move-Item -Path $staged -Destination $Destination -Force

    Write-Ok "installed $Destination"

    # Run it: a binary for the wrong architecture installs fine and then fails
    # on first use, which is a worse experience than failing here.
    try {
        $out = (& $Destination --version 2>&1 | Out-String).Trim()
        Write-Ok $out
    } catch {
        Stop-Install @"
installed binary does not run:
  $_
  This usually means the wrong platform asset. Try -Build.
"@
    }
}

function Install-Alias {
    param([string] $Destination)

    if ($NoAlias) { return }

    $aliasPath = Join-Path (Split-Path -Parent $Destination) 'qkl.exe'

    # Never clobber an unrelated qkl.exe. Ours is recognised by asking it for a
    # version string that names this project.
    if (Test-Path $aliasPath) {
        $ours = $false
        try { $ours = ((& $aliasPath --version 2>&1 | Out-String) -match '^quackling\s') } catch { }
        if (-not ($ours -or $Force)) {
            Write-Warn "$aliasPath already exists and is not ours; leaving it alone. Use -Force to replace it, or -NoAlias to skip."
            return
        }
    }

    # A symlink would need developer mode or elevation on Windows, so copy. It
    # costs a second file on disk but never fails for a permission reason.
    try {
        Copy-Item -Path $Destination -Destination $aliasPath -Force
        Write-Ok "installed $aliasPath"
    } catch {
        Write-Warn "could not create the qkl alias; quackling is installed and works"
    }
}

function Test-OnPath {
    param([string] $Dir)

    $onPath = ($env:PATH -split ';' | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') })
    if ($onPath) { return }

    Write-Warn "$Dir is not on your PATH"
    Write-Host ''
    Write-Host '  Add it for future sessions with:'
    Write-Host "    [Environment]::SetEnvironmentVariable('PATH', `"`$env:PATH;$Dir`", 'User')"
    Write-Host ''
    Write-Host '  Or for this session only:'
    Write-Host "    `$env:PATH += ';$Dir'"
}

# ---------------------------------------------------------------------------
# install paths
# ---------------------------------------------------------------------------

function Install-FromRelease {
    param([string] $Target, [string] $Destination)

    $resolved = Resolve-Version -Requested $Version -Repository $Repo
    $script:Version = $resolved
    $base = "https://github.com/$Repo/releases/download/$resolved"
    $asset = "quackling-$Target.exe"

    Write-Step "Installing quackling $resolved for $Target"

    if ($DryRun) {
        Write-Host "  would download $base/$asset"
        Write-Host "  would install to $Destination"
        if (-not $NoAlias) { Write-Host "  would copy it to qkl.exe alongside" }
        return
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("quackling-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $download = Join-Path $tmp 'quackling.exe'
        Write-Host "  downloading $asset"
        try {
            Invoke-WebRequest -Uri "$base/$asset" -OutFile $download -UseBasicParsing `
                -Headers @{ 'User-Agent' = 'quackling-installer' }
        } catch {
            Stop-Install @"
download failed: $base/$asset
  Check that $resolved exists and has an asset for $Target, or use -Build.
"@
        }
        if ((Get-Item $download).Length -eq 0) { Stop-Install 'downloaded file is empty' }

        Test-Checksum -File $download -BaseUrl $base -Asset $asset
        Install-Binary -Source $download -Destination $Destination
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Install-FromSource {
    param([string] $Destination)

    $zig = Get-Command zig -ErrorAction SilentlyContinue
    if (-not $zig) { Stop-Install '-Build needs zig on PATH (https://ziglang.org/download/)' }

    $zigVersion = (& zig version).Trim()
    if ($zigVersion -notlike '0.17.*') {
        Write-Warn "this project targets Zig 0.17.x; found $zigVersion"
    }

    Write-Step "Building quackling from source with Zig $zigVersion"
    if ($DryRun) {
        Write-Host '  would run: zig build -Doptimize=safe'
        Write-Host "  would install to $Destination"
        if (-not $NoAlias) { Write-Host "  would copy it to qkl.exe alongside" }
        return
    }

    $root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    if (-not (Test-Path (Join-Path $root 'build.zig'))) {
        Stop-Install 'build.zig not found; run this from a checkout or drop -Build'
    }

    Push-Location $root
    try {
        & zig build -Doptimize=safe
        if ($LASTEXITCODE -ne 0) { Stop-Install 'build failed' }
    } finally {
        Pop-Location
    }

    $built = Join-Path $root 'zig-out\bin\quackling.exe'
    if (-not (Test-Path $built)) { Stop-Install 'build produced no quackling.exe' }
    Install-Binary -Source $built -Destination $Destination
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

$target = Get-Target
if (-not $BinDir) { $BinDir = Get-DefaultBinDir }
$destination = Join-Path $BinDir 'quackling.exe'

if ($Build) {
    Install-FromSource -Destination $destination
} else {
    Install-FromRelease -Target $target -Destination $destination
}

if (-not $DryRun) {
    Install-Alias -Destination $destination
    Test-OnPath -Dir $BinDir
    Write-Host ''
    Write-Host 'Try it:'
    Write-Host '  quackling --url quack:localhost:9494 --token $env:QUACK_TOKEN "SELECT 42"'
    if (-not $NoAlias) { Write-Host '  qkl "SELECT 42"   # same command, shorter' }
    Write-Host ''
    Write-Host 'Start a server with:' -ForegroundColor DarkGray
    Write-Host '  duckdb -c "LOAD quack; CALL quack_serve(''quack:localhost:9494'', token => ''secret'');"' -ForegroundColor DarkGray
}
