#!/usr/bin/env bash
# =============================================================================
# install-azcopy.sh – Install AzCopy v10 on the current machine.
#
# Detects the host architecture (x86_64 / aarch64) and downloads the
# appropriate binary.  Installs to /usr/local/bin/azcopy.
#
# Usage:
#   ./scripts/install-azcopy.sh
# =============================================================================
set -euo pipefail

ARCH="$(uname -m)"
if [[ "${ARCH}" == "aarch64" ]]; then
  AZCOPY_URL="https://aka.ms/downloadazcopy-v10-linux-arm64"
else
  AZCOPY_URL="https://aka.ms/downloadazcopy-v10-linux"
fi

echo "Installing AzCopy v10 for ${ARCH}..."
curl -fsSL "${AZCOPY_URL}" -o /tmp/azcopy.tar.gz
tar -xzf /tmp/azcopy.tar.gz -C /tmp
find /tmp -name 'azcopy' -type f -exec sudo mv {} /usr/local/bin/azcopy \;
sudo chmod +x /usr/local/bin/azcopy
rm -f /tmp/azcopy.tar.gz
echo "AzCopy installed: $(azcopy --version)"
