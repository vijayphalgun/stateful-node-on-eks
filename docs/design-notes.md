# Design notes

## Why a StatefulSet, not a Deployment

A blockchain node is the textbook stateful workload: hundreds of gigabytes of local state, an identity that peers and downstream services rely on, and a database that's expensive to rebuild. A Deployment gives pods random names and doesn't bind a pod to a specific volume across reschedules. A StatefulSet gives `ethereum-0` the same name, DNS entry and volumes every time it starts.

The same rule applies to any clustered stateful system on Kubernetes. Message brokers, databases and consensus systems run as Deployments can lose stable identity and peer discovery on restart. The classic result is a split-brain, where members come back as independent clusters. If it has state or membership, it's a StatefulSet.

## Two clients, one pod

geth and Lighthouse run as two containers in one pod rather than two StatefulSets:

- They share a lifecycle. An execution client without its consensus client can't follow the chain, and vice versa.
- The Engine API binds to `127.0.0.1`, so it's unreachable from anything outside the pod. That's the strongest network control available, and it needs no NetworkPolicy.
- Both containers read the same JWT secret from a single mounted Secret.

**Trade-off.** Separate StatefulSets would allow independent scaling and upgrades, and one consensus client could serve several execution clients. For one node, coupling the two is simpler and safer.

## Storage: IOPS first, then capacity

Sync speed is limited by small random I/O, not raw capacity. The StorageClass uses gp3 with 6,000 provisioned IOPS and 250 MB/s throughput rather than the 3,000 IOPS baseline.

- **`WaitForFirstConsumer`** creates each volume only once the pod is scheduled, in that node's AZ. With `Immediate` binding the volume could land in a different AZ from the node, and the pod would never start.
- **`allowVolumeExpansion: true`.** Chains only grow. Increasing a PVC's request expands the EBS volume and filesystem online, without downtime.
- **`reclaimPolicy: Delete`** keeps the sandbox cheap. In production use `Retain`, so deleting a PVC by mistake can't destroy a synced chain.

## Zonal volumes and node placement

EBS volumes live in one AZ. If the node hosting `ethereum-0` fails and its replacement comes up in another AZ, the volumes can't attach and the pod stays Pending. The blockchain node group is therefore pinned to a single subnet. The trade-off is that an AZ outage takes the node down. For one node that's acceptable. For a highly available RPC tier you'd run several independent nodes in different AZs behind a load balancer, each with its own volumes, rather than trying to move one node's disk between zones.

## Shutdown and probes

- **`terminationGracePeriodSeconds: 300`.** Both clients keep state in memory and flush on SIGTERM. The default 30 seconds can end in SIGKILL mid-write, and a corrupted database means hours of resync.
- **Startup probes** give each client up to 10 minutes to open its ports before liveness checks begin. Liveness is a TCP check, deliberately not "is it synced": a node that's syncing is healthy and must not be restarted.
- **Readiness** for Lighthouse uses the standard `/eth/v1/node/health` endpoint, which returns 200 when synced and 206 while syncing. Both keep it in the Service.

## Memory

geth is written in Go. Without a hint, the Go garbage collector doesn't know about the container's memory limit and can grow the heap until the kernel OOM-kills it. `GOMEMLIMIT=14GiB`, under the 16 GiB limit, makes the runtime collect harder as it approaches the limit. `--cache=4096` bounds geth's own caches.

## Volume permissions at scale

`fsGroup` makes Kubernetes chown the volume so the non-root user can write to it. By default that chown is recursive on every mount, and on a volume holding millions of files it can delay startup by many minutes. `fsGroupChangePolicy: OnRootMismatch` chowns only when the volume root's ownership is wrong, which in practice means only the first mount.

## Peering and NAT

Both clients dial out to peers through the NAT gateway, which is enough to sync and follow the chain. They don't accept inbound peers, because the pod sits on a private subnet. That limits how many peers they hold and makes them slightly less useful to the network. A production node that should accept inbound peers would expose the p2p ports through a NodePort or host ports on a node with a public address, and advertise that address to the clients.

## Alerting on symptoms

The alerts track what an operator acts on:

- **The head stopped advancing.** The node has stopped following the chain, whatever the cause.
- **Peers dropped.** That's an early sign of egress or NAT problems before sync stalls.
- **A volume has under 15% free, or is projected to fill within 24 hours.** `predict_linear` turns disk growth into a deadline, giving time to expand the PVC before the client halts.

CPU and memory alerts are left to the cluster defaults. A busy node isn't a problem; a node that stopped following the chain is.

## What I'd add for production

- `reclaimPolicy: Retain` and scheduled EBS snapshots (or Velero), so a node can be rebuilt from a recent snapshot instead of resyncing
- Multiple independent nodes across AZs behind an internal load balancer for a highly available RPC tier
- Inbound p2p through NodePort or host networking with an advertised public address
- A NetworkPolicy that limits RPC access to the namespaces of the applications using it
- A Grafana dashboard for sync progress, peers, and disk growth
