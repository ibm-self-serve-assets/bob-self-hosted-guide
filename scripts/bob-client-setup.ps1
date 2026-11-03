<#
.SYNOPSIS
    bob-client-setup.ps1 — On-prem Bob client-side workstation setup for Windows.

.DESCRIPTION
    Automates the end-user workstation setup for on-prem Bob on Windows:
      1. Trust the CA certificate in the Windows Certificate Store (CurrentUser\Root)
      2. Set gatewayUrl in ~\.bob\settings\settings.json (shared by Bob IDE and
         Bob Shell; users then sign in through their IdP/SSO)
      3. Optionally store an API key in user-scoped DPAPI storage (only when
         BOB_API_KEY is set in the env file)
      4. Warn if an obsolete Bob Shell helper block is still in PowerShell $PROFILE

    This script is standalone — it has no `oc` dependency and requires only
    PowerShell 5.1+ (or PowerShell Core 7+).

.PARAMETER EnvFile
    Path to the .env file (default: .\bob-client-setup.env in the script's directory).

.PARAMETER SkipCert
    Skip CA certificate installation and Windows trust store import.

.PARAMETER DryRun
    Log all actions without making any changes.

.PARAMETER Help
    Show this help message.

.EXAMPLE
    .\bob-client-setup.ps1
    .\bob-client-setup.ps1 -SkipCert
    .\bob-client-setup.ps1 -EnvFile "C:\path\to\bob-client-setup.env" -DryRun
#>

[CmdletBinding()]
param (
    [Alias("env-file")]
    [string]$EnvFile = "",

    [Alias("skip-cert", "no-cert")]
    [switch]$SkipCert,

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

# ── Self-contained logging ──────────────────────────────────────────────────────

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

$LogDir = if ($env:BOB_LOG_DIR) { $env:BOB_LOG_DIR } else { Join-Path $ScriptDir "logs" }
$LogTimestamp = (Get-Date -Format "yyyyMMdd-HHmmss")
$LogFile = Join-Path $LogDir "bob-client-setup-$LogTimestamp.log"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
New-Item -ItemType File -Path $LogFile -Force | Out-Null

function Write-BobLog {
    param(
        [string]$Level,
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $logEntry = "$timestamp $Level $Message"
    Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue

    if ($env:NOCOLOR) {
        Write-Host $Message
    } else {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Log-Info {
    param([string]$Message)
    Write-BobLog "INFO " $Message -Color Green
}

function Log-Warn {
    param([string]$Message)
    Write-BobLog "WARN " $Message -Color Yellow
}

function Log-Error {
    param([string]$Message)
    Write-BobLog "ERROR" $Message -Color Red
}

function Log-DryRun {
    param([string]$Message)
    Write-BobLog "DRY  " "[DRY-RUN] $Message" -Color Yellow
}

# ── Constants ───────────────────────────────────────────────────────────────────

$UserHome = [Environment]::GetFolderPath("UserProfile")
$BobDir = Join-Path $UserHome ".bob"
$BobSettingsDir = Join-Path $BobDir "settings"
$BobSettingsFile = Join-Path $BobSettingsDir "settings.json"
$BobCaFile = Join-Path $UserHome "bob-ca.crt"
$BobApiKeyFile = Join-Path $BobDir "bob-api-key.dat"
# Marker written to $PROFILE by older versions of this script. It is no longer
# written; it is only used to warn that the old block is obsolete.
$PsMarker = "# ── Bob Shell environment helpers"

# ── Locate and Load Env File ───────────────────────────────────────────────────

if (-not $EnvFile) {
    $EnvFile = Join-Path $ScriptDir "bob-client-setup.env"
}

function Load-EnvFile {
    if (-not (Test-Path $EnvFile)) {
        Log-Error "Env file not found: $EnvFile"
        Log-Error "Copy bob-client-setup.env.example to bob-client-setup.env and fill in your values."
        exit 1
    }

    Log-Info "Loading env file: $EnvFile"

    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $key = $parts[0].Trim()
            $val = $parts[1].Trim().Trim("'`"")
            [Environment]::SetEnvironmentVariable($key, $val, "Process")
        }
    }
}

# ── Validate Environment ────────────────────────────────────────────────────────

function Validate-Env {
    $gatewayUrl = [Environment]::GetEnvironmentVariable("BOB_GATEWAY_URL", "Process")
    if (-not $gatewayUrl) {
        Log-Error "BOB_GATEWAY_URL is not set in $EnvFile"
        Log-Error "This is required — please fill it in and re-run."
        exit 1
    }

    Log-Info "Gateway URL: $gatewayUrl"
}

# ── Derive Values ───────────────────────────────────────────────────────────────

function Derive-Values {
    $script:GatewayUrl = [Environment]::GetEnvironmentVariable("BOB_GATEWAY_URL", "Process").TrimEnd("/")
    $script:BobIdeGatewayUrl = "$GatewayUrl/"

    $script:DoInstallCert = $false
    $script:CertSource = ""

    $envCertPath = [Environment]::GetEnvironmentVariable("BOB_CA_CERT_PATH", "Process")
    if ($SkipCert) {
        Log-Info "CA Cert:      Skipping (explicit -SkipCert flag)"
    } elseif (-not $envCertPath) {
        Log-Info "CA Cert:      Skipping (BOB_CA_CERT_PATH empty/unset — trusted CA assumed)"
    } else {
        $script:DoInstallCert = $true
        $script:CertSource = $envCertPath.Replace("~", $UserHome)
        if (-not [System.IO.Path]::IsPathRooted($script:CertSource)) {
            $envDir = Split-Path -Parent $EnvFile
            if ($envDir -and (Test-Path $envDir)) {
                $script:CertSource = Join-Path $envDir $script:CertSource
            } else {
                $script:CertSource = Join-Path $ScriptDir $script:CertSource
            }
        }
    }

    Log-Info "gatewayUrl:   $BobIdeGatewayUrl"
    if ($script:DoInstallCert) {
        Log-Info "CA cert src:  $CertSource"
        Log-Info "CA cert dst:  $BobCaFile"
    }
}

# ── Step 1: Install CA Certificate ──────────────────────────────────────────────

function Install-CaCert {
    if (-not $script:DoInstallCert) {
        Log-Info "=== Step 1: Install CA certificate (Skipped) ==="
        Log-Info "Skipping CA certificate installation — cluster certificate is assumed trusted by standard authorities."
        return
    }

    Log-Info "=== Step 1: Install CA certificate ==="

    if (-not (Test-Path $CertSource)) {
        Log-Warn "CA certificate not found at specified path: $CertSource"
        Log-Warn "Skipping certificate installation and continuing setup."
        return
    }

    # Copy cert to $HOME\bob-ca.crt (the path NODE_EXTRA_CA_CERTS should point at)
    if ($DryRun) {
        Log-DryRun "Would copy $CertSource -> $BobCaFile"
    } else {
        $srcFull = [System.IO.Path]::GetFullPath($CertSource)
        $dstFull = [System.IO.Path]::GetFullPath($BobCaFile)
        if ($srcFull -ne $dstFull) {
            Log-Info "Copying CA cert to $BobCaFile"
            Copy-Item -Path $CertSource -Destination $BobCaFile -Force
        } else {
            Log-Info "CA cert already at $BobCaFile — skipping copy"
        }
    }

    # Trust cert in Windows Root Store
    if ($DryRun) {
        Log-DryRun "Would import certificate to Cert:\CurrentUser\Root"
    } else {
        try {
            Log-Info "Importing certificate into CurrentUser\Root trust store..."
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($BobCaFile)
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store([System.Security.Cryptography.X509Certificates.StoreName]::Root, [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            
            # Check if cert is already in store
            $existing = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
            if ($existing) {
                Log-Warn "CA cert thumbprint $($cert.Thumbprint) already in Root store."
            } else {
                $store.Add($cert)
                Log-Info "CA cert successfully added to CurrentUser\Root store."
            }
            $store.Close()
        } catch {
            Log-Warn "Could not add to CurrentUser store via .NET API: $_"
            Log-Info "Falling back to certutil.exe..."
            certutil.exe -user -addstore Root "$BobCaFile" | Out-Null
        }
    }

    Log-Info "CA certificate installed."
}

# ── Step 2: Set gatewayUrl in settings.json ─────────────────────────────────────

function Configure-IdeSettings {
    Log-Info "=== Step 2: Set gatewayUrl in ~\.bob\settings\settings.json (Bob IDE + Bob Shell) ==="

    if ($DryRun) {
        Log-DryRun "Would create $BobSettingsDir if missing"
        Log-DryRun "Would set gatewayUrl to '$BobIdeGatewayUrl' in $BobSettingsFile"
        return
    }

    if (-not (Test-Path $BobSettingsDir)) {
        New-Item -ItemType Directory -Path $BobSettingsDir -Force | Out-Null
    }

    $settings = @{}
    if (Test-Path $BobSettingsFile) {
        Log-Info "Existing settings.json found — merging gatewayUrl"
        try {
            $rawContent = Get-Content -Raw -Path $BobSettingsFile
            if ($rawContent.Trim()) {
                $settings = $rawContent | ConvertFrom-Json -AsHashtable
            }
        } catch {
            Log-Warn "Failed to parse existing settings.json, creating a new structure."
            $settings = @{}
        }
    } else {
        Log-Info "No existing settings.json — creating new one"
    }

    $settings["gatewayUrl"] = $BobIdeGatewayUrl

    $jsonOut = $settings | ConvertTo-Json -Depth 10
    Set-Content -Path $BobSettingsFile -Value $jsonOut -Encoding UTF8

    Log-Info "Bob settings updated. gatewayUrl: $BobIdeGatewayUrl"
    Log-Warn "Tip: to switch back to SaaS, rename the 'gatewayUrl' key (e.g. 'gatewayUrl-old') or delete it in $BobSettingsFile, then restart Bob"
}

# ── Step 3: Store API Key (optional) ────────────────────────────────────────────

function Capture-AndStoreApiKey {
    $apiKey = [Environment]::GetEnvironmentVariable("BOB_API_KEY", "Process")

    if (-not $apiKey) {
        Log-Info "=== Step 3: API key (Skipped) ==="
        Log-Info "No BOB_API_KEY in env file — sign in through your IdP/SSO instead."
        Log-Info "(Optional alternative: create a key with Scope 'Inference' at $GatewayUrl/admin/apikeys"
        Log-Info " and set BOB_API_KEY in the env file, or see docs/bob-onprem-shell-setup.md.)"
        return
    }

    Log-Info "=== Step 3: Store API key (optional alternative to SSO) ==="
    Log-Info "Using API key from env file"

    if ($DryRun) {
        Log-DryRun "Would store DPAPI-encrypted API key in $BobApiKeyFile"
        return
    }

    if (-not (Test-Path $BobDir)) {
        New-Item -ItemType Directory -Path $BobDir -Force | Out-Null
    }

    try {
        # Secure storage using Windows DPAPI (Data Protection API) for CurrentUser
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($apiKey)
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [System.IO.File]::WriteAllBytes($BobApiKeyFile, $protectedBytes)
        Log-Info "API key securely stored (DPAPI encrypted) at $BobApiKeyFile"
    } catch {
        Log-Warn "DPAPI storage failed: $_. Storing in protected text file."
        Set-Content -Path (Join-Path $BobDir "bob-api-key") -Value $apiKey -Encoding UTF8
    }

    Log-Warn "Nothing loads the stored key automatically. To use it, set BOB_API_KEY in the session where you run Bob."
}

# ── Step 4: Warn about obsolete PowerShell profile helpers ─────────────────────

# Older versions of this script appended bob-onprem/bob-saas helper functions to
# $PROFILE. They are no longer needed. This only warns — it never edits the file.
function Warn-ObsoleteProfileBlock {
    $profilePath = $PROFILE
    $existingProfile = ""
    if (Test-Path $profilePath) {
        $existingProfile = Get-Content -Raw -Path $profilePath
    }

    if ($existingProfile -and $existingProfile.Contains($PsMarker)) {
        Log-Info "=== Step 4: Obsolete PowerShell `$PROFILE helpers detected ==="
        Log-Warn "$profilePath still contains the '$PsMarker' block from an older version of this script."
        Log-Warn "It is no longer needed (bob-onprem / bob-saas / BOB_AUTHN_URL). Remove the block manually."
        Log-Warn "While it exists, bob-onprem may set BOB_AUTHN_URL / BOB_API_KEY and override the settings.json flow."
    } else {
        Log-Info "=== Step 4: Obsolete PowerShell `$PROFILE helpers (none found) ==="
    }
}

# ── Main Entrypoint ─────────────────────────────────────────────────────────────

function Main {
    Log-Info "=== Bob Client-Side Setup (Windows) ==="
    Log-Info "Started: $(Get-Date)"
    Log-Info "Log file: $LogFile"
    if ($DryRun) {
        Log-Warn "DRY-RUN mode: no changes will be made"
    }
    Log-Info ""

    Load-EnvFile
    Validate-Env
    Derive-Values
    Install-CaCert
    Configure-IdeSettings
    Capture-AndStoreApiKey
    Warn-ObsoleteProfileBlock

    Log-Info ""
    Log-Info "=== Setup Complete ==="
    Log-Info ""
    Log-Info "Next steps:"
    Log-Info "  1. Restart Bob (Shell or IDE) so it picks up gatewayUrl."
    Log-Info "  2. Sign in through your IdP/SSO:"
    Log-Info "       bob               # Bob Shell, interactive"
    Log-Info "       bob run `"Explain this project`"   # Bob Shell, single prompt"
    if ($script:DoInstallCert) {
        Log-Info "  3. Private-CA cluster: Bob Shell (Node.js) does not read the Windows trust store."
        Log-Info "     Set NODE_EXTRA_CA_CERTS persistently, then open a new terminal:"
        Log-Info "       setx NODE_EXTRA_CA_CERTS `"$BobCaFile`""
    }
    Log-Info ""
    Log-Info "Bob IDE:"
    Log-Info "  - Fully quit Bob IDE (Alt+F4 / exit from tray or Task Manager) and relaunch."
    Log-Info ""
    Log-Info "Switching back to SaaS (Bob IDE and Bob Shell):"
    Log-Info "  - Rename the 'gatewayUrl' key in $BobSettingsFile (e.g. 'gatewayUrl-old')"
    Log-Info "    or delete it, then restart Bob. Rename it back to return to on-prem."
    Log-Info ""
    Log-Info "Log file: $LogFile"
}

Main
