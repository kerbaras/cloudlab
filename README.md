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
├── ARCHITECTURE.md          canonical design record
├── SUBNET-PLAN.md           addressing contract
├── talos/                   talconfig · schematic · machineconfig patches
├── tailscale/               tailnet ACL policy
└── kubernetes/
    ├── cilium/              Helm values (bootstrap layer — not GitOps-managed yet)
    ├── networking/          LB pools · GatewayClass/Gateway · certs · routes
    ├── policies/            baseline kustomize components · examples
    └── argocd/              root app-of-apps + sync-waved Applications
```

## CHECKME index

| Where | What you must fill in |
|---|---|
| `talos/talconfig.yaml` | install disk, IPv4 netmask + gateway (Robot panel), tailnet MagicDNS cert SAN |
| `talos/patches/firewall.yaml` | break-glass operator IP (deleted in Stage 2) |
| `talos/patches/tailscale.yaml` | copied from `.example`; tagged Tailscale auth key |
| `kubernetes/networking/cert-issuer.yaml` | ACME email, DNS-01 provider credentials ref |
| `kubernetes/argocd/apps/*.yaml` | repo URL / target revision if you fork or rename branches |
| `.sops.yaml` | your age recipient |
| DNS zone | `*.cloudlab.kerbaras.com` A → `65.21.143.224`, AAAA → edge address from `fd02::/64` (after Stage 4) |

---

## Stage 0 — Prerequisites (workstation)

Tools: `talosctl`, `talhelper`, `kubectl`, `helm`, `cilium`, `hubble`,
`sops`, `age`.

1. **SOPS/age**: generate a key (`age-keygen`), put the public recipient in
   `.sops.yaml`, keep the private key off-box (password manager).
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
   lsblk   # confirm the system disk
   xz -dc /tmp/talos.raw.xz | dd of=/dev/nvme0n1 bs=4M status=progress && sync
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
   default-block active with the break-glass rule admitting your operator IP.

## Stage 2 — Prove the tailnet, then burn the break-glass rule

1. The tailscale extension registers `quasar` on the tailnet (check the
   admin console; approve the advertised route `10.96.0.0/12` if
   auto-approval didn't).
2. **Prove** management-plane access over the tailnet before removing the
   fallback:
   ```bash
   talosctl -n <quasar-tailscale-ip> version
   kubectl --server https://<quasar-tailscale-ip>:6443 get nodes
   ```
3. Point your configs at the tailnet permanently: edit `talosconfig`
   endpoints and the kubeconfig `server:` to the MagicDNS name (it is in the
   cert SANs via `talos/talconfig.yaml`).
4. Delete the break-glass document from
   [`talos/patches/firewall.yaml`](./talos/patches/firewall.yaml) (the block
   marked `00-break-glass`), regenerate, re-apply:
   ```bash
   talhelper genconfig && talosctl -n <tailscale-ip> apply-config \
     --file clusterconfig/cloudlab-mgmt-quasar.yaml
   ```
5. Verify from a network that is neither the tailnet nor your operator IP:
   `nc -vz 65.21.143.251 50000` and `:6443` must time out.

Lockout after this point costs a rescue-mode reinstall (~30 min), not the box.

## Stage 3 — Cilium (the one bootstrap-installed layer)

```bash
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium --version 1.19.5 \
  -n kube-system -f kubernetes/cilium/values.yaml
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

1. Bootstrap Argo CD and hand it the repo:
   ```bash
   helm repo add argo https://argoproj.github.io/argo-helm
   helm install argocd argo/argo-cd --version 10.1.2 -n argocd --create-namespace
   kubectl apply -f kubernetes/argocd/root.yaml
   ```
2. Sync waves land in order: Envoy Gateway + cert-manager (wave 0) →
   networking (wave 1) → policies (wave 2).
3. Create the DNS-01 credentials secret referenced by
   `kubernetes/networking/cert-issuer.yaml` (SOPS-decrypt your copy of the
   `.example` file and apply it).
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
| `nmap -sS -p- 65.21.143.251` | all TCP filtered |
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
[`kubernetes/cilium/values.yaml`](./kubernetes/cilium/values.yaml),
`helm upgrade`, and re-run the external checks.

Phase 1 is done when every row above passes. Next: Phase 2/3 per
[`ARCHITECTURE.md`](./ARCHITECTURE.md) §12.

## Recovery

- **Bricked host / lost config** → Stage 1 again (rescue + `dd` + `talhelper
  genconfig` + bootstrap): ~30 minutes to a bare mgmt cluster.
- **etcd** → `talosctl etcd snapshot db.snapshot` periodically, shipped
  off-box; everything else reconstructs from this repo.
- **Locked out of the firewall** → rescue mode; the break-glass rule only
  exists between Stages 1 and 2 by design.
