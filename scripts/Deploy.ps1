#Requires -Version 7.4
<#
.SYNOPSIS
    Deploys the cluster, monitoring stack, and Ethereum Sepolia node in re-runnable phases.

.DESCRIPTION
      Infra    terraform apply (VPC, EKS, EBS CSI driver, kube-prometheus-stack)
      Secret   Engine API JWT secret shared by geth and Lighthouse (created once, never rotated by re-runs)
      Node     StorageClass, StatefulSet, Services, ServiceMonitors, PrometheusRules (Kustomize)

.EXAMPLE
    ./scripts/Deploy.ps1
.EXAMPLE
    ./scripts/Deploy.ps1 -Phase Node     # roll out a client version bump from k8s/kustomization.yaml
.EXAMPLE
    ./scripts/Deploy.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('All', 'Infra', 'Secret', 'Node')]
    [string[]] $Phase = 'All',

    [string] $Namespace = 'ethereum',

    [switch] $AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Parent $PSScriptRoot
$terraformDir = Join-Path $repoRoot 'terraform'

function Invoke-Native {
    param([Parameter(Mandatory)][string] $Command, [string[]] $Arguments = @())
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

foreach ($tool in 'terraform', 'aws', 'kubectl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool '$tool' was not found on PATH." }
}

$run = if ($Phase -contains 'All') { @('Infra', 'Secret', 'Node') } else { $Phase }

if ('Infra' -in $run -and $PSCmdlet.ShouldProcess('terraform', 'init and apply')) {
    Write-Host '==> Infra: terraform apply' -ForegroundColor Cyan
    Invoke-Native terraform @("-chdir=$terraformDir", 'init', '-input=false')
    $applyArgs = @("-chdir=$terraformDir", 'apply', '-input=false')
    if ($AutoApprove) { $applyArgs += '-auto-approve' }
    Invoke-Native terraform $applyArgs
}

if ($run | Where-Object { $_ -ne 'Infra' }) {
    $cluster = (& terraform "-chdir=$terraformDir" output -raw cluster_name)
    $region  = (& terraform "-chdir=$terraformDir" output -raw region)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read Terraform outputs. Run the Infra phase first.' }
    if ($PSCmdlet.ShouldProcess($cluster, 'update kubeconfig')) {
        Invoke-Native aws @('eks', 'update-kubeconfig', '--region', $region, '--name', $cluster)
    }
}

if ('Secret' -in $run -and $PSCmdlet.ShouldProcess("$Namespace/engine-jwt", 'create if missing')) {
    Write-Host '==> Secret: Engine API JWT' -ForegroundColor Cyan
    & kubectl create namespace $Namespace --dry-run=client -o yaml | & kubectl apply -f - | Out-Null

    & kubectl -n $Namespace get secret engine-jwt 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host '    engine-jwt already exists; keeping it.'
    }
    else {
        # 32 random bytes, hex encoded: the format both clients expect.
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $hex = [Convert]::ToHexString($bytes).ToLowerInvariant()
        Invoke-Native kubectl @('-n', $Namespace, 'create', 'secret', 'generic', 'engine-jwt', "--from-literal=jwt.hex=$hex")
    }
}

if ('Node' -in $run -and $PSCmdlet.ShouldProcess('k8s/', 'kubectl apply -k')) {
    Write-Host '==> Node: StatefulSet, services, monitoring' -ForegroundColor Cyan
    Invoke-Native kubectl @('apply', '-k', (Join-Path $repoRoot 'k8s'))
    Write-Host '    Waiting for the pod to start (initial sync then continues for hours)...'
    Invoke-Native kubectl @('-n', $Namespace, 'rollout', 'status', 'statefulset/ethereum', '--timeout=15m')
}

Write-Host 'Done. Check progress with ./scripts/Get-SyncStatus.ps1' -ForegroundColor Green
