# cloudlab

A single Hetzner dedicated server operated as if it were a small cloud
provider. Design rationale: [`ARCHITECTURE.md`](./ARCHITECTURE.md).
Addressing contract: [`SUBNET-PLAN.md`](./SUBNET-PLAN.md).

This README is the **rollout runbook for Phase 1 — the network baseline**:
Talos + firewall + Tailscale, Cilium dual-stack, LB pools, the Envoy edge
Gateway, and the policy tiers.

> [!IMPORTANT]
> Real values: `cloudlab.kerbaras.com` (domain), `quasar` (host),
> `cloudlab-mgmt` (cluster). Before applying anything, sweep the repo:
> `grep -rn CHECKME .`

## Repo layout

```
├── ARCHITECTURE.md           canonical design record
├── SUBNET-PLAN.md            addressing contract
├── talos/                    talconfig · schematic · machineconfig patches
├── tailscale/                tailnet ACL policy
├── apps/                     (arrives with the first app) one dir per app
├── clusters/                 (arrives with cluster-a) CAPI workload clusters
└── system/                   one dir per component; config + policies colocated
    ├── flux-system/          gotk manifests · the per-component Kustomization DAG
    ├── cilium/               bootstrap Helm values (by hand) · LB pools (GitOps)
    ├── cert-manager/         HelmRelease · ClusterIssuer · Route53 DNS-01 secret
    ├── envoy-gateway-system/ HelmRelease · GatewayClass · EnvoyProxy · ns policies
    ├── edge/                 Gateway · wildcard cert · HTTP→S redirect · ns policies
    └── policies/             reusable baseline components · examples
```

Each `system/` dir is one Flux Kustomization; dependencies are explicit
(`edge` depends on `cilium` + `cert-manager` + `envoy-gateway-system`). An
app follows the same pattern: `apps/<name>/` plus a `<name>-ks.yaml` in
`system/flux-system/`.

## CHECKME index

| Where | What you must fill in |
|---|---|
| `talos/patches/tailscale.yaml` | copied from `.example`; tagged Tailscale auth key |
| `system/cert-manager/issuer.yaml` | ACME contact email |
| `system/cert-manager/route53-credentials.sops.yaml.example` | scoped IAM key for DNS-01 |
| DNS zone | `*.cloudlab.kerbaras.com` A → `65.21.143.224`, AAAA → edge address from `fd02::/64` (after Stage 4) |

Already pinned from the live v1 box + tailnet: install disk (by serial), IPv4
`/26` + gateway `.193`, MagicDNS SAN (`quasar.tail9639db.ts.net`).

---

## Stage 0 — Prerequisites (workstation)

Tools: `talosctl`, `talhelper`, `kubectl`, `helm`, `cilium`, `hubble`,
`sops`, `aws`.

