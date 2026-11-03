<#
.SYNOPSIS
    bob-autoinstall.ps1 — fully automated IBM Bob install for GA release on Windows.

.DESCRIPTION
    Automates the complete installation of IBM Bob on OpenShift from a Windows admin machine:
      §1 Prerequisites check (oc, helm 3.14+, openssl, config files, credentials)
      §3 cert-manager check / installation via OLM
      §4 Storage class check
      §5 Config files validation
      §6 Generate and apply cluster-scoped resources
      §7 Create pull secrets, run smoke test, invoke install with retries, poll Bob CR Available
      §9/§10 Extract CA certificate, configure Keycloak admin password, print summary

.PARAMETER DryRun
    Dry-run mode: show what commands would run without making cluster changes.

.PARAMETER Help
    Show this help message.

.EXAMPLE
    .\bob-autoinstall.ps1
    .\bob-autoinstall.ps1 -DryRun
#>

[CmdletBinding()]
param (
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

# ── Self-contained logging ────────────────────────────────────────────────────

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

$LogDir = if ($env:BOB_LOG_DIR) { $env:BOB_LOG_DIR } else { Join-Path $ScriptDir "logs" }
$LogTimestamp = (Get-Date -Format "yyyyMMdd-HHmmss")
$LogFile = Join-Path $LogDir "bob-autoinstall-$LogTimestamp.log"

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

# ── Constants ─────────────────────────────────────────────────────────────────

$OperatorNs = "ibm-bob-operators"
$InstanceNs = "ibm-bob"
$SmokeImage = "cp.icr.io/cp/bob/bob-admin@sha256:a942b8e31e1f0ce7c98a44a6c69861f3c8aa5e5a7e1395b8221976db39e0a653"
$InstallRetries = if ($env:BOBCTL_INSTALL_RETRIES) { [int]$env:BOBCTL_INSTALL_RETRIES } else { 3 }
$InstallRetryDelay = if ($env:BOBCTL_INSTALL_RETRY_DELAY) { [int]$env:BOBCTL_INSTALL_RETRY_DELAY } else { 15 }
$BobInstallTimeout = if ($env:BOB_INSTALL_TIMEOUT) { [int]$env:BOB_INSTALL_TIMEOUT } else { 1500 }
$UserHome = [Environment]::GetFolderPath("UserProfile")

# ── §1 check_prerequisites ───────────────────────────────────────────────────

function Check-Prerequisites {
    Log-Info "==> §1 Checking prerequisites"

    $envFile = Join-Path $ScriptDir "bob-autoinstall.env"
    if (-not (Test-Path $envFile)) {
        Log-Error "bob-autoinstall.env not found at $envFile"
        Log-Error "Copy bob-autoinstall.env.example to bob-autoinstall.env and fill in your values."
        exit 1
    }

    # Load env file without leaking credentials
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $key = $parts[0].Trim()
            $val = $parts[1].Trim().Trim("'`"")
            [Environment]::SetEnvironmentVariable($key, $val, "Process")
        }
    }

    $entitlementKey = [Environment]::GetEnvironmentVariable("IBM_ENTITLEMENT_KEY", "Process")
    if (-not $entitlementKey) {
        Log-Error "IBM_ENTITLEMENT_KEY is not set in bob-autoinstall.env"
        exit 1
    }

    # Tool checks
    $missing = 0
    foreach ($tool in @("oc", "helm", "openssl")) {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Log-Error "Required tool not found: $tool"
            $missing++
        }
    }
    if ($missing -gt 0) { exit 1 }

    # Helm version check (>= 3.14.0)
    $helmVerRaw = helm version --short 2>$null
    if ($helmVerRaw -match 'v?(\d+)\.(\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $helmVer = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
        if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 14)) {
            Log-Error "helm 3.14.0+ is required (found: $helmVer)"
            exit 1
        }
    } else {
        Log-Warn "Could not parse Helm version — continuing"
        $helmVer = "unknown"
    }

    # oc login check
    $whoami = oc whoami 2>$null
    if (-not $whoami) {
        Log-Error "oc is not logged in — run 'oc login ...' before continuing"
        exit 1
    }

    # config files
    if (-not (Test-Path (Join-Path $ScriptDir "config.yaml"))) {
        Log-Error "config.yaml not found in $ScriptDir"
        Log-Error "Create it from config-template.yaml: cp config-template.yaml config.yaml"
        exit 1
    }

    if (-not (Test-Path (Join-Path $ScriptDir "model-gateway.yaml"))) {
        Log-Error "model-gateway.yaml not found in $ScriptDir"
        exit 1
    }

    $server = oc whoami --show-server 2>$null
    Log-Info "    Prerequisites: OK"
    Log-Info "    Cluster: $server"
    Log-Info "    User:    $whoami"
    Log-Info "    Helm:    $helmVer"
}

