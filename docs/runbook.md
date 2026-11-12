# Runbook

Day-2 operations for the Ethereum node. Commands are PowerShell 7.

## Check sync status

```powershell
./scripts/Get-SyncStatus.ps1
```

- geth `Syncing: True` with `Progress` rising means snap sync is underway.
- Lighthouse `SyncDistance` near 0 means it's following the head.
- Fewer than 5 geth peers or 10 Lighthouse peers for more than 15 minutes suggests egress problems; check the NAT gateway and the node's security group.

Logs:

```powershell
kubectl -n ethereum logs ethereum-0 -c geth --tail=100
kubectl -n ethereum logs ethereum-0 -c lighthouse --tail=100
```

## Alert: head stalled

1. Check both clients' logs for errors. The most common cause is the Engine API link: look for JWT or "execution endpoint" errors in Lighthouse.
2. Check peers with `Get-SyncStatus.ps1`.
3. Check disk with `kubectl -n ethereum get pvc` and the volume alerts. A full volume halts geth.
4. If one client is wedged, restart the pod: `kubectl -n ethereum delete pod ethereum-0`. The StatefulSet recreates it with the same volumes, and the 300-second grace period lets both clients shut down cleanly.

## Alert: volume filling up

Expand the PVC online. The StorageClass allows expansion, and the EBS volume and filesystem grow without a restart.

```powershell
kubectl -n ethereum patch pvc execution-data-ethereum-0 `
  -p '{"spec":{"resources":{"requests":{"storage":"1500Gi"}}}}'
kubectl -n ethereum get pvc execution-data-ethereum-0 -w
```

Also raise the size in `k8s/statefulset.yaml` so a rebuilt StatefulSet asks for the new size. `volumeClaimTemplates` can't be changed on a live StatefulSet, so delete the StatefulSet with `--cascade=orphan` (the pod and PVCs stay) and re-apply.

## Upgrade a client

1. Read the release notes for breaking flag changes and database migrations.
2. Change the tag in `k8s/kustomization.yaml` under `images`.
3. Apply: `./scripts/Deploy.ps1 -Phase Node`.
4. Watch logs and `Get-SyncStatus.ps1` until both clients are following the head again.

To roll back, revert the tag and re-apply. A release that migrated the database may not run older versions, so check before upgrading.

## Replace the node

The node group runs in one AZ, so a replacement node can reattach the volumes.

1. Add capacity first: set the `blockchain` node group's `desired_size` to 2 in `terraform/main.tf` and apply (or raise it in the console). Wait for the new node to be `Ready`.
2. Drain the old node:

   ```powershell
   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
   ```

   `ethereum-0` stops gracefully, its volumes detach, and the pod restarts on the new node in the same AZ.
3. Set `desired_size` back to 1. The managed node group removes a node; if it picks the one now running `ethereum-0`, the pod reschedules once more.

## Rotate the Engine API JWT

```powershell
kubectl -n ethereum delete secret engine-jwt
./scripts/Deploy.ps1 -Phase Secret
kubectl -n ethereum delete pod ethereum-0   # both clients pick up the new secret together
```
