# DNS configuration failure with bridge-over-dummy topology

## Problem

When using an agent-based installation with a bridge interface (`br0`) over a dummy port as the primary network interface, the node fails to start kubelet. The kubelet is blocked waiting for `/run/resolv-prepender-kni-conf-done`, which is never created because the resolv-prepender script is stuck in an infinite loop waiting for nameservers in `/var/run/NetworkManager/resolv.conf`.

The journal shows repeated messages:

```
NM resolv-prepender: NM resolv.conf still empty of nameserver
```

## Root cause

The issue involves three components across different repositories:

### 1. nmstate global `dns-resolver` not bound to the bridge connection

In the agent-config, DNS is configured via the nmstate global `dns-resolver` block:

```yaml
networkConfig:
  interfaces:
  - name: br0
    type: linux-bridge
    state: up
    ipv4:
      enabled: true
      address:
      - ip: 192.168.110.2
        prefix-length: 24
      dhcp: false
    bridge:
      port:
      - name: dummy0
  dns-resolver:
    config:
      server:
      - 192.168.110.1
  routes:
    config:
    - destination: 0.0.0.0/0
      next-hop-address: 192.168.110.1
      next-hop-interface: br0
      table-id: 254
```

nmstate is supposed to bind the global `dns-resolver` to the interface that has a static gateway. However, for a bridge-over-dummy topology, this binding fails: the DNS server is never written to the `br0` NetworkManager connection profile (`ipv4.dns` remains empty).

This can be confirmed on the node:

```bash
$ nmcli con show br0 | grep -i dns
# (empty - no DNS configured)
```

### 2. NetworkManager's resolv.conf stays empty

Since no connection profile has DNS configured, NetworkManager never populates `/var/run/NetworkManager/resolv.conf` with any nameserver entries. The file remains empty.

### 3. resolv-prepender hangs (openshift/machine-config-operator)

The resolv-prepender script (`/usr/local/bin/resolv-prepender.sh`, rendered from `templates/common/on-prem/files/resolv-prepender.yaml` in the machine-config-operator) has an early loop:

```bash
while ! grep nameserver /var/run/NetworkManager/resolv.conf; do
    >&2 echo "NM resolv-prepender: NM resolv.conf still empty of nameserver"
    sleep 0.5
done
```

This loop never exits because NM's resolv.conf is empty. The script never reaches the `node-ip show` call (from `openshift/baremetal-runtimecfg`) and never creates `/run/resolv-prepender-kni-conf-done`.

### 4. kubelet never starts (openshift/machine-config-operator)

The kubelet service has a drop-in (`10-mco-on-prem-wait-resolv.conf`, from `templates/common/on-prem/units/kubelet.service-wait-resolv.yaml`) that gates startup on the done file:

```ini
[Service]
ExecCondition=/bin/bash -c '[ -f /run/resolv-prepender-kni-conf-done ] || { echo "NM resolv-prepender failed"; exit 255; }'
```

Since the file is never created, kubelet never starts.

## The chain

```
nmstate dns-resolver not bound to br0 connection profile
  -> NM ipv4.dns empty on br0
    -> /var/run/NetworkManager/resolv.conf empty
      -> resolv-prepender.sh stuck in "waiting for nameserver" loop
        -> /run/resolv-prepender-kni-conf-done never created
          -> kubelet ExecCondition fails forever
            -> node never becomes ready
```

## Workaround

Manually setting DNS on the connection resolves the issue:

```bash
nmcli con mod br0 ipv4.dns "192.168.110.1"
nmcli con up br0
```

After this, `/var/run/NetworkManager/resolv.conf` is populated, the resolv-prepender completes, and kubelet starts.

## Possible fix

Adding `auto-dns: false` to the bridge interface ipv4 config in the agent-config may help nmstate correctly bind the global DNS to the connection:

```yaml
    - name: br0
      type: linux-bridge
      state: up
      ipv4:
        enabled: true
        auto-dns: false
        address:
        - ip: 192.168.110.2
          prefix-length: 24
        dhcp: false
```

If this does not work, the DNS should be investigated as a potential nmstate bug for bridge-over-dummy topologies.

## References

- [nmstate DNS configuration limitations (BZ 1847038)](https://bugzilla.redhat.com/show_bug.cgi?id=1847038)
- [nmstate: "only support saving DNS to interface with static gateway or auto interface with auto-dns:false"](https://access.redhat.com/solutions/7030084)
- [MCO resolv-prepender template](https://github.com/openshift/machine-config-operator/blob/master/templates/common/on-prem/files/resolv-prepender.yaml)
- [MCO kubelet wait-resolv template](https://github.com/openshift/machine-config-operator/blob/master/templates/common/on-prem/units/kubelet.service-wait-resolv.yaml)
- [baremetal-runtimecfg node-ip command](https://github.com/openshift/baremetal-runtimecfg/blob/master/cmd/runtimecfg/node-ip.go)
