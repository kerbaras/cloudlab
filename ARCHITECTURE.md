# Cloudlab Architecture

**Status:** living document. This is the canonical design record for the cloudlab —
a single Hetzner dedicated server operated as if it were a small cloud provider.
Companion docs: [`SUBNET-PLAN.md`](./SUBNET-PLAN.md) (the addressing contract) and
[`README.md`](./README.md) (rollout runbook for the network baseline).

Real values throughout: `cloudlab.kerbaras.com` (domain), `quasar` (host),
`cloudlab-mgmt` (management cluster). Grep `CHECKME` in manifests before applying.

---

## 1. What this is

One bare-metal box running a **Kubernetes-native cloud control plane**: the
management cluster *is* the cloud API. Compute (VMs), networks, clusters,
DNS, identity clients, and policies are all CRDs reconciled from Git. The
design deliberately mirrors AWS concepts — not because AWS is sacred, but
because those abstractions (VPC, SG, NLB, IRSA) are the shared vocabulary of
modern infrastructure and replicating them from CNCF primitives is the point
of the lab.

### Design goals

1. **Cloud-as-CRDs.** Every piece of infrastructure is declarative, in Git,
   reconciled by a controller. No imperative snowflake state.
2. **IPv6-first.** The routed /56 is the native addressing plane; IPv4 is a
   legacy ingress shim. Every pod and VM is globally *routable*; reachability
   is a policy decision, never a NAT accident.
3. **Identity everywhere.** Humans, workloads, and clusters authenticate via
   OIDC; static credentials are a bug.
4. **Small public surface, rich private surface.** The internet sees two IPs
   and three ports. Operators see everything, over the tailnet.
5. **Rebuildable.** The host is cattle. Any layer can be recreated from this
   repo plus off-box secrets in bounded time.

### Non-goals

- **High availability.** One node = one availability zone = zero failover.
  All HA affordances (LB pools, CAPI abstractions, Gateway) are designed so a
  second box slots in later, but today they are single-instance by honesty.
- **Production SLAs, multi-region, compliance.** It's a lab. It should be
  *correct*, not certified.
- **Replicated storage.** Local NVMe via LVM. Longhorn/Ceph on one node is
  cosplay.

---

## 2. Physical substrate

| Item | Value |
|---|---|
| Server | Hetzner AX41-NVMe (Robot / dedicated) |
| CPU | AMD Ryzen 5 3600 — 6c/12t, KVM-capable, no iGPU |
| RAM | 64 GB DDR4 (non-ECC) |
| Disks | 2 × 512 GB NVMe — **not mirrored** (see §9) |
| IPv4 | `65.21.143.251` (primary), `65.21.143.224` (additional) |
| IPv6 | `2a01:4f9:3b:2d44::/64` on-link; `2a01:4f9:3b:fd00::/56` routed |
| NIC | 1 GbE, single physical interface |

