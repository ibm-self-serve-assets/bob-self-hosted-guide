<#
.SYNOPSIS
    package-client-kit.ps1 — Package on-prem Bob client setup kit for distribution on Windows.

.DESCRIPTION
    Creates a clean, self-contained zip package containing:
      1. bob-client-setup.ps1 (Windows workstation configuration script)
      2. bob-client-setup.sh (macOS / Linux workstation configuration script)
      3. bob-client-setup.env (pre-populated with gateway URL, cert path, and optional API key —
         an alternative to IdP/SSO sign-in)
      4. bob-ca.crt (CA certificate)
      5. README.md / QUICKSTART instructions for the recipient

.PARAMETER GatewayUrl
    Full gateway base URL (e.g. https://api.bob.ibm-bob.apps....).
    Auto-detected if oc is logged in or from bob-client-setup.env.

.PARAMETER CaCert
    Path to bob-ca.crt (default: looks in ~\bob-ca.crt, .\bob-ca.crt, install pkg).

.PARAMETER ApiKey
    Optional personal API key to pre-populate in the package .env (alternative to SSO).

.PARAMETER IncludeApiKey
    Include API key found in scripts\bob-client-setup.env.

.PARAMETER OutputDir
    Directory to save the zip (default: script's directory).

.PARAMETER OutputName
    Zip archive filename (default: bob-client-setup-kit.zip).

.PARAMETER DryRun
    Preview packaging without writing files.

.PARAMETER Help
    Show this help message.

.EXAMPLE
    .\package-client-kit.ps1
    .\package-client-kit.ps1 -GatewayUrl "https://api.bob.ibm-bob.apps.cluster.domain" -CaCert ".\bob-ca.crt"
#>

[CmdletBinding()]
param (
    [Alias("gateway-url")]
    [string]$GatewayUrl = "",

    [Alias("ca-cert")]
    [string]$CaCert = "",

    [Alias("skip-cert", "no-cert")]
    [switch]$SkipCert,

    [Alias("api-key")]
    [string]$ApiKey = "",

    [Alias("include-api-key")]
    [switch]$IncludeApiKey,

    [Alias("output-dir")]
    [string]$OutputDir = "",

    [Alias("output-name")]
    [string]$OutputName = "bob-client-setup-kit.zip",

    [Alias("dry-run")]
    [switch]$DryRun,

    [Alias("h", "?")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit 0
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$WorkspaceRoot = Split-Path -Parent $ScriptDir
if (-not $OutputDir) { $OutputDir = $ScriptDir }

function Log-Info {
    param([string]$Message)
    if ($env:NOCOLOR) { Write-Host $Message } else { Write-Host $Message -ForegroundColor Green }
}

function Log-Warn {
    param([string]$Message)
    if ($env:NOCOLOR) { Write-Host $Message } else { Write-Host $Message -ForegroundColor Yellow }
}

function Log-Error {
    param([string]$Message)
    if ($env:NOCOLOR) { [Console]::Error.WriteLine($Message) } else { Write-Host $Message -ForegroundColor Red }
}

function Log-DryRun {
    param([string]$Message)
    if ($env:NOCOLOR) { Write-Host "[DRY-RUN] $Message" } else { Write-Host "[DRY-RUN] $Message" -ForegroundColor Yellow }
}

Log-Info "=== IBM Bob Client Package Builder (Windows) ==="

$ExistingEnv = Join-Path $ScriptDir "bob-client-setup.env"
$ExistingGateway = ""
$ExistingKey = ""
$ExistingCert = ""

if (Test-Path $ExistingEnv) {
    Log-Info "Reading defaults from $ExistingEnv"
    Get-Content $ExistingEnv | ForEach-Object {
        $line = $_.Trim()
        if ($line.StartsWith("BOB_GATEWAY_URL=")) {
            $ExistingGateway = $line.Substring("BOB_GATEWAY_URL=".Length).Trim("'`"")
        } elseif ($line.StartsWith("BOB_API_KEY=")) {
            $ExistingKey = $line.Substring("BOB_API_KEY=".Length).Trim("'`"")
        } elseif ($line.StartsWith("BOB_CA_CERT_PATH=")) {
            $ExistingCert = $line.Substring("BOB_CA_CERT_PATH=".Length).Trim("'`"")
        }
    }
}

# 1. Gateway URL Resolution
if (-not $GatewayUrl) {
    if ($ExistingGateway) {
        $GatewayUrl = $ExistingGateway
        Log-Info "Found Gateway URL from bob-client-setup.env: $GatewayUrl"
    } else {
        # Check if oc is available and logged in
        $ocCmd = Get-Command "oc" -ErrorAction SilentlyContinue
        if ($ocCmd) {
            $whoami = oc whoami 2>$null
            if ($whoami) {
                Log-Info "Querying cluster via oc..."
                $crGateway = oc get bob -n ibm-bob -o jsonpath='{.items[0].status.gatewayURL}' 2>$null
                if ($crGateway) {
                    $GatewayUrl = $crGateway
                } else {
                    $clusterDomain = oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>$null
                    if ($clusterDomain) {
                        $GatewayUrl = "https://api.bob.ibm-bob.$clusterDomain"
                    }
                }
            }
        }
    }
}

if (-not $GatewayUrl) {
    Log-Error "Could not determine BOB_GATEWAY_URL."
    Log-Error "Please provide it with -GatewayUrl <url> or configure scripts\bob-client-setup.env"
    exit 1
}

$GatewayUrl = $GatewayUrl.TrimEnd("/")

# Derive console and API keys URL
$consoleHost = $GatewayUrl
if ($GatewayUrl -match "^https://api\.(bob\..+)$") {
    $consoleHost = "https://$($Matches[1])"
}
$ApiKeysUrl = "$consoleHost/admin/apikeys"
$AdminConsoleUrl = "$consoleHost/admin"

# 2. CA Certificate Resolution
$UserHome = [Environment]::GetFolderPath("UserProfile")
if ($SkipCert) {
    Log-Info "CA Certificate: Omitted (-SkipCert specified)"
    $CaCert = ""
} else {
    if (-not $CaCert) {
        if ($ExistingCert) {
            $resolved = $ExistingCert.Replace("~", $UserHome)
            if (-not [System.IO.Path]::IsPathRooted($resolved)) {
                $resolved = Join-Path $ScriptDir $resolved
            }
            if (Test-Path $resolved) { $CaCert = $resolved }
        }
        if (-not $CaCert -and (Test-Path (Join-Path $UserHome "bob-ca.crt"))) {
            $CaCert = Join-Path $UserHome "bob-ca.crt"
        } elseif (-not $CaCert -and (Test-Path (Join-Path $ScriptDir "bob-ca.crt"))) {
            $CaCert = Join-Path $ScriptDir "bob-ca.crt"
        } elseif (-not $CaCert -and (Test-Path (Join-Path $WorkspaceRoot "bob-ca.crt"))) {
            $CaCert = Join-Path $WorkspaceRoot "bob-ca.crt"
        } else {
            # Search ibm-bob-install-* dirs
            $pkgDirs = Get-ChildItem -Path $WorkspaceRoot -Directory -Filter "ibm-bob-install-*" -ErrorAction SilentlyContinue
            foreach ($p in $pkgDirs) {
                $c1 = Join-Path $p.FullName "work\bob-ca.crt"
                $c2 = Join-Path $p.FullName "bob-ca.crt"
                if (Test-Path $c1) { $CaCert = $c1; break }
                elseif (Test-Path $c2) { $CaCert = $c2; break }
            }
        }
    }

    if (-not $CaCert -or -not (Test-Path $CaCert)) {
        if (-not $ExistingCert) {
            Log-Info "No CA certificate found or specified — omitting certificate (trusted CA assumed)"
            $SkipCert = $true
            $CaCert = ""
        } else {
            Log-Error "CA certificate $ExistingCert not found!"
            Log-Error "Please specify the path with -CaCert <path>, use -SkipCert, or extract it first using:"
            Log-Error "  .\bobctl get-ca-cert --output bob-ca.crt"
            exit 1
        }
    } else {
        Log-Info "Found CA Certificate: $CaCert"
    }
}

# 3. API Key Resolution
if (-not $ApiKey -and $IncludeApiKey -and $ExistingKey) {
    $ApiKey = $ExistingKey
    Log-Info "Including existing API key in package .env"
}

# ── Packaging ─────────────────────────────────────────────────────────────────

$PkgName = "bob-client-setup"
$TempBase = [System.IO.Path]::GetTempPath()
$PkgTmp = Join-Path $TempBase ([System.Guid]::NewGuid().ToString("N"))
$PkgDir = Join-Path $PkgTmp $PkgName

New-Item -ItemType Directory -Path $PkgDir -Force | Out-Null
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Log-Info "Preparing package contents in $PkgName\..."

# 1. Copy setup scripts (both Windows .ps1 and Mac/Linux .sh)
$shScript = Join-Path $ScriptDir "bob-client-setup.sh"
$psScript = Join-Path $ScriptDir "bob-client-setup.ps1"

if (Test-Path $shScript) { Copy-Item -Path $shScript -Destination (Join-Path $PkgDir "bob-client-setup.sh") }
if (Test-Path $psScript) { Copy-Item -Path $psScript -Destination (Join-Path $PkgDir "bob-client-setup.ps1") }

# 2. Copy CA certificate (if applicable)
$pkgCaPath = ""
if (-not $SkipCert -and $CaCert -and (Test-Path $CaCert)) {
    Copy-Item -Path $CaCert -Destination (Join-Path $PkgDir "bob-ca.crt")
    $pkgCaPath = "bob-ca.crt"
}

# 3. Generate pre-populated bob-client-setup.env
$envContent = @"
# bob-client-setup.env — Pre-configured for on-prem IBM Bob
# chmod 600 bob-client-setup.env

# ── Required ────────────────────────────────────────────────────────────────────
# Gateway base URL
BOB_GATEWAY_URL="$GatewayUrl"

# ── Optional ────────────────────────────────────────────────────────────────────
# Your personal Bob API key (Scope: Inference). NOT required — leave empty and
# sign in through your IdP/SSO instead. If set, the setup script stores it
# (you must still set BOB_API_KEY yourself).
# To generate one manually: $ApiKeysUrl
BOB_API_KEY="$ApiKey"

# ── CA Certificate (Optional) ────────────────────────────────────────────────────
# Leave empty for trusted CA deployments (e.g. TechZone showcase cluster).
BOB_CA_CERT_PATH="$pkgCaPath"
"@

Set-Content -Path (Join-Path $PkgDir "bob-client-setup.env") -Value $envContent -Encoding UTF8

# 4. Generate README / Instructions
$readmeContent = @"
# IBM Bob — Client Setup Kit

This package contains everything needed to connect **Bob IDE** and **Bob Shell** to your on-prem IBM Bob instance.

## Deployment Details
- **Gateway API URL:** ``$GatewayUrl``
- **Web Console / Admin UI:** ``$AdminConsoleUrl``
- **API Keys Management (optional alternative to SSO):** ``$ApiKeysUrl``

---

## Quick Setup (Automated)

### Windows (PowerShell)
Open PowerShell in this extracted folder and run:

````powershell
.\bob-client-setup.ps1
````

### macOS / Linux (Terminal)
Open Terminal in this extracted folder and run:

````bash
./bob-client-setup.sh
````

---

## What the Setup Script Does
1. Trusts the ``bob-ca.crt`` certificate in your OS trust store and copies it to ``~/bob-ca.crt`` (only when a CA cert is included in this kit).
2. Sets ``gatewayUrl`` in ``~/.bob/settings/settings.json``. **Bob IDE and Bob Shell both read this one file**, so both route to the on-prem gateway.
3. *(Only if ``BOB_API_KEY`` is set in ``bob-client-setup.env``)* Stores that API key securely.
4. Warns if an obsolete ``bob-onprem`` / ``bob-saas`` helper block from an older kit is still in your shell profile.

No shell helper functions or API key are required — you sign in through your IdP/SSO.

---

## Using IBM Bob

### 1. Bob IDE
1. Fully restart Bob IDE (close all windows / exit background process) and relaunch.
2. Sign in. It will now connect to the on-prem instance.

### 2. Bob Shell
1. Open a new terminal so it picks up ``gatewayUrl``.
2. Run Bob Shell and sign in through your IdP/SSO:
   ````text
   bob
   ````
3. Or run a single prompt:
   ````text
   bob run "Explain this project"
   ````
4. If your cluster uses a private CA, Bob Shell (Node.js) also needs ``NODE_EXTRA_CA_CERTS`` pointing at ``bob-ca.crt``:
   - **Windows PowerShell:** ``setx NODE_EXTRA_CA_CERTS "`$env:USERPROFILE\bob-ca.crt"``, then open a new terminal
   - **macOS / Linux:** add ``export NODE_EXTRA_CA_CERTS="`$HOME/bob-ca.crt"`` to ``~/.zshrc``

### 3. Switching between on-prem and SaaS
Rename the ``gatewayUrl`` key in ``~/.bob/settings/settings.json`` (for example to ``gatewayUrl-old``) or delete it, then restart Bob. Rename it back to return to on-prem. This applies to both Bob IDE and Bob Shell.

---

## Using an API key instead of SSO (optional)
If you need non-interactive access, create a personal API key at ``$ApiKeysUrl`` (Scope: **Inference**), then set it as ``BOB_API_KEY`` in the session where you run Bob Shell.
"@

Set-Content -Path (Join-Path $PkgDir "README.md") -Value $readmeContent -Encoding UTF8

$ZipOutputPath = Join-Path $OutputDir $OutputName

if ($DryRun) {
    Log-DryRun "Would create archive: $ZipOutputPath"
    Log-DryRun "Archive contents:"
    Log-DryRun "  - $PkgName/bob-client-setup.ps1"
    Log-DryRun "  - $PkgName/bob-client-setup.sh"
    Log-DryRun "  - $PkgName/bob-client-setup.env (Gateway: $GatewayUrl)"
    if (-not $SkipCert -and $CaCert) {
        Log-DryRun "  - $PkgName/bob-ca.crt"
    }
    Log-DryRun "  - $PkgName/README.md"
    Remove-Item -Path $PkgTmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# Create zip archive
if (Test-Path $ZipOutputPath) {
    Remove-Item -Path $ZipOutputPath -Force
}

Compress-Archive -Path $PkgDir -DestinationPath $ZipOutputPath -Force
Remove-Item -Path $PkgTmp -Recurse -Force -ErrorAction SilentlyContinue

Log-Info ""
Log-Info "════════════════════════════════════════════════════════════════"
Log-Info "  Client Setup Package created successfully!"
Log-Info "════════════════════════════════════════════════════════════════"
Log-Info "  File:         $ZipOutputPath"
Log-Info "  Gateway URL:  $GatewayUrl"
Log-Info "  Admin URL:    $AdminConsoleUrl"
Log-Info "  API Keys:     $ApiKeysUrl"
if ($ApiKey) {
    Log-Info "  API Key:      [Pre-populated in .env]"
} else {
    Log-Info "  API Key:      [Not included — recipients sign in via IdP/SSO]"
}
Log-Info "════════════════════════════════════════════════════════════════"
Log-Info ""
Log-Info "You can now share '$ZipOutputPath' with your team or manager."