# ── §3 install_cert_manager ──────────────────────────────────────────────────

function Install-CertManager {
    Log-Info "==> §3 Checking / installing cert-manager"

    $hasCrd = oc get crd certificates.cert-manager.io 2>$null
    if ($hasCrd) {
        $version = oc get csv -n cert-manager-operator -o jsonpath='{.items[0].spec.version}' 2>$null
        Log-Info "    cert-manager already installed ($version) — skipping"
        return
    }

    Log-Info "    cert-manager not found — installing via OLM"

    if ($DryRun) {
        Log-DryRun "oc new-project cert-manager-operator"
        Log-DryRun "oc apply -f <OperatorGroup>"
        Log-DryRun "oc apply -f <Subscription>"
        return
    }

    oc new-project cert-manager-operator 2>$null | Out-Null

    $ogYaml = @"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
"@
    $ogYaml | oc apply -f - 2>&1 | Tee-Object -FilePath $LogFile -Append

    $subYaml = @"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
"@
    $subYaml | oc apply -f - 2>&1 | Tee-Object -FilePath $LogFile -Append

    Log-Info "    Waiting for cert-manager CSV to reach Succeeded (up to 3 min)..."
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        $phase = oc get csv -n cert-manager-operator -o jsonpath='{.items[0].status.phase}' 2>$null
        if ($phase -eq "Succeeded") {
            Log-Info "    cert-manager CSV: Succeeded"
            return
        }
        Start-Sleep -Seconds 10
    }
    Log-Error "cert-manager did not reach Succeeded within 3 minutes"
    exit 1
}

# ── §4 deploy_nfs_provisioner ────────────────────────────────────────────────

function Deploy-NfsProvisioner {
    Log-Info "==> §4 Checking storage classes"

    $sc1 = oc get sc ocs-storagecluster-cephfs 2>$null
    $sc2 = oc get sc ocs-storagecluster-ceph-rbd 2>$null
    if ($sc1 -and $sc2) {
        Log-Info "    ODF storage classes present — NFS provisioner not needed"
        return
    }

    Log-Warn "    ODF storage classes not found — NFS provisioner may be required."
    Log-Warn "    If your config.yaml already specifies a valid RWX class, this warning can be ignored."
    Log-Warn "    See Appendix G of the install guide to deploy the managed NFS provisioner manually."
}

# ── §5 validate_config_files ─────────────────────────────────────────────────

function Validate-ConfigFiles {
    Log-Info "==> §5 Validating config files"

    foreach ($f in @("config.yaml", "model-gateway.yaml")) {
        $p = Join-Path $ScriptDir $f
        if (-not (Test-Path $p) -or (Get-Item $p).Length -eq 0) {
            Log-Error "$f is missing or empty"
            exit 1
        }
        Log-Info "    $f: OK"
    }
}

# ── §6 generate_cluster_resources ────────────────────────────────────────────

function Generate-ClusterResources {
    Log-Info "==> §6 Generating and applying cluster-scoped resources"

    $workDir = Join-Path $ScriptDir "work"
    $clusterFile = Join-Path $workDir "cluster-resources.yaml"

    if ($DryRun) {
        Log-DryRun "Render cluster resources via helm template"
        Log-DryRun "oc apply -f work/cluster-resources.yaml --force-conflicts --server-side"
        return
    }

    if (-not (Test-Path $workDir)) {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    }

    $clusterChartDir = Join-Path $ScriptDir "charts\ibm-bob-cluster-scoped"
    $configFile = Join-Path $ScriptDir "config.yaml"

    helm template ibm-bob-cluster-scoped "$clusterChartDir" -f "$configFile" --set "opencontent-opensearch.enabled=true" > "$clusterFile"
    oc apply -f "$clusterFile" --force-conflicts --server-side 2>&1 | Tee-Object -FilePath $LogFile -Append

    Log-Info "    Cluster-scoped resources applied"

    $ns1 = oc get namespace $OperatorNs 2>$null
    $ns2 = oc get namespace $InstanceNs 2>$null
    if (-not $ns1 -or -not $ns2) {
        Log-Error "Namespaces $OperatorNs and/or $InstanceNs not found after apply"
        exit 1
    }
}

