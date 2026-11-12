#Requires -Version 7.4
<#
.SYNOPSIS
    Removes the node and its volumes, then destroys the infrastructure.

.DESCRIPTION
    Deleting a StatefulSet does NOT delete its PersistentVolumeClaims. This script deletes
    the PVCs explicitly and waits for the EBS volumes to be released before terraform destroy,
    so no orphaned (and billed) volumes are left behind.

      Node    delete Kustomize resources, PVCs, and the JWT secret
      Infra   terraform destroy
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('All', 'Node', 'Infra')]
    [string[]] $Phase = 'All',

    [string] $Namespace = 'ethereum',

    [int] $VolumeReleaseTimeoutSeconds = 600,

    [switch] $AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Parent $PSScriptRoot
$terraformDir = Join-Path $repoRoot 'terraform'

$run = if ($Phase -contains 'All') { @('Node', 'Infra') } else { $Phase }

if ('Node' -in $run -and $PSCmdlet.ShouldProcess($Namespace, 'delete node, PVCs and volumes')) {
    Write-Host '==> Node: delete StatefulSet and its volumes' -ForegroundColor Cyan
    & kubectl delete -k (Join-Path $repoRoot 'k8s') --ignore-not-found --wait=true | Out-Null
    & kubectl -n $Namespace delete pvc --all --wait=true 2>$null | Out-Null

    $deadline = (Get-Date).AddSeconds($VolumeReleaseTimeoutSeconds)
    while ($true) {
        $pvs = @(& kubectl get pv -o jsonpath="{range .items[?(@.spec.claimRef.namespace=='$Namespace')]}{.metadata.name}{'\n'}{end}" 2>$null |
            Where-Object { $_ })
        if ($pvs.Count -eq 0) { break }
        if ((Get-Date) -gt $deadline) { throw "PersistentVolumes still present: $($pvs -join ', ')" }
        Write-Host "    waiting for $($pvs.Count) volume(s) to be deleted..."
        Start-Sleep -Seconds 10
    }
    & kubectl delete namespace $Namespace --ignore-not-found --wait=true | Out-Null
}

if ('Infra' -in $run -and $PSCmdlet.ShouldProcess('terraform', 'destroy')) {
    Write-Host '==> Infra: terraform destroy' -ForegroundColor Cyan
    $destroyArgs = @("-chdir=$terraformDir", 'destroy', '-input=false')
    if ($AutoApprove) { $destroyArgs += '-auto-approve' }
    & terraform @destroyArgs
    if ($LASTEXITCODE -ne 0) { throw "terraform destroy failed with exit code $LASTEXITCODE." }
}

Write-Host 'Done.' -ForegroundColor Green
