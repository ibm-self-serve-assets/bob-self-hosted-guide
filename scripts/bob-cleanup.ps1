<#
.SYNOPSIS
    bob-cleanup.ps1 — Full cluster cleanup for a dedicated IBM Bob OpenShift cluster on Windows.

.DESCRIPTION
    Returns the OpenShift cluster to its post-provisioning, pre-Bob-install state so Bob
    can be reinstalled from scratch.

.PARAMETER DryRun
    Dry-run mode: show what would be deleted without making any cluster changes.

.PARAMETER Yes
    Skip confirmation prompt.

.PARAMETER InstallDir
    Override path to the ibm-bob-install-* directory.

.PARAMETER Help
    Show this help message.

.EXAMPLE
    .\scripts\bob-cleanup.ps1 -DryRun
    .\scripts\bob-cleanup.ps1 -Yes
    .\scripts\bob-cleanup.ps1 -InstallDir "..\ibm-bob-install-20260924-163534"
#>

[CmdletBinding()]
param (
    [Alias("dry-run")]
    [switch]$DryRun,

    [Alias("yes", "y")]
    [switch]$Yes,

    [Alias("install-dir")]
    [string]$InstallDir = "",

    [Alias("h", "?")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit 0
}

# ── 1. Locate directories ───────────────────────────────────────────────────────

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$WorkspaceRoot = Split-Path -Parent $ScriptDir

$BobDir = ""
if ($InstallDir) {
    $BobDir = $InstallDir
} elseif (Test-Path (Join-Path $WorkspaceRoot "ibm-bob-install-20260924-163534")) {
    $BobDir = Join-Path $WorkspaceRoot "ibm-bob-install-20260924-163534"
} else {
    $installMatches = Get-ChildItem -Path $WorkspaceRoot -Directory -Filter "ibm-bob-install-*" -ErrorAction SilentlyContinue
    if (-not $installMatches -or $installMatches.Count -eq 0) {
        Write-Error "ERROR: No install package directory (ibm-bob-install-*) found at $WorkspaceRoot. Specify -InstallDir <path>"
        exit 1
    } elseif ($installMatches.Count -gt 1) {
        Write-Host "ERROR: Multiple install package directories found:" -ForegroundColor Red
        foreach ($m in $installMatches) {
            Write-Host "  - $($m.FullName)" -ForegroundColor Red
        }
        Write-Error "Specify which to use with -InstallDir <path>"
        exit 1
    }
    $BobDir = $installMatches[0].FullName
}

$BobLogDir = if ($env:BOB_LOG_DIR) { $env:BOB_LOG_DIR } else { Join-Path $WorkspaceRoot "logs" }
$BobWorkDir = if ($env:BOB_WORK_DIR) { $env:BOB_WORK_DIR } else { Join-Path $BobDir "work" }
$BobConfigFile = if ($env:BOB_CONFIG_FILE) { $env:BOB_CONFIG_FILE } else { Join-Path $BobDir "config.yaml" }

# ── 2. Logging Setup ────────────────────────────────────────────────────────────

$LogTimestamp = (Get-Date -Format "yyyyMMdd-HHmmss")
if (-not (Test-Path $BobLogDir)) {
    New-Item -ItemType Directory -Path $BobLogDir -Force | Out-Null
}
$LogFile = Join-Path $BobLogDir "bobctl-cleanup-$LogTimestamp.log"
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

Log-Info "Log file: $LogFile"
Log-Info "Install package: $BobDir"
Log-Info "Config file: $BobConfigFile"

# ── 3. Helper Functions ─────────────────────────────────────────────────────────

function Check-Tools {
    $helmCmd = Get-Command "helm" -ErrorAction SilentlyContinue
    if (-not $helmCmd) {
        Log-Error "helm command not found on PATH"
        exit 1
    }
    $ocCmd = Get-Command "oc" -ErrorAction SilentlyContinue
    if (-not $ocCmd) {
        Log-Error "oc command not found on PATH"
        exit 1
    }
    $whoami = oc whoami 2>$null
    if (-not $whoami) {
        Log-Error "oc is not logged in to an OpenShift cluster"
        exit 1
    }
}

function Read-ConfigValue {
    param(
        [string]$Key,
        [string]$FilePath
    )
    if (-not (Test-Path $FilePath)) { return "" }
    $val = ""
    Get-Content $FilePath | ForEach-Object {
        $line = $_.Trim()
        if ($line.StartsWith("$Key`:") -or $line.StartsWith("$Key ")) {
            $parts = $line.Split(":", 2)
            if ($parts.Length -ge 2) {
                $val = $parts[1].Trim().Trim("'`"")
            }
        }
    }
    return $val
}

# ── 4. Verification ─────────────────────────────────────────────────────────────

function Verify-Cleanup {
    param(
        [string]$OperatorNamespace,
        [string]$InstanceNamespace
    )
    $allClean = $true

    # 1. Bob CR
    if ($DryRun) {
        Log-DryRun "Would check: Bob CR deleted in '$InstanceNamespace'"
    } else {
        $bobCr = oc get bob -n $InstanceNamespace --ignore-not-found 2>$null
        if ($bobCr) {
            Log-Info "  ✗ Bob CR still present in namespace '$InstanceNamespace'"
            $allClean = $false
        } else {
            Log-Info "  ✓ No Bob CRs found in namespace '$InstanceNamespace'"
        }
    }

    # 2. Helm release
    if ($DryRun) {
        Log-DryRun "Would check: Helm release 'ibm-bob' absent in '$OperatorNamespace'"
    } else {
        $helmRel = helm list -n $OperatorNamespace --short 2>$null | Where-Object { $_ -eq "ibm-bob" }
        if ($helmRel) {
            Log-Info "  ✗ Helm release 'ibm-bob' still present in namespace '$OperatorNamespace'"
            $allClean = $false
        } else {
            Log-Info "  ✓ No Helm release 'ibm-bob' found in namespace '$OperatorNamespace'"
        }
    }

    # 3. Non-Helm extras
    if ($DryRun) {
        Log-DryRun "Would check: entitlement secrets and bob-metrics-forwarder absent"
    } else {
        $leftoverExtras = $false
        foreach ($ns in @($OperatorNamespace, $InstanceNamespace)) {
            $s1 = oc get secret ibm-entitlement-key -n $ns --ignore-not-found 2>$null
            if ($s1) {
                Log-Info "  ✗ Secret 'ibm-entitlement-key' still present in namespace '$ns'"
                $leftoverExtras = $true
                $allClean = $false
            }
            $s2 = oc get secret ibm-prod-entitlement-key -n $ns --ignore-not-found 2>$null
            if ($s2) {
                Log-Info "  ✗ Secret 'ibm-prod-entitlement-key' still present in namespace '$ns'"
                $leftoverExtras = $true
                $allClean = $false
            }
        }
        $mf = oc get deployment bob-metrics-forwarder -n $InstanceNamespace --ignore-not-found 2>$null
        if ($mf) {
            Log-Info "  ✗ Deployment 'bob-metrics-forwarder' still present in namespace '$InstanceNamespace'"
            $allClean = $false
        }
        if (-not $leftoverExtras) {
            Log-Info "  ✓ No non-Helm extras (entitlement secrets, metrics forwarder) found"
        }
    }

    # 4. PVCs
    if ($DryRun) {
        Log-DryRun "Would check: no PVCs in both namespaces"
    } else {
        $leftoverPvcs = $false
        foreach ($ns in @($OperatorNamespace, $InstanceNamespace)) {
            $pvcs = oc get pvc -n $ns --ignore-not-found --no-headers 2>$null
            if ($pvcs) {
                Log-Info "  ✗ PVCs still present in namespace '$ns'"
                $leftoverPvcs = $true
                $allClean = $false
            }
        }
        if (-not $leftoverPvcs) {
            Log-Info "  ✓ No PVCs found in either namespace"
        }
    }

    # 5. Namespaces
    if ($DryRun) {
        Log-DryRun "Would check: both namespaces deleted"
    } else {
        $leftoverNs = $false
        foreach ($ns in @($OperatorNamespace, $InstanceNamespace)) {
            $nsObj = oc get namespace $ns --ignore-not-found 2>$null
            if ($nsObj) {
                Log-Info "  ✗ Namespace '$ns' still exists"
                $leftoverNs = $true
                $allClean = $false
            }
        }
        if (-not $leftoverNs) {
            Log-Info "  ✓ Both namespaces ('$OperatorNamespace', '$InstanceNamespace') have been deleted"
        }
    }

    # 6. CRDs
    if ($DryRun) {
        Log-DryRun "Would check: no Bob-related CRDs remain"
    } else {
        $crds = oc get crd 2>$null | Select-String -Pattern 'bob\.ibm|bobidp\.bob|pg\.ibm\.com|redis\.ibm\.com|opensearch\.ibm|keycloak\.org|ibmlicensing|ibmusagemetering'
        if ($crds) {
            Log-Info "  ✗ Bob-related CRDs still present:"
            $crds | ForEach-Object { Log-Info "    $_" }
            $allClean = $false
        } else {
            Log-Info "  ✓ No Bob-related CRDs found"
        }
    }

    if ($allClean) {
        Log-Info ""
        Log-Info "✓ Cluster is clean — all Bob resources have been removed."
    } else {
        Log-Warn ""
        Log-Warn "✗ Cluster is NOT fully clean — some resources remain (see above)."
    }
}

# ── 5. Main Cleanup Workflow ────────────────────────────────────────────────────

function Main {
    Log-Info "=== Bob Cluster Cleanup (Windows) ==="
    if ($DryRun) {
        Log-DryRun "Dry-run mode enabled — no changes will be made to the cluster"
    }

    Check-Tools

    $sourceConfig = $BobConfigFile
    if (-not (Test-Path $sourceConfig)) {
        $template = Join-Path $BobDir "config-template.yaml"
        if (Test-Path $template) {
            $sourceConfig = $template
            Log-Info "config.yaml not found — reading default namespaces from config-template.yaml"
        }
    }

    $operatorNamespace = Read-ConfigValue "operatorNamespace" $sourceConfig
    $instanceNamespace = Read-ConfigValue "instanceNamespace" $sourceConfig

    if (-not $operatorNamespace) { $operatorNamespace = "ibm-bob-operators" }
    if (-not $instanceNamespace) { $instanceNamespace = "ibm-bob" }

    $crName = ""
    if ($DryRun) {
        $crName = "bob-cr"
    } else {
        $rawCr = oc get bob -n $instanceNamespace -o name 2>$null | Select-Object -First 1
        if ($rawCr) {
            $crName = $rawCr.Split("/")[-1]
        }
    }

    Log-Info "Namespace (operator):   $operatorNamespace"
    Log-Info "Namespace (instance):   $instanceNamespace"
    Log-Info "Bob CR name:            $crName"

    if (-not $Yes -and -not $DryRun) {
        Log-Warn "WARNING: This will permanently delete ALL IBM Bob resources, including:"
        Log-Warn "  - Bob CR and the operator's reconciled child resources"
        Log-Warn "  - Helm release 'ibm-bob' (operator deployment, RBAC, configmaps, secrets)"
        Log-Warn "  - Non-Helm extras (entitlement pull secrets, bob-metrics-forwarder)"
        Log-Warn "  - ALL PVCs in both namespaces"
        Log-Warn "  - BOTH namespaces: '$operatorNamespace' and '$instanceNamespace'"
        Log-Warn "  - Cluster-scoped resources (CRDs, ClusterRoles, webhook configs)"
        Log-Warn "This operation cannot be undone."
        $reply = Read-Host "Continue? [y/N]"
        if ($reply -ne "y" -and $reply -ne "Y") {
            Log-Info "Aborted."
            exit 0
        }
    }

    # Step 1: Delete Bob CR
    if ($crName) {
        Log-Info "Step 1: Deleting Bob CR '$crName' in namespace '$instanceNamespace'..."
        if ($DryRun) {
            Log-DryRun "Would delete bob/$crName in namespace '$instanceNamespace'"
        } else {
            oc delete bob $crName -n $instanceNamespace --ignore-not-found 2>&1 | Tee-Object -FilePath $LogFile -Append
        }

        # Step 2: Wait for Bob CR deletion
        Log-Info "Step 2: Waiting for Bob CR '$crName' to be deleted..."
        $timeout = if ($env:BOB_INSTALL_TIMEOUT) { [int]$env:BOB_INSTALL_TIMEOUT } else { 300 }
        if ($DryRun) {
            Log-DryRun "Would wait for deletion of bob/$crName (timeout: ${timeout}s)"
        } else {
            try {
                oc wait --for=delete "bob/$crName" -n $instanceNamespace --timeout="${timeout}s" 2>&1 | Tee-Object -FilePath $LogFile -Append
                Log-Info "Bob CR '$crName' has been deleted."
            } catch {
                Log-Error "Timed out waiting for Bob CR '$crName' to be deleted (timeout: ${timeout}s)"
                oc get bob $crName -n $instanceNamespace -o jsonpath='{.metadata.finalizers}' 2>$null | Tee-Object -FilePath $LogFile -Append
                exit 1
            }
        }
    } else {
        Log-Info "Step 1: No Bob CR found in namespace '$instanceNamespace' — skipping"
        Log-Info "Step 2: No Bob CR to wait on — skipping"
    }

    # Step 3: Helm uninstall
    Log-Info "Step 3: Uninstalling Helm release 'ibm-bob' in namespace '$operatorNamespace'..."
    if ($DryRun) {
        Log-DryRun "Would check if Helm release 'ibm-bob' exists, then uninstall it"
    } else {
        $hasRel = helm list -n $operatorNamespace --short 2>$null | Where-Object { $_ -eq "ibm-bob" }
        if ($hasRel) {
            helm uninstall ibm-bob -n $operatorNamespace 2>&1 | Tee-Object -FilePath $LogFile -Append
            Log-Info "Helm release 'ibm-bob' uninstalled."
        } else {
            Log-Info "Helm release 'ibm-bob' not found — skipping uninstall (idempotent)"
        }
    }

    # Step 4: Delete non-Helm extras
    Log-Info "Step 4: Deleting non-Helm extras..."
    if ($DryRun) {
        Log-DryRun "Would delete secrets 'ibm-entitlement-key' and 'ibm-prod-entitlement-key' in both namespaces"
        Log-DryRun "Would delete deployment 'bob-metrics-forwarder' in namespace '$instanceNamespace'"
    } else {
        foreach ($ns in @($operatorNamespace, $instanceNamespace)) {
            oc delete secret ibm-entitlement-key -n $ns --ignore-not-found 2>&1 | Tee-Object -FilePath $LogFile -Append
            oc delete secret ibm-prod-entitlement-key -n $ns --ignore-not-found 2>&1 | Tee-Object -FilePath $LogFile -Append
        }
        oc delete deployment bob-metrics-forwarder -n $instanceNamespace --ignore-not-found 2>&1 | Tee-Object -FilePath $LogFile -Append
    }

    # Step 5: Delete all PVCs
    Log-Info "Step 5: Deleting all PVCs in both namespaces..."
    if ($DryRun) {
        Log-DryRun "Would delete all PVCs in namespaces: '$operatorNamespace', '$instanceNamespace'"
    } else {
        foreach ($ns in @($operatorNamespace, $instanceNamespace)) {
            oc delete pvc --all -n $ns --ignore-not-found 2>&1 | Tee-Object -FilePath $LogFile -Append
        }
    }

    # Step 6: Delete namespaces
    Log-Info "Step 6: Deleting namespaces '$operatorNamespace' and '$instanceNamespace'..."
    if ($DryRun) {
        Log-DryRun "Would delete namespaces: '$operatorNamespace', '$instanceNamespace'"
    } else {
        oc delete namespace $operatorNamespace $instanceNamespace --ignore-not-found 2>&1 | Tee-Object -FilePath $LogFile -Append
    }

    # Step 7: Delete cluster-scoped resources
    Log-Info "Step 7: Deleting cluster-scoped resources (CRDs, ClusterRoles, webhooks)..."
    $clusterResourcesFile = Join-Path $BobWorkDir "cluster-resources.yaml"

    if (-not (Test-Path $clusterResourcesFile)) {
        Log-Warn "work\cluster-resources.yaml not found — rendering cluster-scoped chart templates..."
        if ($DryRun) {
            Log-DryRun "Would render cluster-scoped resources to $clusterResourcesFile"
        } else {
            if (-not (Test-Path $BobWorkDir)) {
                New-Item -ItemType Directory -Path $BobWorkDir -Force | Out-Null
            }
            $clusterChartDir = Join-Path $BobDir "charts\ibm-bob-cluster-scoped"
            helm template ibm-bob-cluster-scoped "$clusterChartDir" -f "$sourceConfig" --set "opencontent-opensearch.enabled=true" > "$clusterResourcesFile"
            Log-Info "Cluster-scoped resources rendered to: $clusterResourcesFile"
        }
    }

    if ($DryRun) {
        Log-DryRun "Would filter Namespace resources from $clusterResourcesFile and delete remainder via 'oc delete -f -'"
    } else {
        if (Test-Path $clusterResourcesFile) {
            # Filter out Namespace documents
            $rawYaml = Get-Content -Raw -Path $clusterResourcesFile
            $docs = $rawYaml -split "(?m)^---`r?`n"
            $filteredDocs = @()
            foreach ($doc in $docs) {
                if ($doc.Trim() -and $doc -notmatch "(?m)^kind:\s+Namespace\b") {
                    $filteredDocs += $doc.Trim()
                }
            }
            $cleanYaml = $filteredDocs -join "`n---`n"
            $cleanYaml | oc delete --ignore-not-found -f - 2>&1 | Tee-Object -FilePath $LogFile -Append
            Log-Info "Cluster-scoped resources deleted."
        }
    }

    # Step 8: Verification
    Log-Info ""
    Log-Info "=== Verification ==="
    Verify-Cleanup -OperatorNamespace $operatorNamespace -InstanceNamespace $instanceNamespace

    Log-Info ""
    Log-Info "=== Manual Verification Commands ==="
    Log-Info "  # Check for remaining Bob CRs:"
    Log-Info "  oc get bob -A"
    Log-Info "  # Check for remaining Helm releases:"
    Log-Info "  helm list -A | Select-String ibm-bob"
    Log-Info "  # Check for remaining CRDs:"
    Log-Info "  oc get crd | Select-String -Pattern 'bob|keycloak|pg.ibm|redis.cloud|opensearch.cloud|ibmlicensing|ibmusagemetering'"
    Log-Info "  # Check for remaining PVCs:"
    Log-Info "  oc get pvc -n $operatorNamespace -n $instanceNamespace"
    Log-Info "  # Check for remaining namespaces:"
    Log-Info "  oc get namespace $operatorNamespace $instanceNamespace"
    Log-Info ""
    Log-Info "Cleanup complete. Log file: $LogFile"
}

Main
