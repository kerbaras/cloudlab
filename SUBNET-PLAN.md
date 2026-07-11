# Subnet Plan

**Status:** addressing contract. Changing anything here is a breaking change to
the platform; do it in a PR that also updates every manifest that embeds these
ranges. Rationale lives in [`ARCHITECTURE.md`](./ARCHITECTURE.md) §5.

---

## 1. Public IPv4 (scarce → structural)

| Address | Role | Holder | Notes |
|---|---|---|---|
| `65.21.143.251` | Dark mgmt host | Talos `metal-01` uplink | Answers exactly one UDP port (Tailscale `41641`) to the internet. Pod v4 egress SNATs to this address. |
| `65.21.143.224` | Public data-plane edge | Cilium LB-IPAM pool `edge-ipv4` (one address) | Claimable only by a Service labeled `cloudlab.example/lb-pool: edge-ipv4` — in practice, the edge Gateway. Ports 80/443/6443. Routed to primary MAC (no virtual MAC ordered — revisit in Phase 2). |

There is no third IPv4. That is the security model working as intended.

## 2. Public IPv6

### 2.1 On-link /64 (uplink)

| Prefix | Role |
|---|---|
| `2a01:4f9:3b:2d44::/64` | Host uplink only. `metal-01` = `2a01:4f9:3b:2d44::1`. Gateway `fe80::1`. Nothing else lives here. |

### 2.2 Routed /56 (the addressing plane)

`2a01:4f9:3b:fd00::/56`, delivered routed to the host — every /64 below
arrives at the NIC with zero NDP tricks.

**Convention:** the third hex digit of the /64 is the cluster ordinal `N`
(`0` = mgmt, `1` = cluster-a, `2` = cluster-b, …, up to `f`), the fourth is
the role: `0` nodes/infra, `1` pods, `2` LoadBalancer pool, `3`–`f` reserved.
A packet capture is self-describing.

| Prefix | Cluster | Role | Status |
|---|---|---|---|
| `2a01:4f9:3b:fd00::/64` | mgmt (`cloudlab-mgmt`) | nodes / infra bridges | Reserved (host node lives on the on-link /64; this funds Phase 2 bridges) |
| `2a01:4f9:3b:fd01::/64` | mgmt | pods (GUA, policy-dark) | **Active — Phase 1** |
| `2a01:4f9:3b:fd02::/64` | mgmt | LB pool `public-ipv6` (opt-in label) | **Active — Phase 1** |
| `2a01:4f9:3b:fd03::/64`–`fd0f::/64` | mgmt | reserved | — |
| `2a01:4f9:3b:fd10::/64` | cluster-a | nodes (VM bridge) | Phase 3 |
| `2a01:4f9:3b:fd11::/64` | cluster-a | pods | Phase 3 |
| `2a01:4f9:3b:fd12::/64` | cluster-a | LB pool | Phase 3 |
| `2a01:4f9:3b:fd20::/64` | cluster-b | nodes | future |
| `2a01:4f9:3b:fd21::/64` | cluster-b | pods | future |
| `2a01:4f9:3b:fd22::/64` | cluster-b | LB pool | future |
| … | cluster N ≤ `f` | `fdN0`/`fdN1`/`fdN2` | claim via PR to this file |

Reachability rules: `fdN1` pod addresses are natively routable but
**policy-dark** (world ingress dropped at the veth, proof in Hubble). The only
publicly *served* v6 addresses come from `fdN2` pools, entered by labeling a
Service `cloudlab.example/public-v6: "true"` in Git.

## 3. Virtual ranges (never routed, never public)

| Range | Role | Notes |
|---|---|---|
| `10.244.0.0/16` | mgmt pods v4 | Egress SNATs to `.251`; workload clusters reuse the same range internally (isolated by VM boundary) |
| `10.96.0.0/12` | mgmt services v4 | The **only** range Tailscale advertises |
| `fd63:6c6f:7564::/108` | mgmt services v6 | `63:6c6f:7564` spells "cloud"; optionally advertised to the tailnet |
| `100.64.0.0/10` | Tailnet (CGNAT) | Appears as source identity in Talos firewall rules; never a destination we route |

## 4. DNS naming

| Name | Record | Target |
|---|---|---|
| `*.cloudlab.example` | A / AAAA | `65.21.143.224` / edge address from `fd02::/64` |
| `<cluster>.k8s.cloudlab.example` | A / AAAA | Same edge addresses (SNI passthrough on :6443) |
| `metal-01.cloudlab.example` | — | Deliberately unpublished; host access rides the tailnet (MagicDNS) |

AAAA-first: every published name gets an AAAA; A records are the compatibility
shim. Manual records in Phase 1; external-dns assumes custody in Phase 4.

## 5. Port surface (internet-facing)

| Address | Port | Protocol | Service |
|---|---|---|---|
| `65.21.143.251` | `41641` | UDP | Tailscale (direct connections) |
| `65.21.143.224` + `fd02::/64` pool | `80` | TCP | Edge — permanent 301 |
| 〃 | `443` | TCP | Edge — TLS terminate `*.cloudlab.example` |
| 〃 | `6443` | TCP | Edge — TLS passthrough `*.k8s.cloudlab.example` |

Everything else is dropped by the Talos ingress firewall (host-destined) or
Cilium policy (pod/LB-destined) before it reaches a socket.
