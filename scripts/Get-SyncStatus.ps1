#Requires -Version 7.4
<#
.SYNOPSIS
    Reports sync progress and peer counts for both clients.

.DESCRIPTION
    Port-forwards to the in-cluster RPC service, queries geth over JSON-RPC and
    Lighthouse over the standard beacon API, then closes the tunnel.

.EXAMPLE
    ./scripts/Get-SyncStatus.ps1
#>
[CmdletBinding()]
param(
    [string] $Namespace = 'ethereum',
    [int] $LocalRpcPort = 18545,
    [int] $LocalBeaconPort = 15052
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-HexQuantity([string] $Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    return [Convert]::ToInt64($Value.Substring(2), 16)
}

function Invoke-JsonRpc([string] $Method) {
    $body = @{ jsonrpc = '2.0'; id = 1; method = $Method; params = @() } | ConvertTo-Json -Compress
    (Invoke-RestMethod -Uri "http://127.0.0.1:${LocalRpcPort}" -Method Post -ContentType 'application/json' -Body $body).result
}

$tunnel = Start-Process -FilePath kubectl -PassThru -NoNewWindow -RedirectStandardOutput ([System.IO.Path]::GetTempFileName()) -ArgumentList @(
    '-n', $Namespace, 'port-forward', 'svc/ethereum-rpc', "${LocalRpcPort}:8545", "${LocalBeaconPort}:5052"
)

try {
    Start-Sleep -Seconds 3

    $syncing = Invoke-JsonRpc 'eth_syncing'
    $execution = [ordered]@{
        Client  = 'geth'
        Syncing = [bool] $syncing
        Head    = ConvertFrom-HexQuantity (Invoke-JsonRpc 'eth_blockNumber')
        Peers   = ConvertFrom-HexQuantity (Invoke-JsonRpc 'net_peerCount')
    }
    if ($syncing) {
        $current = ConvertFrom-HexQuantity $syncing.currentBlock
        $highest = ConvertFrom-HexQuantity $syncing.highestBlock
        $execution.Progress = if ($highest) { '{0:P1}' -f ($current / $highest) } else { 'unknown' }
    }

    $beaconSync  = (Invoke-RestMethod "http://127.0.0.1:${LocalBeaconPort}/eth/v1/node/syncing").data
    $beaconPeers = (Invoke-RestMethod "http://127.0.0.1:${LocalBeaconPort}/eth/v1/node/peer_count").data
    $consensus = [ordered]@{
        Client       = 'lighthouse'
        Syncing      = [bool] $beaconSync.is_syncing
        HeadSlot     = [int64] $beaconSync.head_slot
        SyncDistance = [int64] $beaconSync.sync_distance
        Peers        = [int] $beaconPeers.connected
    }

    [pscustomobject] $execution | Format-List
    [pscustomobject] $consensus | Format-List
}
finally {
    if ($tunnel -and -not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force }
}
