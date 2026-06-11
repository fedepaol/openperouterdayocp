# OpenPERouter — EVPN Full Config Deployment

A controller-managed deployment of OpenPERouter on an OpenShift cluster. The
OpenPERouter controller and reloader containers run as systemd quadlets on each
node, reading a declarative config (`openpe_config.yaml`) and driving FRR
accordingly.

## Architecture

```
              ┌─────────┐
              │   TOR   │
              │ AS 64512│
              └────┬────┘
                   │  eBGP (EVPN + L3VPN over VXLAN)
        ┌──────────┼──────────┐
        │          │          │
   ┌────┴───┐ ┌───┴────┐ ┌───┴────┐
   │master-0│ │master-1│ │worker-0│  ...
   │AS 64514│ │AS 64514│ │AS 64514│
   └────────┘ └────────┘ └────────┘
        ◄── EVPN / VXLAN (L2VPN) ──►
           routes via TOR (no RR)
```

- **North-south** (nodes ↔ TOR): L3VPN over VXLAN (eBGP underlay), L3VNI 100
- **East-west** (node ↔ node): EVPN with VXLAN, L2VNI 210
- All nodes peer directly with the TOR — **no route reflector**
- The TOR distributes all EVPN and L3VPN routes

See [TOPOLOGY.md](TOPOLOGY.md) for full addressing and peering details.

## Host Configuration

OpenPERouter runs as systemd quadlets deployed via MachineConfig (butane sources
in [`configimage/`](configimage/)):

| Component | Description |
|-----------|-------------|
| `controller.container` | Reads `openpe_config.yaml`, derives node-specific config, drives FRR |
| `reloader.container` | Watches for FRR config changes and triggers reload |
| `frr.container` | FRR routing daemon (BGP, EVPN) |
| `openperouter-node-index.sh` | Derives the node index from the br0 IP at boot |
| `enable-virtual-interfaces.sh` | Creates VRF, VXLAN, and bridge interfaces |
| `patch-installer-config.sh` | Patches the Assisted Service installer config |

## OpenPERouter Configuration

The declarative config lives in [`extras/config/openpe_config.yaml`](extras/config/openpe_config.yaml):

| Parameter | Value | Description |
|-----------|-------|-------------|
| L3VNI | 100 | VRF `red`, VXLAN port 4789 |
| L2VNI | 210 | VRF `red`, VXLAN port 4789, gateway 192.168.110.1/24 |
| ASN | 64514 | Cluster nodes' BGP AS |
| TOR ASN | 64512 | TOR's BGP AS |
| TOR address | 192.168.111.1 | eBGP neighbor on underlay |
| Tunnel endpoints | 100.65.0.0/24 | VTEP address pool |
| Underlay NIC | enp2s0 | BGP peering interface |

## Building

- **Appliance ISO**: [`appliance/generate_appliance.sh`](appliance/generate_appliance.sh) `<pull_secret_file> [ssh_key_file]`
- **Config-image ISO**: [`configimage/generate_config_image.sh`](configimage/generate_config_image.sh) `<pull_secret_file>`
