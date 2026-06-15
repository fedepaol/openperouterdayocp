#!/bin/bash
# patch_appliance.sh - Patch an existing appliance ISO by embedding
# OpenPERouter quadlets, configs, registry mirrors,
# and the ignition hack agent into it.
#
# Usage: patch_appliance.sh <appliance_iso> <ocp_dir>
#
#   appliance_iso         Path to the appliance ISO to patch
#   ocp_dir               OCP working directory containing cache/*/cluster-resources
#
# Requires: coreos-installer, jq, yq, butane

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRASDIR="$(cd "${SCRIPTDIR}/../extras" && pwd)"

appliance_iso="$1"
ocp_dir="$2"

if [[ ! -f "${appliance_iso}" ]]; then
    echo "ERROR: Appliance ISO not found: ${appliance_iso}"
    exit 1
fi

# ============================================================
# Step 1: Embed OpenPERouter content into the ISO ignition
# ============================================================
echo "==> Patching appliance ISO with OpenPERouter content..."

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

staging="${tmpdir}/staging"
mkdir -p "${staging}"

# --- Generate registries.conf drop-in ---
# Converts IDMS/ITMS yaml files from the appliance cache into a
# registries.conf drop-in so mirror redirects work on first boot.
registries_conf="${staging}/appliance-mirrors.conf"
cluster_resources="${ocp_dir}/cache/"*"/cluster-resources"
{
    for yaml_file in ${cluster_resources}/idms-oc-mirror.yaml ${cluster_resources}/itms-oc-mirror.yaml; do
        if [[ ! -f "${yaml_file}" ]]; then
            continue
        fi
        if [[ "${yaml_file}" == *idms* ]]; then
            digest_only="true"
        else
            digest_only="false"
        fi
        yq -r '.spec.imageDigestMirrors // .spec.imageTagMirrors // [] | .[] | .source as $src | .mirrors[] | [$src, .] | @tsv' "${yaml_file}" | \
        while IFS=$'\t' read -r source mirror; do
            cat <<TOML

[[registry]]
  prefix = ""
  location = "${source}"
  mirror-by-digest-only = ${digest_only}

  [[registry.mirror]]
    location = "${mirror}"
    insecure = true
TOML
        done
    done
} > "${registries_conf}"

# --- Build butane YAML ---
bu="${tmpdir}/appliance.bu"
bu_files=""
bu_units=""

# Registry mirrors
if [[ -s "${registries_conf}" ]]; then
    bu_files+="    - path: /etc/containers/registries.conf.d/appliance-mirrors.conf
      mode: 0644
      overwrite: true
      contents:
        local: appliance-mirrors.conf
"
fi

# Quadlet files and configs
if [[ -d "${EXTRASDIR}/quadlets" ]]; then
    # Stage all source files into the butane files-dir
    for f in controllerpod.pod controller.container routerpod.pod frr.container \
             reloader.container frr-sockets.volume openperouter-node-index.sh \
             patch-installer-config.sh can_start.sh \
             openperouter-node-index.service \
             enable-virtual-interfaces.service; do
        cp "${EXTRASDIR}/quadlets/${f}" "${staging}/"
    done
    cp "${EXTRASDIR}/config/openpe_config.yaml" "${staging}/"

    # Quadlet files -> /etc/containers/systemd/
    for f in controllerpod.pod controller.container routerpod.pod frr.container \
             reloader.container frr-sockets.volume; do
        bu_files+="    - path: /etc/containers/systemd/${f}
      mode: 0644
      overwrite: true
      contents:
        local: ${f}
"
    done

    # Scripts -> /usr/local/bin/ (executable)
    for f in openperouter-node-index.sh patch-installer-config.sh; do
        bu_files+="    - path: /usr/local/bin/${f}
      mode: 0755
      overwrite: true
      contents:
        local: ${f}
"
    done

    # Config files -> /var/lib/openperouter/
    bu_files+="    - path: /var/lib/openperouter/configs/openpe_config.yaml
      mode: 0644
      overwrite: true
      contents:
        local: openpe_config.yaml
"

    # can_start.sh -> /var/lib/openperouter/ (executable)
    bu_files+="    - path: /var/lib/openperouter/can_start.sh
      mode: 0755
      overwrite: true
      contents:
        local: can_start.sh
"

    # Systemd units (using contents_local so butane reads from files-dir)
    for f in openperouter-node-index.service \
             enable-virtual-interfaces.service; do
        bu_units+="    - name: ${f}
      enabled: true
      contents_local: ${f}
"
    done
fi

# --- Assemble and compile butane ---
if [[ -z "${bu_files}" && -z "${bu_units}" ]]; then
    echo "Nothing to embed into appliance ISO"
else
    {
        echo "variant: fcos"
        echo "version: 1.5.0"
        if [[ -n "${SSH_PUB_KEY:-}" ]]; then
            echo "passwd:"
            echo "  users:"
            echo "    - name: core"
            echo "      ssh_authorized_keys:"
            echo "        - \"${SSH_PUB_KEY}\""
        fi
        if [[ -n "${bu_files}" ]]; then
            echo "storage:"
            echo "  files:"
            printf '%s' "${bu_files}"
        fi
        if [[ -n "${bu_units}" ]]; then
            echo "systemd:"
            echo "  units:"
            printf '%s' "${bu_units}"
        fi
    } > "${bu}"

    # Compile butane -> ignition (butane handles base64 encoding, etc.)
    butane --raw --strict -d "${staging}" "${bu}" > "${tmpdir}/additions.ign"

    # Extract existing ISO ignition
    sudo coreos-installer iso ignition show "${appliance_iso}" > "${tmpdir}/original.ign" 2>/dev/null \
        || echo '{"ignition":{"version":"3.4.0"}}' > "${tmpdir}/original.ign"

    # Merge our additions with the original ignition
    jq -s '
        .[0] as $orig | .[1] as $new |
        $orig |
        .storage = (.storage // {}) |
        .storage.files = ((.storage.files // []) + ($new.storage.files // [])) |
        if ($new.systemd.units // [] | length) > 0 then
            .systemd = (.systemd // {}) |
            .systemd.units = ((.systemd.units // []) + ($new.systemd.units // []))
        else . end |
        if ($new.passwd.users // [] | length) > 0 then
            .passwd = (.passwd // {}) |
            .passwd.users = ((.passwd.users // []) + ($new.passwd.users // []))
        else . end
    ' "${tmpdir}/original.ign" "${tmpdir}/additions.ign" > "${tmpdir}/merged.ign"

    # Embed merged ignition into ISO (force overwrite)
    sudo coreos-installer iso ignition embed -f -i "${tmpdir}/merged.ign" "${appliance_iso}"

    echo "==> Embedded OpenPERouter ignition into appliance ISO"
fi

# ============================================================
# Step 2: Embed ignition hack agent
# ============================================================
if [[ -x "${SCRIPTDIR}/hackagent.sh" ]]; then
    "${SCRIPTDIR}/hackagent.sh" "${appliance_iso}"
fi

echo "==> Done! Appliance ISO patched: ${appliance_iso}"