1. **SOPS/KMS**: the master key is AWS KMS `alias/cloudlab-sops` (us-east-1,
   ARN pinned in `.sops.yaml` — decision #15). Operators encrypt/decrypt with
   their own AWS credentials (`eval "$(aws configure export-credentials
   --profile personal --format env)"` — sops can't read `aws login` root
   sessions directly); in-cluster decryption uses the `cloudlab-flux-sops`
   IAM user, scoped to `kms:Decrypt` on that one key. No local key material
   to lose.
2. **Tailscale**: in the admin console apply
   [`tailscale/policy.hujson`](./tailscale/policy.hujson), then create an
   auth key **tagged `tag:cloudlab-host`** (reusable off, ephemeral off).
3. **Secrets**:
   ```bash
   cd talos
   talhelper gensecret > talsecret.sops.yaml && sops -e -i talsecret.sops.yaml
   cp patches/tailscale.yaml.example patches/tailscale.yaml   # fill TS_AUTHKEY (gitignored)
   ```
4. **DNS**: create `*.cloudlab.kerbaras.com. A 65.21.143.224` now; AAAA comes
   after Stage 4 assigns the v6 edge address.

## Stage 1 — Metal (Talos via Hetzner rescue)

> [!CAUTION]
> The `dd` below irreversibly wipes the target disk. Confirm the device in
> rescue mode with `lsblk` first.

1. Robot → server → **Rescue** tab → activate (linux/x86_64) → reboot → SSH in.
2. Build the factory image from [`talos/schematic.yaml`](./talos/schematic.yaml):
   ```bash
   ID=$(curl -sX POST --data-binary @talos/schematic.yaml https://factory.talos.dev/schematics | jq -r .id)
   # on the rescue system:
   wget -O /tmp/talos.raw.xz "https://factory.talos.dev/image/${ID}/v1.13.6/metal-amd64.raw.xz"
   lsblk -o NAME,SIZE,SERIAL   # system disk = S4GENX0R517398; PV pool = S4GENX0R517494
   # v1 ran md RAID1 across both disks — kill the superblocks or they haunt Talos:
   mdadm --stop --scan && wipefs -af /dev/nvme0n1 /dev/nvme1n1
   xz -dc /tmp/talos.raw.xz | dd of=/dev/disk/by-id/nvme-*S4GENX0R517398 bs=4M status=progress && sync
   reboot
   ```
3. Talos boots into maintenance mode on `65.21.143.251`. Generate and apply:
   ```bash
   cd talos
   talhelper genconfig
   talosctl apply-config --insecure -n 65.21.143.251 \
     --file clusterconfig/cloudlab-mgmt-quasar.yaml
   talosctl --talosconfig clusterconfig/talosconfig -n 65.21.143.251 bootstrap
   talosctl --talosconfig clusterconfig/talosconfig -n 65.21.143.251 kubeconfig ..
   ```
4. Expected state: node `NotReady` (no CNI yet — deliberate), firewall
   default-block active; the management planes (`:50000`, `:6443`) answer
   mutual TLS from anywhere (decision #14).

> [!NOTE]
> **As built:** quasar v2 was installed without rescue mode at all — kexec
> from the running v1 Debian into the Talos initramfs (RAM-only), then
> `apply-config`; the installer rewrote the disk. Rescue + `dd` remains the
> documented recovery path.

## Stage 2 — Join the tailnet (ergonomics, not the floor)

The management floor is decision #14: apid/apiserver are internet-open behind
mutual TLS, with the operator-managed **Robot firewall** as the IP allowlist
(restrict `dst 65.21.143.251` + `tcp 50000,6443` there; leave edge and return
traffic alone). The tailnet is the *preferred* path on top of that floor.

1. The tailscale extension registers `quasar` on the tailnet. With a tagged
   auth key in `talos/patches/tailscale.yaml` this is automatic; without one
   (as built) grab the interactive login URL from
   `talosctl logs ext-tailscale` — take the **latest** URL, the extension
   regenerates it on its retry loop, and a stale click registers a ghost node.
2. Approve the advertised route `10.96.0.0/12` in the admin console; run
   `tailscale set --accept-routes=true` on admin devices.
3. Verify over the tailnet:
   ```bash
   talosctl -e <quasar-tailscale-ip> -n <quasar-tailscale-ip> version
   kubectl --server https://quasar.<tailnet>.ts.net:6443 get nodes
   ```
4. Optionally point `talosconfig`/kubeconfig at the MagicDNS name (it is in
   the cert SANs via `talos/talconfig.yaml`).

## Stage 3 — Cilium (the one bootstrap-installed layer)

```bash
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium --version 1.19.5 \
  -n kube-system -f system/cilium/values.yaml
cilium status --wait
```

Verify dual-stack before continuing:

```bash
kubectl get node quasar -o jsonpath='{.spec.podCIDRs}'   # 10.244/24 + fd01::/64 slice
kubectl run tmp --rm -it --image=nicolaka/netshoot -- bash
  ip -6 addr                     # pod holds a GUA from 2a01:4f9:3b:fd01::/64
  curl -4 ifconfig.co            # egress = 65.21.143.251 (SNAT)
  curl -6 ifconfig.co            # egress = the pod's own GUA (no NAT)
```

Note: Cilium starts in `policy-audit-mode` — policies observe, not enforce,
until Stage 5 flips the switch.

## Stage 4 — GitOps root + edge

1. Install the Flux controllers and hand them the repo (public, read-only —
   no repo credentials live in-cluster):
   ```bash
   kubectl apply -k system/flux-system
   ```
2. Give Flux AWS credentials for SOPS-KMS decryption (the one manual secret;
   everything downstream decrypts from Git). Fresh access key for the scoped
   `cloudlab-flux-sops` user, in the `sops.aws-kms` format kustomize-controller
   expects:
   ```bash
   aws iam create-access-key --user-name cloudlab-flux-sops   # then:
   kubectl -n flux-system create secret generic sops-kms \
     --from-literal=sops.aws-kms="$(printf 'aws_access_key_id: %s\naws_secret_access_key: %s' "$KEY_ID" "$SECRET")"
   ```
3. Reconciliation follows the dependency DAG: `cilium` (LB pools),
   `cert-manager`, and `envoy-gateway-system` land in parallel, then `edge`
   (Gateway, wildcard cert, redirect). Watch with
   `flux get kustomizations --watch`. On a from-scratch install expect one
   transient round of "CRD not found" retries while the HelmReleases install
   the CRDs their neighbors consume — it converges within `retryInterval`.
4. Watch the edge come up, then publish the AAAA record:
   ```bash
   kubectl -n envoy-gateway-system get svc   # EXTERNAL-IP: 65.21.143.224 + fd02::…
   kubectl -n edge get gateway edge          # PROGRAMMED: True
   kubectl -n edge get certificate           # READY: True (DNS-01 takes a few minutes)
   ```

## Stage 5 — Verification suite (Phase 1 exit criteria)

**From the internet** (any host that is not on the tailnet):

| Check | Expectation |
|---|---|
| `nmap -sS -p- 65.21.143.251` | only `50000` + `6443` open (both TLS-authenticated); rest filtered |
| `nmap -sU -p 41641 65.21.143.251` | open\|filtered (Tailscale) |
| `nmap -sS -p- 65.21.143.224` | exactly 80, 443, 6443 open |
| `curl -I http://anything.cloudlab.kerbaras.com` | `301` → https |
| `curl -v https://anything.cloudlab.kerbaras.com` | valid `*.cloudlab.kerbaras.com` cert (404 body is fine — nothing is routed yet) |
| `curl -6 -I https://anything.cloudlab.kerbaras.com` | same, over the AAAA |
| `ping6 <any pod GUA from fd01::/64>` | silence; Hubble logs `world → pod DROP` |

**From the tailnet:**

| Check | Expectation |
|---|---|
| `talosctl -n quasar version` / `kubectl get nodes` | works over MagicDNS |
| `curl <any ClusterIP>` from your laptop | works (advertised Service CIDR) |
| Tailscale admin console | `quasar` has no ACL grant toward other devices |

**Policy audit → enforce:** run for a few days, watching
`hubble observe --verdict AUDIT` for legitimate flows you forgot to allow.
Then set `policy-audit-mode: "false"` in
[`system/cilium/values.yaml`](./system/cilium/values.yaml),
`helm upgrade`, and re-run the external checks.

Phase 1 is done when every row above passes. Next: Phase 2/3 per
[`ARCHITECTURE.md`](./ARCHITECTURE.md) §12.

## Recovery

- **Bricked host / lost config** → Stage 1 again (rescue + `dd` + `talhelper
  genconfig` + bootstrap): ~30 minutes to a bare mgmt cluster.
- **etcd** → `talosctl etcd snapshot db.snapshot` periodically, shipped
  off-box; everything else reconstructs from this repo.
- **Locked out** → IP-allowlist mistakes live in the Robot firewall and are
  fixed from any browser; only a broken Talos firewall config costs a
  rescue-mode reinstall.