Constraints that shape everything downstream: **RAM is the scarce resource**
(vCPU oversubscribes fine in an idle-heavy lab; memory doesn't), the /56 is
genuinely routed (no NDP tricks needed), and Hetzner Robot delivers the
additional IPv4 to the primary MAC unless a virtual MAC is ordered (which we
deliberately have not — see Phase 2).

---

## 3. The AWS translation table

| AWS concept | Cloudlab implementation |
|---|---|
| Region / AZ | `quasar`. There is exactly one, and it reboots sometimes. |
| EC2 | KubeVirt `VirtualMachine` CRs (KVM direct on metal, no nesting) |
| EKS | Cluster API + KubeVirt infra provider + Sidero Talos providers (CABPT/CACPPT); Talos-in-VM workload clusters |
| EKS-lite / ephemeral | vCluster (~500 MB vs ~6 GB for a VM-backed cluster) |
| VPC | Per-cluster `/64` trio (`fdN0` nodes / `fdN1` pods / `fdN2` LB) + Multus bridges (Phase 2) |
| Security Groups | Four distributed enforcement planes (§6.2) — Talos nftables, Cilium eBPF identity policy, LB-IPAM pool selectors, Tailscale ACLs |
| NLB (control planes) | Envoy Gateway `:6443` listener, TLS/SNI passthrough to `*.k8s.cloudlab.kerbaras.com` |
| Elastic IP / public addressing | Cilium LB-IPAM pools: one-address v4 prison, opt-in v6 /64 |
| Route 53 | external-dns, AAAA-first, on a real domain; cert-manager DNS-01 wildcards |
| IAM (humans) | Zitadel OIDC + apiserver structured `AuthenticationConfiguration` + kubelogin |
| IAM (workloads / IRSA) | Cluster SA issuer published as a public OIDC provider; JWT federation into Zitadel/OpenBao; SPIFFE/SPIRE as the maximalist upgrade |
| Secrets Manager | OpenBao + External Secrets Operator, authenticated by cluster JWTs |
| CloudFormation / Service Catalog | kro `ResourceGraphDefinition`s — `CloudlabCluster` stamps CAPI Cluster + DNS + OIDC client + Flux Kustomization in one apply |
| CloudWatch | VictoriaMetrics + VictoriaLogs + Grafana + Alloy/OTel; Hubble for flows |
| Direct Connect / VPN | Tailscale (host extension as subnet router; operator later) |

---

## 4. Layer model

```
 L7  Platform API        kro (CloudlabCluster), Flux Kustomization tree
 L6  Identity            Zitadel · structured authn · SA federation · OpenBao
 L5  Admin plane         Tailscale (subnet router → Service CIDR only)
 L4  Edge                Envoy Gateway on .224 · cert-manager · external-dns
 L3  Cluster fleet       Cluster API + KubeVirt provider + CABPT/CACPPT · vCluster
 L2  Network             Cilium (dual-stack native routing, LB-IPAM, policy)
 L1  Compute             KubeVirt (VMs as CRs, CDI for images)
 L0  Metal               Talos Linux · factory image + tailscale ext · talhelper
 --  Hardware            Hetzner AX41 · 2×IPv4 · /64 on-link · /56 routed
```

### L0 — Metal: Talos Linux

Immutable, API-only (no SSH, no shell, no package manager), fully declarative
machineconfig, built-in declarative ingress firewall, system extensions via
factory images. Installed by booting Hetzner rescue mode and `dd`-ing the
factory *metal* image (schematic includes `siderolabs/tailscale`);
configuration generated by talhelper from `talos/talconfig.yaml`.

Why not the alternatives: Flatcar+k0s was the credible runner-up (keeps SSH
as an escape hatch, costs you the appliance model and the declarative
firewall); Debian+kubeadm and Proxmox are GitOps-hostile at the host layer;
Harvester assumes a 3-node HCI cluster and is disqualified on footprint.
Talos' weak escape hatch (no SSH when things get weird) is a real cost,
mitigated by `talosctl` support bundles, privileged debug pods, and the fact
that reinstalling from Git takes ~10 minutes. Fedora bootc is the interesting
candidate to try **on box #2**, not here.

### L1 — Compute: KubeVirt

Kubernetes is the hypervisor management plane. The stack is: host kernel KVM →
virt-handler DaemonSet → one virt-launcher pod per VM (containerized
libvirt+QEMU) → `/dev/kvm`. **No nested virtualization** — VMs are first-class
KVM guests; workload-cluster nodes live inside them, which is what makes
"cluster = isolation boundary" true rather than aspirational. CDI imports
images to PVCs on local LVM. Kata/Firecracker remain a `RuntimeClass`
experiment to run *inside* a workload cluster later, not a host concern.

### L2 — Network: Cilium

Dual-stack, native routing both families (no tunnels — one node, and the /56
is genuinely routed here), kube-proxy replacement via KubePrism
(`localhost:7445`), LB-IPAM for service addressing, Hubble for flow
observability, eBPF identity-based policy as the security-group engine.

The rejected maximalist: **kube-ovn**, which offers literal `Vpc`/`Subnet`
CRDs and the closest AWS-VPC semantics in CRD form. Rejected as the *management*
CNI because it depends on the OVS kernel module whose availability on Talos is
an open risk, and because Cilium covers the actual requirements (identity
policy, LB-IPAM, observability) with a guaranteed-supported path. The VPC
abstraction is instead: **one workload cluster = one VPC**, realized as a /64
trio per cluster plus (Phase 2) a Multus bridge. kube-ovn can still be
evaluated *inside* a workload cluster where a broken CNI costs nothing.

### L3 — Cluster fleet: Cluster API

CAPI with the KubeVirt infrastructure provider and Sidero's Talos bootstrap +
control-plane providers (CABPT/CACPPT) against Talos nocloud images: apply a
`Cluster` CR, receive a Talos cluster in VMs minutes later. Paired with
Flux-stamped per-cluster Kustomizations (kro templating at L7) this reproduces
the per-PR-preview-environment pattern at the *cluster* level. Honest label: this is the "some assembly required" corner of
the design — the fallback happy path is capk's vanilla kubeadm images, but the
Talos route is worth the fight for config-consistency across layers.

vCluster sits alongside for experiments that don't need VM isolation:
app-level multi-tenancy at ~500 MB instead of ~6 GB. Real clusters for
CNI/system experiments; vClusters for everything else.

### L4 — Edge: Envoy Gateway

One Gateway (`edge`), one public IPv4, three listeners:

- `:80` — permanent 301 to HTTPS.
- `:443` — TLS termination for `*.cloudlab.kerbaras.com` (cert-manager wildcard via
  DNS-01); routes attach only from namespaces labeled
  `cloudlab.kerbaras.com/gateway-access: "true"` — exposure is a two-key launch.
- `:6443` — TLS **passthrough**, SNI-routed: `cluster-a.k8s.cloudlab.kerbaras.com`
  reaches cluster-a's apiserver with its own certs and auth intact. This is
  the NLB-for-control-planes on a single address.

Envoy Gateway over Cilium's Gateway implementation because of its auth
primitives: `SecurityPolicy` does OIDC at the gateway, making SSO the default
for every hosted UI (L6). external-dns publishes AAAA-first records for
everything on the declared surface.

### L5 — Admin plane: Tailscale

Talos system extension running a subnet router that advertises **the Service
CIDR only** (`10.96.0.0/12`, optionally the v6 ULA range). The tailnet never
learns pod or node-internal ranges. Consequences: `talosctl` and `kubectl`
ride the tailnet; VM SSH is a ClusterIP Service like anything else; Tailscale
ACLs form the third security-group layer (admin devices → host admin ports +
Service CIDR; the host gets **no** reach into other tailnet devices). SaaS
Tailscale now; Headscale is the sovereignty upgrade if the itch strikes.
The Kubernetes operator (per-Service tailnet nodes, tag-scoped ACLs, Tailscale
SSH with session recording) is the Phase 2 ergonomics upgrade.

### L6 — Identity

Three flows, one issuer graph:

1. **Humans → clusters.** Zitadel as IdP; kube-apiserver structured
   `AuthenticationConfiguration` (multiple issuers, CEL claim mapping — no
   flag soup); kubelogin on clients; groups → RBAC. Zitadel over Keycloak
   (weight) and Authentik (completeness); Pocket ID noted for passkey-only
   minimalism.
2. **Humans → apps.** Everything with native OIDC (Grafana, Hubble UI,
   OpenBao) points at Zitadel. Everything without gets Envoy Gateway
   `SecurityPolicy` OIDC at the edge. SSO is the default, not a per-app
   project.
3. **Workloads → the world.** Every cluster's service-account issuer is
   already an OIDC provider; publish its discovery docs on a public HTTPS URL
   (exactly how EKS IRSA works) and register clusters as trusted IdPs in
   Zitadel/OpenBao/MinIO. Pods exchange projected SA tokens for real
   credentials; zero static secrets. OpenBao + External Secrets Operator
   complete the loop, authenticating via those same cluster JWTs.
   SPIFFE/SPIRE (with its OIDC discovery provider) is the maximalist upgrade
   once raw SA federation feels limiting.

### L7 — Platform API

kro `ResourceGraphDefinition`s compose the platform's own product surface: a
`CloudlabCluster` CR that expands to CAPI Cluster + DNS records + Zitadel OIDC
client + Flux Kustomization in one apply. Crossplane is deliberately *not* the
composition engine — it earns a seat only when managing external providers
(Cloudflare, Hetzner Cloud burst capacity). CAPH (Syself's
cluster-api-provider-hetzner, covering both hcloud and Robot) is the
designated path when the fleet outgrows one box. Flux is the GitOps root;
this repo is the single source of truth.

---

## 5. Addressing

Full contract in [`SUBNET-PLAN.md`](./SUBNET-PLAN.md). The philosophy:

- **IPv4 is scarce → structural.** `.251` is the mgmt host (authenticated
  planes only); `.224` lives
  in a one-address LB-IPAM pool claimable only by the edge Gateway's Service.
  No rule review can leak public v4, because there is nothing to leak.
- **IPv6 is abundant → declared.** Pods hold GUAs from `fd01::/64` (native
  egress, policy-dark ingress). The only publicly *served* v6 addresses come
  from the `fd02::/64` pool, entered by carrying an opt-in label on a Service
  in Git.
- **Convention over memory.** `fdN0` nodes / `fdN1` pods / `fdN2` LB per
  workload cluster N; a packet capture is self-describing.
- **Virtual ranges:** `10.244.0.0/16` v4 pods (SNAT egress), `10.96.0.0/12` +
  `fd63:6c6f:7564::/108` services (the v6 spells "cloud"; the v4 range is the
  only thing Tailscale advertises), `100.64.0.0/10` = tailnet identity in
  firewall rules.

---

## 6. Security model

### 6.1 Invariants

1. `.251` answers only Tailscale (UDP `41641`) and the mutually-authenticated
   management planes (apid `:50000`, apiserver `:6443`) to the internet;
   IP allowlisting for those is delegated to the operator-managed Robot
   firewall (decision #14).
2. `.224` is the only public IPv4 surface and only the edge Gateway can hold it.
3. The /56 is dark by default; the declared surface is a labeled, Git-reviewed
   LB pool.
4. The tailnet sees Services, never pods.
5. East–west traffic is explicit: a namespace's baseline tier plus written
   `CiliumNetworkPolicy` allows, or it doesn't happen.

### 6.2 Jurisdiction: who polices which packets

There is **no chokepoint router**. Enforcement is distributed and attached to
identity, not topology:

| Traffic | Enforcement plane |
|---|---|
| Host-destined (apid :50000, apiserver :6443, Tailscale) | Talos nftables ingress firewall (default-block + explicit rules) |
| Service / LoadBalancer / NodePort | Cilium eBPF — intercepted at tc ingress, **upstream of nftables**; controlled by LB-IPAM pool membership + policy |
| Pod ↔ pod, pod ↔ world | Cilium identity policies (label-derived identities, enforced at both veths) |
| Admin plane | Tailscale ACLs |
| Routed VM bridges (Phase 2) | **Nobody, natively** → VyOS-as-KubeVirt-VM owns per-tenant bridges when they exist |

Two consequences worth tattooing somewhere: the Talos firewall **cannot** see
LB traffic (hence no 80/443 rules — they'd be dead code implying false
coverage), and masquerade-mode VMs are unreachable by construction, which is
what lets VyOS stay deferred without leaving a gap.

### 6.3 Policy tiers

Namespaces consume one of two kustomize components:

- **`baseline`** — deny-world ingress (`fromEntities: cluster`), east–west
  open. Day-one default for every namespace.
- **`baseline-strict`** — same-namespace-only ingress (+ `host` for kubelet
  probes) and default-deny egress with DNS funded through Cilium's L7 proxy.
  Cross-namespace and external flows become explicit per-app policies
  (postgres trio, gateway admission, `toFQDNs` allowlists — see
  `system/policies/examples/`).

Rollout is audit-first: `policy-audit-mode` on, watch
`hubble observe --verdict AUDIT` for days, then enforce. Every workload
holding an API key gets a `toFQDNs` egress policy — the anti-botnet pattern.

### 6.4 Worked traffic flows

```
Internet → app (v4):
  A record → .224 → NIC → Cilium eBPF (LB VIP match) → Envoy pod
  → HTTPRoute → app pod   [app CNP admits envoy-gateway-system identity]

Internet → app (v6):
  AAAA → fd02::x (routed /56 arrives at NIC) → same eBPF path

Internet → pod GUA (fd01::x):
  routed to NIC → dest veth eBPF → identity=world → DROP (+ Hubble flow)

Admin → mgmt apiserver:
  laptop → tailnet → tailscale0 → host :6443   [nftables allows 100.64/10]

Admin → workload apiserver:
  cluster-a.k8s.cloudlab.kerbaras.com:6443 → .224 → Envoy TLSRoute (SNI,
  passthrough) → CP VM apiserver   [cluster's own certs/authn intact]

Tailnet → VM SSH:
  laptop → advertised 10.96/12 → ClusterIP :22 → Cilium KPR
  → virt-launcher pod → VM   [CNP: fromEntities host; finer = SNAT off]

Pod egress:
  v4 → SNAT to .251        v6 → native from fd01::/64, no NAT ever
```

---

## 7. GitOps & repo layout

The repo is organized by *component*, not by resource type: each `system/`
directory is everything one component needs (HelmRelease, config CRs, its
namespace's Cilium policies) and maps to exactly one Flux Kustomization.
Ordering is explicit `dependsOn` (`edge` waits on `cilium`, `cert-manager`,
`envoy-gateway-system`), not anonymous waves. Cilium's Helm layer is the one
bootstrap-installed piece (no CNI, no pods, no GitOps); its GitOps-owned CRs
(LB pools) live in `system/cilium/` beside the hand-applied values. Secrets
are SOPS-encrypted in-repo against AWS KMS (`alias/cloudlab-sops`; decision
#15) and decrypted natively by Flux via a KMS-scoped IAM credential held
in-cluster, until OpenBao assumes custody.

```
cloudlab/
├── ARCHITECTURE.md          ← you are here
├── SUBNET-PLAN.md           addressing contract
├── README.md                network-baseline rollout runbook
├── talos/                   machineconfig patches · talconfig · schematic
├── tailscale/               tailnet ACL policy
├── system/                  one dir = one component = one Flux Kustomization
│   ├── flux-system/         gotk manifests + the Kustomization DAG
│   ├── cilium/              bootstrap Helm values · LB-IPAM pools
│   ├── cert-manager/        HelmRelease · ClusterIssuer · DNS-01 secret
│   ├── envoy-gateway-system/  HelmRelease · GatewayClass · EnvoyProxy · policies
│   ├── edge/                Gateway · wildcard cert · redirect · policies
│   └── policies/            reusable baseline components · examples
└── (planned)
    ├── apps/                one dir per app (dashboard, Zitadel, OpenBao, …)
    └── clusters/            CAPI manifests per workload cluster (fdN* trios)
```

Note: `clusters/` here means *workload clusters as products* (L3), a
deliberate deviation from the Flux-community convention where `clusters/`
holds per-cluster Flux entrypoints — this repo has one management cluster and
its entrypoint is `system/flux-system/`.

---

## 8. Resource budget

The inception tax — running a cloud control plane before any workload — is
**~20–25% of the box**, accepted deliberately. Rough steady-state carve:

| Component group | RAM | Notes |
|---|---|---|
| Talos + kubelet + containerd | ~2 GB | |
| Cilium + Hubble | ~1–1.5 GB | |
| KubeVirt + CDI | ~1 GB | plus ~200 MB virt-launcher overhead *per VM* |
| CAPI + providers | ~0.5 GB | |
| Flux controllers | ~0.3 GB | |
| Envoy Gateway | ~0.5 GB | |
| Zitadel + OpenBao | ~1.5 GB | L6, Phase 3 |
| VictoriaMetrics/Logs + Grafana + Alloy | ~1.5–2 GB | |
| Tailscale + misc | ~0.5 GB | |
| **Management plane total** | **~10–14 GB, ~2 cores** | |

Remainder (~48–52 GB) funds VMs: one "real" workload cluster (CP VM 4 GB +
two workers 8–12 GB each) plus a scratch cluster or a handful of standalone
VMs. Oversubscribe vCPU shamelessly; never oversubscribe RAM. vClusters when
the experiment doesn't justify a VM.

---

## 9. Storage

No mirror, on purpose. `nvme0n1` is the Talos system disk — cattle,
rebuildable from Git in minutes, mirroring it buys nothing. `nvme1n1` is the
PV pool: LVM thin + TopoLVM (or OpenEBS LocalPV-LVM) for dynamic provisioning
and snapshots; CDI lands VM disks here. Longhorn/Ceph are explicitly rejected
on one node. The honest consequence: **PV data is as durable as one NVMe**.
Anything that matters gets an off-box backup path (restic/velero to object
storage) before it's allowed to matter. Replicated storage becomes a real
conversation when box #2 arrives, not before.

---

## 10. Failure & recovery model

Single node means the failure model is refreshingly simple: everything shares
fate with one kernel, one PSU, one NVMe pair.

- **Host loss / bricked config** → Hetzner rescue mode, `dd` factory image,
  `talhelper genconfig`, apply, bootstrap: ~30 minutes to a bare mgmt cluster.
- **Lockout protection** → management endpoints are internet-open behind
  mutual TLS (decision #14); the IP allowlist lives in the Robot firewall,
  editable from any browser. A dynamic operator IP cannot cause a lockout;
  a Talos firewall misconfig still costs only a rescue-mode trip.
- **etcd** → periodic `talosctl etcd snapshot` shipped off-box; mgmt cluster
  state is otherwise reconstructable from this repo.
- **Workload clusters** → cattle by construction: CAPI re-stamps them; their
  state of record is Git + whatever their PVs held (see §9 caveat).
- **Blast radius honesty** → a kernel panic takes down every "AZ"
  simultaneously. The design's HA affordances are *interfaces* today and
  become *guarantees* only with hardware plurality.

---

## 11. Decision log

| # | Decision | Over | Because | Revisit when |
|---|---|---|---|---|
| 1 | Kubernetes-all-the-way-down | Incus/Proxmox hypervisor-first | Requirements literally describe cloud-as-CRDs; inception tax (~20–25%) accepted as the price of a cloud API | Resource pressure outweighs the aesthetic |
| 2 | Talos host OS | Flatcar+k0s, Debian+kubeadm, Harvester | Declarative everything incl. firewall; immutable; extensions; Harvester needs 3-node HCI | Box #2 (try bootc there) |
| 3 | Cilium mgmt CNI | kube-ovn (VPC CRDs) | OVS-on-Talos kernel-module risk; identity policy + LB-IPAM + Hubble cover requirements; "cluster = VPC" | True multi-tenant VPC CRDs needed → kube-ovn inside a workload cluster |
| 4 | GUA pods, policy-dark | ULA pods + NAT66 | Native egress, no NAT66 ugliness; eBPF drops world-ingress at the veth with proof in Hubble | Hopefully never |
| 5 | Envoy Gateway edge | Cilium Gateway, ingress-nginx | SecurityPolicy OIDC at the gateway; mature TLSRoute passthrough; keeps CNI and edge concerns separate | — |
| 6 | LB-IPAM edge day one | Multus macvlan + Hetzner vMAC | Same admission guarantees, hours less work; structural per-MAC isolation is hardening, not foundation | Phase 2 |
| 7 | Subnet router, Service CIDR only | Tailscale k8s operator day one | Simplest correct thing; operator adds per-Service tags/SSH later | Flat-CIDR ACLs feel coarse |
| 8 | TopoLVM local, no mirror | md mirror, Longhorn, Ceph | System disk is cattle; replicated storage on one node is theater | Box #2 |
| 9 | VyOS deferred | VyOS/OPNsense appliance day one | No chokepoint exists; masquerade VMs are unreachable by construction; VyOS-as-VM owns routed tenant bridges when those exist | Routed multi-tenant VM networks become real |
| 10 | Zitadel IdP | Keycloak, Authentik, Pocket ID | Modern, Go, light, real multi-tenancy; Pocket ID if passkey-minimalism wins | — |
| 11 | kro platform API | Crossplane compositions | Lighter; Crossplane reserved for external providers only | External resources (Cloudflare, hcloud burst) enter scope |
| 12 | SaaS Tailscale | Headscale | Zero control-plane ops now; sovereignty is a later itch | The itch |
| 13 | Flux | ArgoCD | Native SOPS decryption, pull-based, ~700 MB lighter; v1's endgame was already a Flux migration; cluster stamping moves to kro+Flux templates | A console need arises (Headlamp/Capacitor) |
| 14 | Internet-open mTLS mgmt endpoints | Talos-firewall IP pinning; tailnet-only mgmt | Operator egress IP is dynamic → pinning is a lockout timer; apid/apiserver are mutually-authenticated TLS; allowlisting delegated to the browser-editable Robot firewall | Static operator egress, or Tailscale API-server proxy assumes the role |
| 15 | SOPS master key in AWS KMS | Local age key | The lost-workstation rebuild proved a local key is a single point of loss; KMS survives any one machine, and Flux decrypts via an IAM user scoped to kms:Decrypt on one key | OpenBao assumes secret custody (Phase 4) |

---

## 12. Roadmap

**Phase 1 — network baseline (this repo, current).** Talos + firewall +
Tailscale, Cilium dual-stack, LB pools, Envoy edge with the three listeners,
policy tiers audit→enforce. Exit criteria: the README verification suite
passes from outside and inside.

**Phase 2 — hardening & ergonomics.** Hetzner virtual MAC + Multus macvlan so
`.224` bypasses the host stack entirely (structural per-IP isolation);
Tailscale operator; Multus tenant bridges + VyOS-as-VM for routed VM networks;
CCNP variants of the baselines.

**Phase 3 — the fleet.** KubeVirt + CDI in anger; CAPI + CABPT/CACPPT;
`cluster-a` on its `fd10/fd11/fd12` trio; TLSRoute wired for real;
Flux-templated preview clusters; vCluster lane.

**Phase 4 — identity & platform.** Zitadel + structured authn + kubelogin;
gateway OIDC everywhere; SA-issuer federation (IRSA-style) + OpenBao/ESO;
kro `CloudlabCluster`; observability build-out; SPIRE if federation outgrows
raw SA tokens.

**Phase N — box #2.** Robot vSwitch or ClusterMesh; CAPH for Hetzner-native
CAPI; replicated storage question reopens; HA stops being theater.
