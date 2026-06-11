# OpenPERouter Network Topology — BGP EVPN + VXLAN (IPv4 only)

## Overview

A BGP EVPN fabric running on top of an OpenShift cluster (3 masters + 2 workers),
with a TOR router peering externally. IPv4-only overlay — no SRv6, no ISIS.

- **Underlay**: eBGP on `enp2s0` (192.168.111.0/24)
- **L3VPN** (north-south): BGP with VXLAN encapsulation, VNI 100, VRF `red`
- **L2VPN** (east-west): BGP EVPN with VXLAN (VNI 210) between all cluster nodes
- **AS**: 64514 (cluster nodes), 64512 (TOR) — all eBGP, no route reflector
- **Route distribution**: TOR distributes routes to all nodes; all nodes peer directly with TOR

```
                       ┌──────────────────────────────┐
                       │        TOR / RemotePE        │
                       │   AS 64512                   │
                       │   Underlay: 192.168.111.1    │
                       │   VRF red:                   │
                       │     DNS + NTP: 10.100.0.1    │
                       └──────────┬───────────────────┘
                                  │ eBGP (enp2s0)
                                  │ 192.168.111.0/24
                 ┌────────────────┼────────────────┐
                 │                │                │
     ┌───────────┴──┐   ┌────────┴─────┐   ┌─────┴────────┐
     │  master-0    │   │  master-1    │   │  master-2    │
     │  AS 64514    │   │  AS 64514    │   │  AS 64514    │
     │              │   │              │   │              │
     │  enp2s0:     │   │  enp2s0:     │   │  enp2s0:     │
     │   .111.80    │   │   .111.81    │   │   .111.82    │
     │  br0: .110.2 │   │  br0: .110.3 │   │  br0: .110.4 │
     │  VRF red:    │   │  VRF red:    │   │  VRF red:    │
     │   L3VNI 100  │   │   L3VNI 100  │   │   L3VNI 100  │
     │   br-pe-210  │   │   br-pe-210  │   │   br-pe-210  │
     │   .110.1/24  │   │   .110.1/24  │   │   .110.1/24  │
     │   VNI 210    │   │   VNI 210    │   │   VNI 210    │
     └──────────────┘   └──────────────┘   └──────────────┘

     ┌──────────────┐   ┌──────────────┐
     │  worker-0    │   │  worker-1    │
     │  AS 64514    │   │  AS 64514    │
     │              │   │              │
     │  enp2s0:     │   │  enp2s0:     │
     │   .111.83    │   │   .111.84    │
     │  br0: .110.5 │   │  br0: .110.6 │
     │  VRF red:    │   │  VRF red:    │
     │   L3VNI 100  │   │   L3VNI 100  │
     │   br-pe-210  │   │   br-pe-210  │
     │   .110.1/24  │   │   .110.1/24  │
     │   VNI 210    │   │   VNI 210    │
     └──────────────┘   └──────────────┘
```

## Addressing Scheme

| Node | Underlay (enp2s0) | Bridge (br0) | VTEP (from 100.65.0.0/24) | Management (enp3s0) |
|---|---|---|---|---|
| TOR | 192.168.111.1 | — | — | — |
| master-0 | 192.168.111.80 | 192.168.110.2 | 100.65.0.x | 192.168.150.20 |
| master-1 | 192.168.111.81 | 192.168.110.3 | 100.65.0.x | 192.168.150.21 |
| master-2 | 192.168.111.82 | 192.168.110.4 | 100.65.0.x | 192.168.150.22 |
| worker-0 | 192.168.111.83 | 192.168.110.5 | 100.65.0.x | 192.168.150.23 |
| worker-1 | 192.168.111.84 | 192.168.110.6 | 100.65.0.x | 192.168.150.24 |

VTEP IPs are allocated dynamically from the `100.65.0.0/24` tunnel endpoint CIDR.

## Network Interfaces

Each node has:

| Interface | Purpose |
|---|---|
| `enp2s0` | Underlay — eBGP peering with TOR (192.168.111.0/24) |
| `br0` | Overlay bridge — cluster traffic (192.168.110.0/24), backed by `dummy0` |
| `enp3s0` | Management network (192.168.150.0/24) |
| `enp1s0` | Unused (up, no IP) |

## BGP Peering

All sessions are eBGP. Every cluster node peers directly with the TOR — no route reflector.

| From | To | Local AS | Remote AS | AFIs |
|---|---|---|---|---|
| master-0 | TOR (192.168.111.1) | 64514 | 64512 | ipv4 unicast, l2vpn evpn |
| master-1 | TOR (192.168.111.1) | 64514 | 64512 | ipv4 unicast, l2vpn evpn |
| master-2 | TOR (192.168.111.1) | 64514 | 64512 | ipv4 unicast, l2vpn evpn |
| worker-0 | TOR (192.168.111.1) | 64514 | 64512 | ipv4 unicast, l2vpn evpn |
| worker-1 | TOR (192.168.111.1) | 64514 | 64512 | ipv4 unicast, l2vpn evpn |

## VXLAN Overlays

### L3VNI (VRF red)

| Parameter | Value |
|---|---|
| VNI | 100 |
| VRF | red |
| VXLAN port | 4789 |

### L2VNI (east-west L2 segment)

| Parameter | Value |
|---|---|
| VNI | 210 |
| VRF | red |
| VXLAN port | 4789 |
| Gateway IP | 192.168.110.1/24 (anycast on all nodes) |
| Bridge | br-pe-210 |
| Host bridge | br0 (linux-bridge) |

EVPN type-2 (MAC/IP) and type-3 (BUM/VTEP) routes are exchanged between
all cluster nodes via the TOR. The TOR acts as the eBGP hub distributing
all EVPN routes — there is no dedicated route reflector.

## Services on TOR (VRF red)

### DNS (dnsmasq on 10.100.0.1)

| Record | Target |
|---|---|
| api.sno-lab.example.com | 192.168.110.10 (API VIP) |
| api-int.sno-lab.example.com | 192.168.110.10 (API VIP) |
| *.apps.sno-lab.example.com | 192.168.110.11 (Ingress VIP) |

### NTP (10.100.0.1)

All cluster nodes sync time to the TOR's NTP service at 10.100.0.1.

## Routing

Default route on all cluster nodes: `0.0.0.0/0` via `192.168.110.1` (br0).
Management route: `192.168.150.0/24` via `enp3s0`.
