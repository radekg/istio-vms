#!/bin/bash

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

set -eu

WORKLOAD_IP=$(multipass info "${WORKLOAD_VM_NAME}" --format yaml | yq '.'${WORKLOAD_VM_NAME}'[] | select(.state == "Running") | .ipv4[0]' -r)
echo "Workload IP address is: ${WORKLOAD_IP}"

# From the istio/proxyv2 image, copy arm64 binaries as istio-sidecar.deb is amd54 only:
arm64_patch_dir="${base}/.tmp/istio-proxy-${ISTIO_VERSION}-arm64"
if [ -f "${arm64_patch_dir}/usr/local/bin/envoy" ]; then
  echo >&2 "Deploying with arm64 binaries..."
  multipass transfer --parents "${arm64_patch_dir}/usr/local/bin/envoy" "${WORKLOAD_VM_NAME}":./usr/local/bin/envoy
  multipass transfer --parents "${arm64_patch_dir}/usr/local/bin/pilot-agent" "${WORKLOAD_VM_NAME}":./usr/local/bin/pilot-agent
else
  echo >&2 "Deploying without arm64 binaries."
fi

# Set the timezone, install ntp:
multipass exec "${WORKLOAD_VM_NAME}" -- sudo timedatectl set-timezone UTC
multipass exec "${WORKLOAD_VM_NAME}" -- sudo apt-get update -y
multipass exec "${WORKLOAD_VM_NAME}" -- sudo DEBIAN_FRONTEND=noninteractive apt-get install ntp -y

# istio-sidecar.deb:
multipass transfer --parents "${DATA_DIR}/istio-sidecar/usr/local/bin/istio-start.sh" "${WORKLOAD_VM_NAME}":./usr/local/bin/istio-start.sh
multipass transfer --parents "${DATA_DIR}/istio-sidecar/lib/systemd/system/istio.service" "${WORKLOAD_VM_NAME}":./lib/systemd/system/istio.service 
multipass transfer --parents "${DATA_DIR}/istio-sidecar/var/lib/istio/envoy/envoy_bootstrap_tmpl.json" "${WORKLOAD_VM_NAME}":./var/lib/istio/envoy/envoy_bootstrap_tmpl.json
multipass transfer --parents "${DATA_DIR}/istio-sidecar/var/lib/istio/envoy/sidecar.env" "${WORKLOAD_VM_NAME}":./var/lib/istio/envoy/sidecar.env

# Configure the istio-sidecar.deb-like environment:
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /etc/certs
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /etc/istio/config
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/lib/istio/config
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/lib/istio/envoy
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/lib/istio/proxy
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/log/istio
multipass exec "${WORKLOAD_VM_NAME}" -- sudo touch /var/lib/istio/config/mesh
if [ -f "${arm64_patch_dir}/usr/local/bin/envoy" ]; then
  multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v usr/local/bin/* /usr/local/bin/'
  multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v lib/systemd/system/istio.service /lib/systemd/system/istio.service'
  multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v var/lib/istio/envoy/* /var/lib/istio/envoy/'
  # From postinst:
  set +e; multipass exec "${WORKLOAD_VM_NAME}" -- sudo groupadd --system istio-proxy; set -e
  set +e; multipass exec "${WORKLOAD_VM_NAME}" -- sudo useradd --system --gid istio-proxy --home-dir /var/lib/istio istio-proxy; set -e
else
  multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'curl -LO https://storage.googleapis.com/istio-release/releases/'${ISTIO_VERSION}'/deb/istio-sidecar.deb && sudo dpkg -i istio-sidecar.deb'
fi

# Deploy workload files:
multipass transfer --parents "${base}/.data/workload-files/root-cert.pem" "${WORKLOAD_VM_NAME}":./workload/root-cert.pem
multipass transfer --parents "${base}/.data/workload-files/cluster.env" "${WORKLOAD_VM_NAME}":./workload/cluster.env
multipass transfer --parents "${base}/.data/workload-files/istio-token" "${WORKLOAD_VM_NAME}":./workload/istio-token
multipass transfer --parents "${base}/.data/workload-files/mesh.yaml" "${WORKLOAD_VM_NAME}":./workload/mesh



multipass transfer --parents "${base}/.data/workload-files/hosts" "${WORKLOAD_VM_NAME}":./workload/hosts
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/hosts /etc/hosts'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/root-cert.pem /etc/certs/root-cert.pem'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/cluster.env /var/lib/istio/envoy/cluster.env'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/run/secrets/tokens
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/istio-token /var/run/secrets/tokens/istio-token'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/mesh /etc/istio/config/mesh'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo chmod o+rx /usr/local/bin/{envoy,pilot-agent}
multipass exec "${WORKLOAD_VM_NAME}" -- sudo chmod 2755 /usr/local/bin/{envoy,pilot-agent}

multipass exec "${WORKLOAD_VM_NAME}" -- sudo chown -R istio-proxy.istio-proxy \
  /etc/certs \
  /etc/istio \
  /var/run/secrets \
  /var/lib/istio/envoy \
  /var/lib/istio/config \
  /var/log/istio \
  /var/lib/istio/config/mesh \
  /var/lib/istio/proxy