# ── §7a create_pull_secrets ──────────────────────────────────────────────────

function Create-PullSecrets {
    Log-Info "==> §7a Creating ibm-entitlement-key pull secret"

    $entitlementKey = [Environment]::GetEnvironmentVariable("IBM_ENTITLEMENT_KEY", "Process")

    if ($DryRun) {
        Log-DryRun "oc create secret docker-registry ibm-entitlement-key --namespace $OperatorNs [...]"
        Log-DryRun "oc create secret docker-registry ibm-entitlement-key --namespace $InstanceNs [...]"
        return
    }

    foreach ($ns in @($OperatorNs, $InstanceNs)) {
        $secretYaml = oc create secret docker-registry ibm-entitlement-key `
            --namespace $ns `
            --docker-server="cp.icr.io" `
            --docker-username="cp" `
            --docker-password="$entitlementKey" `
            --dry-run=client -o yaml

        $labeledYaml = $secretYaml | oc label --local -f - app.kubernetes.io/managed-by=Helm -o yaml
        $annotatedYaml = $labeledYaml | oc annotate --local -f - meta.helm.sh/release-name=ibm-bob meta.helm.sh/release-namespace=ibm-bob -o yaml
        $annotatedYaml | oc apply -f - 2>&1 | Tee-Object -FilePath $LogFile -Append

        Log-Info "    ibm-entitlement-key created/updated in namespace $ns"
    }
}

# ── §7b run_smoke_test ───────────────────────────────────────────────────────

function Run-SmokeTest {
    Log-Info "==> §7b Running image pull smoke test"

    if ($DryRun) {
        Log-DryRun "oc run test-pull --image=$SmokeImage --namespace $InstanceNs [...]"
        return
    }

    oc delete pod test-pull -n $InstanceNs --ignore-not-found 2>$null | Out-Null

    $overrideJson = '{"spec":{"imagePullSecrets":[{"name":"ibm-entitlement-key"}]}}'
    oc run test-pull --namespace $InstanceNs --image="$SmokeImage" --overrides="$overrideJson" --restart=Never 2>&1 | Tee-Object -FilePath $LogFile -Append

    Log-Info "    Waiting 20s for pull to complete..."
    Start-Sleep -Seconds 20

    $status = oc get pod test-pull -n $InstanceNs -o jsonpath='{.status.phase}' 2>$null
    $reason = oc get pod test-pull -n $InstanceNs -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>$null

    Log-Info "    Smoke test pod status: $status (waiting reason: $reason)"
    oc delete pod test-pull -n $InstanceNs --ignore-not-found 2>$null | Out-Null

    if ($reason -eq "ImagePullBackOff" -or $reason -eq "ErrImagePull") {
        Log-Error "Smoke test FAILED — image pull error: $reason"
        Log-Error "Verify IBM_ENTITLEMENT_KEY is valid for cp.icr.io"
        exit 1
    }

    Log-Info "    Smoke test PASSED — image pull succeeded"
}

# ── §7c run_install ──────────────────────────────────────────────────────────

function Run-Install {
    Log-Info "==> §7c Running Bob install (up to $InstallRetries attempts)"

    $entitlementKey = [Environment]::GetEnvironmentVariable("IBM_ENTITLEMENT_KEY", "Process")
    $chartDir = Join-Path $ScriptDir "charts\ibm-bob"
    $configFile = Join-Path $ScriptDir "config.yaml"
    $modelConfigFile = Join-Path $ScriptDir "model-gateway.yaml"

    $attempt = 1
    while ($attempt -le $InstallRetries) {
        Log-Info "    Install attempt $attempt/$InstallRetries"

        if ($DryRun) {
            Log-DryRun "helm upgrade --install ibm-bob '$chartDir' -n $OperatorNs --reset-then-reuse-values ..."
            break
        }

        # Check if bobctl is runnable directly (e.g. bash available) or execute helm upgrade --install directly
        $bashCmd = Get-Command "bash" -ErrorAction SilentlyContinue
        $installed = $false

        if ($bashCmd -and (Test-Path (Join-Path $ScriptDir "bobctl"))) {
            Log-Info "    Invoking ./bobctl install via bash..."
            & bash -c "./bobctl install --accept-license --model-config model-gateway.yaml --registry-creds 'cp:$entitlementKey'" 2>&1 | Tee-Object -FilePath $LogFile -Append
            if ($LASTEXITCODE -eq 0) { $installed = $true }
        } else {
            Log-Info "    Running Helm install directly..."
            $helmArgs = @(
                "upgrade", "--install", "ibm-bob", "$chartDir",
                "--namespace", "$OperatorNs",
                "--reset-then-reuse-values",
                "-f", "$configFile",
                "--set", "global.imagePullSecret.password=$entitlementKey",
                "--set-file", "bob.modelGateway.config=$modelConfigFile"
            )
            helm @helmArgs 2>&1 | Tee-Object -FilePath $LogFile -Append
            if ($LASTEXITCODE -eq 0) { $installed = $true }
        }

        if ($installed) {
            Log-Info "    Bob install succeeded"
            break
        }

        if ($attempt -ge $InstallRetries) {
            Log-Error "Bob install failed after $InstallRetries attempts"
            exit 1
        }

        Log-Warn "    Install attempt $attempt failed — retrying in ${InstallRetryDelay}s..."
        Start-Sleep -Seconds $InstallRetryDelay
        $attempt++
    }

    if ($DryRun) {
        Log-DryRun "Polling Bob CR for Available: True (timeout ${BobInstallTimeout}s)"
        return
    }

    Log-Info "    Polling Bob CR for Available: True (timeout ${BobInstallTimeout}s)..."
    $deadline = (Get-Date).AddSeconds($BobInstallTimeout)

    while ((Get-Date) -lt $deadline) {
        $avail = oc get bob -n $InstanceNs -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>$null
        if ($avail -eq "True") {
            Log-Info "    Bob CR Available: True — install complete"
            return
        }
        $timeStr = (Get-Date -Format "HH:mm:ss")
        Log-Info "    $timeStr — Available: $avail — waiting..."
        Start-Sleep -Seconds 15
    }

    Log-Error "Timed out (${BobInstallTimeout}s) waiting for Bob CR Available: True"
    exit 1
}

# ── §9/§10 post_install_admin ────────────────────────────────────────────────

function Wait-KeycloakReady {
    param(
        [string]$Namespace,
        [int]$TimeoutSeconds = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Log-Info "    Waiting for bob-keycloak-0 to be Ready (timeout ${TimeoutSeconds}s)..."

    while ((Get-Date) -lt $deadline) {
        $phase = oc get pod bob-keycloak-0 -n $Namespace -o jsonpath='{.status.phase}' 2>$null
        $containerName = oc get pod bob-keycloak-0 -n $Namespace -o jsonpath='{.spec.containers[0].name}' 2>$null
        $ready = oc get pod bob-keycloak-0 -n $Namespace -o jsonpath='{.status.containerStatuses[0].ready}' 2>$null

        if ($phase -eq "Running" -and $ready -eq "true" -and $containerName) {
            Log-Info "    bob-keycloak-0 is Ready (container: $containerName)"
            return $containerName
        }
        $timeStr = (Get-Date -Format "HH:mm:ss")
        Log-Info "    $timeStr — keycloak pod phase=$phase ready=$ready — waiting..."
        Start-Sleep -Seconds 10
    }

    Log-Error "Timed out (${TimeoutSeconds}s) waiting for bob-keycloak-0 to be Ready"
    exit 1
}

function PostInstall-Admin {
    Log-Info "==> §9/§10 Post-install: CA cert extraction and admin password"

    $bobCaDest = Join-Path $UserHome "bob-ca.crt"

    if ($DryRun) {
        Log-DryRun "Extract CA cert to $bobCaDest"
        Log-DryRun "Set Keycloak admin password via kcadm.sh"
        return
    }

    # Extract CA cert from secret
    Log-Info "    Extracting CA certificate to $bobCaDest"
    $caSecret = oc get secret bob-tls-ca -n $InstanceNs -o jsonpath='{.data.ca\.crt}' 2>$null
    if (-not $caSecret) {
        $caSecret = oc get secret bob-ca-cert -n $InstanceNs -o jsonpath='{.data.tls\.crt}' 2>$null
    }

    if ($caSecret) {
        $bytes = [Convert]::FromBase64String($caSecret)
        [System.IO.File]::WriteAllBytes($bobCaDest, $bytes)
        openssl x509 -in "$bobCaDest" -noout -subject -issuer -dates 2>&1 | Tee-Object -FilePath $LogFile -Append
        Log-Info "    CA cert written to $bobCaDest"
    } else {
        Log-Warn "    Could not find CA certificate secret automatically."
    }

    # Admin password
    $adminPass = [Environment]::GetEnvironmentVariable("BOB_ADMIN_PASSWORD", "Process")
    if (-not $adminPass) {
        $secPass = Read-Host -Prompt "Enter bob-admin@bob.ibm.com password" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
        $adminPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

        if (-not $adminPass) {
            Log-Error "No password entered — aborting"
            exit 1
        }
    }

    $kcWaitTimeout = if ($env:BOB_KEYCLOAK_WAIT_TIMEOUT) { [int]$env:BOB_KEYCLOAK_WAIT_TIMEOUT } else { 120 }
    $kcContainer = Wait-KeycloakReady -Namespace $InstanceNs -TimeoutSeconds $kcWaitTimeout

    Log-Info "    Setting bob-admin@bob.ibm.com password via kcadm.sh"

    $kcPassB64 = oc get secret bob-keycloak-initial-admin -n $InstanceNs -o jsonpath='{.data.password}' 2>$null
    $kcUserB64 = oc get secret bob-keycloak-initial-admin -n $InstanceNs -o jsonpath='{.data.username}' 2>$null

    $kcPass = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kcPassB64))
    $kcUser = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($kcUserB64))

    oc exec -n $InstanceNs bob-keycloak-0 -c $kcContainer -- `
        /opt/keycloak/bin/kcadm.sh config credentials `
        --server "http://bob-keycloak-service.$InstanceNs.svc:8080" `
        --realm master `
        --user "$kcUser" `
        --password "$kcPass" `
        --config /tmp/kcadm.config 2>&1 | Tee-Object -FilePath $LogFile -Append

    $usersJson = oc exec -n $InstanceNs bob-keycloak-0 -c $kcContainer -- `
        /opt/keycloak/bin/kcadm.sh get users -r bob `
        --config /tmp/kcadm.config `
        -q email=bob-admin@bob.ibm.com 2>$null

    $bobAdminId = ""
    if ($usersJson) {
        $parsedUsers = $usersJson | ConvertFrom-Json
        if ($parsedUsers -and $parsedUsers.Count -gt 0) {
            $bobAdminId = $parsedUsers[0].id
        }
    }

    if ($bobAdminId) {
        oc exec -n $InstanceNs bob-keycloak-0 -c $kcContainer -- `
            /opt/keycloak/bin/kcadm.sh set-password -r bob `
            --config /tmp/kcadm.config `
            --userid "$bobAdminId" `
            --new-password "$adminPass" 2>&1 | Tee-Object -FilePath $LogFile -Append

        oc exec -n $InstanceNs bob-keycloak-0 -c $kcContainer -- `
            /opt/keycloak/bin/kcadm.sh update "users/$bobAdminId" -r bob `
            --config /tmp/kcadm.config `
            -s emailVerified=true 2>&1 | Tee-Object -FilePath $LogFile -Append

        Log-Info "    bob-admin@bob.ibm.com password set successfully"
    } else {
        Log-Warn "    Could not find bob-admin@bob.ibm.com user in Keycloak"
    }
}

# ── §11 Configure-Idp ────────────────────────────────────────────────────────

# Create the BobIdp CR; without one nobody can log in to the Admin UI.
# File selection: BOB_IDP_CONFIG, else .\config-idp.yaml if present, else a
# generated baseline (bob.ibm.com / bob-admin@bob.ibm.com).
# Set BOB_SKIP_IDP_CONFIG=true to skip (not recommended).
$script:IdpConfigSource = ""

function Configure-Idp {
    if ($env:BOB_SKIP_IDP_CONFIG -eq "true") {
        $script:IdpConfigSource = "skipped"
        Log-Warn "==> §11 Skipping IdP configuration (BOB_SKIP_IDP_CONFIG=true)"
        Log-Warn "    No BobIdp will exist, so NOBODY can log in until you run:"
        Log-Warn "    ./bobctl configure-idp --config config-idp.yaml (keep bob.ibm.com and bob-admin@bob.ibm.com)"
        return
    }

    $idpConfig = $env:BOB_IDP_CONFIG
    $generated = $false
    if ($idpConfig) {
        if (-not [System.IO.Path]::IsPathRooted($idpConfig)) { $idpConfig = Join-Path $ScriptDir $idpConfig }
        if (-not (Test-Path $idpConfig)) {
            Log-Error "IdP config file not found: $idpConfig"
            exit 1
        }
        $script:IdpConfigSource = $idpConfig
    } elseif (Test-Path (Join-Path $ScriptDir "config-idp.yaml")) {
        $idpConfig = Join-Path $ScriptDir "config-idp.yaml"
        $script:IdpConfigSource = $idpConfig
    } else {
        $idpConfig = Join-Path $ScriptDir "work\config-idp-default.yaml"
        $script:IdpConfigSource = "default baseline (bob.ibm.com only)"
        $generated = $true
    }

    Log-Info "==> §11 Configuring BobIdp using $($script:IdpConfigSource)"

    if ($DryRun) {
        Log-DryRun "./bobctl configure-idp --config $idpConfig"
        return
    }

    if ($generated) {
        New-Item -ItemType Directory -Force -Path (Split-Path $idpConfig) | Out-Null
        Set-Content -Path $idpConfig -Value @(
            "# Generated by bob-autoinstall.ps1 - baseline BobIdp (bootstrap admin only)",
            "domains:", "  - bob.ibm.com", "adminEmails:", "  - bob-admin@bob.ibm.com"
        )
    }

    $waitTimeout = if ($env:BOB_IDP_WAIT_TIMEOUT) { $env:BOB_IDP_WAIT_TIMEOUT } else { "600" }
    $env:BOB_IDP_WAIT_TIMEOUT = $waitTimeout
    & bash -c "./bobctl configure-idp --config '$($idpConfig -replace '\\','/')'" 2>&1 | Tee-Object -FilePath $LogFile -Append
    if ($LASTEXITCODE -ne 0) {
        Log-Error "bobctl configure-idp failed (exit code $LASTEXITCODE)"
        exit 1
    }
    Log-Info "    BobIdp applied. Verify with: oc get bobidp -n $InstanceNs"
}

# ── Summary ──────────────────────────────────────────────────────────────────

function Print-Summary {
    $clusterDomain = oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}' 2>$null
    $adminUrl = ""
    $apiUrl = ""
    if ($clusterDomain) {
        $adminUrl = "https://bob.$InstanceNs.$clusterDomain/admin"
        $apiUrl = "https://api.bob.$InstanceNs.$clusterDomain"
    }

    $bobCaDest = Join-Path $UserHome "bob-ca.crt"

    Log-Info ""
    Log-Info "════════════════════════════════════════════════════════════════"
    Log-Info "  IBM Bob install complete (Windows)"
    Log-Info "════════════════════════════════════════════════════════════════"
    if ($clusterDomain) {
        Log-Info "  Admin UI:  $adminUrl"
        Log-Info "  API:       $apiUrl"
    }
    Log-Info "  CA cert:   $bobCaDest"
    Log-Info "  Log:       $LogFile"
    if ($script:IdpConfigSource -eq "skipped") {
        Log-Info "  IdP config:  SKIPPED - no BobIdp, login will NOT work until configured"
    } elseif ($script:IdpConfigSource) {
        Log-Info "  IdP config:  $($script:IdpConfigSource)"
    }
    Log-Info "════════════════════════════════════════════════════════════════"
    Log-Info ""
    Log-Info "1. Trust the CA certificate"
    Log-Info "   Run: Import-Certificate -FilePath `"$bobCaDest`" -CertStoreLocation Cert:\CurrentUser\Root"
    Log-Info ""
    Log-Info "2. Point Bob Shell / Bob IDE at this cluster"
    Log-Info "   Set gatewayUrl in ~/.bob/settings/settings.json (shared by Shell and IDE):"
    if ($apiUrl) {
        Log-Info "     { `"gatewayUrl`": `"$apiUrl/`" }"
    } else {
        Log-Info "     { `"gatewayUrl`": `"https://api.bob.<instance-ns>.<cluster-domain>/`" }"
    }
    Log-Info "   To switch back to Bob SaaS, rename the key (e.g. `"gatewayUrl-old`") and restart Bob."
    Log-Info ""
    Log-Info "3. Sign in"
    Log-Info "   Run 'bob' (or open Bob IDE) and sign in through your IdP / SSO. No API key is required."
    Log-Info ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

function Main {
    Check-Prerequisites
    Install-CertManager
    Deploy-NfsProvisioner
    Validate-ConfigFiles
    Generate-ClusterResources
    Create-PullSecrets
    Run-SmokeTest
    Run-Install
    Configure-Idp
    PostInstall-Admin
    Print-Summary
}

Main
