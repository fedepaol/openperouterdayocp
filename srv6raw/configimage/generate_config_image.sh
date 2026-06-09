#!/bin/bash
# generate_config_image.sh - Build the agent config-image ISO (rawconfig mode).
#
# Compiles MachineConfig manifests from rawconfig butane sources, then runs
# `openshift-install agent create config-image` to produce the config-image
# ISO that the appliance mounts at first boot.
#
# Usage: generate_config_image.sh [config_image_dir]
#
#   config_image_dir  Working directory for config-image generation
#                     (default: ./configimage)
#
# The ISO is written to <config_image_dir>/agentconfig.noarch.iso
#
# Requires: butane

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLIANCE_CACHE="${SCRIPTDIR}/../appliance/cache"

config_image_dir="$(realpath "${1:-${SCRIPTDIR}/configimage}")"

# Use openshift-install from the appliance cache
openshift_install=$(find "${APPLIANCE_CACHE}" -name 'openshift-install' -type f 2>/dev/null | head -1)
if [[ -z "${openshift_install}" || ! -x "${openshift_install}" ]]; then
    echo "ERROR: openshift-install not found in ${APPLIANCE_CACHE}. Build the appliance first."
    exit 1
fi
echo "Using: ${openshift_install}"

# ============================================================
# Prepare config-image work directory
# ============================================================
mkdir -p "${config_image_dir}"

# Copy install and agent configs
cp "${SCRIPTDIR}/install-config.yaml" "${config_image_dir}/"
cp "${SCRIPTDIR}/agent-config.yaml" "${config_image_dir}/"

# Remove namespace fields that cause strict diff failures
# in the appliance's load-config-iso.sh
sed -i '/^  namespace:/d' "${config_image_dir}/agent-config.yaml"
sed -i '/^  namespace:/d' "${config_image_dir}/install-config.yaml"

# ============================================================
# Generate MachineConfig manifests from rawconfig butane sources
# ============================================================
extra_manifests_dir="${config_image_dir}/openshift"

"${SCRIPTDIR}/generate_machineconfigs.sh" "${extra_manifests_dir}"

# ============================================================
# Create the config-image ISO
# ============================================================
echo "==> Creating config-image ISO..."

"${openshift_install}" --log-level=debug --dir="${config_image_dir}" agent create config-image

# Copy auth files alongside the ISO for wait-for access
if [[ -d "${config_image_dir}/auth" ]]; then
    echo "  Auth files available at ${config_image_dir}/auth/"
fi

echo "==> Done: ${config_image_dir}/agentconfig.noarch.iso"
