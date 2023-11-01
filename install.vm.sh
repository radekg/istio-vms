#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

set +e; multipass launch -c 2 -m 1G -d 4G -n vm-istio-etxernal-workload "${RUN_OS}"; set -e
WORKLOAD_IP=$(multipass info vm-istio-etxernal-workload --format yaml | yq '."vm-istio-etxernal-workload"[] | select(.state == "Running") | .ipv4[0]' -r)
echo "Workload IP address is: ${WORKLOAD_IP}"

# From the istio/proxyv2 image, copy arm64 binaries as istio-sidecar.deb is amd54 only:
arm64_patch_dir="${base}/.tmp/istio-proxy-${ISTIO_VERSION}-arm64"
if [ -f "${arm64_patch_dir}/usr/local/bin/envoy" ]; then
  multipass transfer --parents "${arm64_patch_dir}/usr/local/bin/envoy" vm-istio-etxernal-workload:./usr/local/bin/envoy
  multipass transfer --parents "${arm64_patch_dir}/usr/local/bin/pilot-agent" vm-istio-etxernal-workload:./usr/local/bin/pilot-agent
fi

# istio-sidecar.deb:
multipass transfer --parents "${DATA_DIR}/istio-sidecar/usr/local/bin/istio-start.sh" vm-istio-etxernal-workload:./usr/local/bin/istio-start.sh
multipass transfer --parents "${DATA_DIR}/istio-sidecar/lib/systemd/system/istio.service" vm-istio-etxernal-workload:./lib/systemd/system/istio.service 
multipass transfer --parents "${DATA_DIR}/istio-sidecar/var/lib/istio/envoy/envoy_bootstrap_tmpl.json" vm-istio-etxernal-workload:./var/lib/istio/envoy/envoy_bootstrap_tmpl.json
multipass transfer --parents "${DATA_DIR}/istio-sidecar/var/lib/istio/envoy/sidecar.env" vm-istio-etxernal-workload:./var/lib/istio/envoy/sidecar.env

# Configure the istio-sidecar.deb-like environment:
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /etc/certs
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /etc/istio/config
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/lib/istio/config
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/lib/istio/envoy
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/lib/istio/proxy
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/log/istio
multipass exec vm-istio-etxernal-workload -- sudo touch /var/lib/istio/config/mesh
if [ -f "${arm64_patch_dir}/usr/local/bin/envoy" ]; then
  multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v usr/local/bin/* /usr/local/bin/'
  multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v lib/systemd/system/istio.service /lib/systemd/system/istio.service'
  multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v var/lib/istio/envoy/* /var/lib/istio/envoy/'
  # From postinst:
  set +e; multipass exec vm-istio-etxernal-workload -- sudo groupadd --system istio-proxy; set -e
  set +e; multipass exec vm-istio-etxernal-workload -- sudo useradd --system --gid istio-proxy --home-dir /var/lib/istio istio-proxy; set -e
else
  multipass exec vm-istio-etxernal-workload -- sudo bash -c 'curl -LO https://storage.googleapis.com/istio-release/releases/'${ISTIO_VERSION}'/deb/istio-sidecar.deb && sudo dpkg -i istio-sidecar.deb'
fi

# Deploy workload files:
multipass transfer --parents "${base}/.data/workload-files/root-cert.pem" vm-istio-etxernal-workload:./workload/root-cert.pem
multipass transfer --parents "${base}/.data/workload-files/cluster.env" vm-istio-etxernal-workload:./workload/cluster.env
multipass transfer --parents "${base}/.data/workload-files/istio-token" vm-istio-etxernal-workload:./workload/istio-token
multipass transfer --parents "${base}/.data/workload-files/mesh.yaml" vm-istio-etxernal-workload:./workload/mesh

cat > ${base}/.data/workload-files/all-hosts <<EOP
# Your system has configured 'manage_etc_hosts' as True.
# As a result, if you wish for changes to this file to persist
# then you will need to either
# a.) make changes to the master file in /etc/cloud/templates/hosts.debian.tmpl
# b.) change or remove the value of 'manage_etc_hosts' in
#     /etc/cloud/cloud.cfg or cloud-config from user-data
#
127.0.1.1 vm-istio-etxernal-workload vm-istio-etxernal-workload
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

$(cat ${base}/.data/workload-files/hosts)
EOP

multipass transfer --parents "${base}/.data/workload-files/all-hosts" vm-istio-etxernal-workload:./workload/hosts
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/hosts /etc/hosts'
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/root-cert.pem /etc/certs/root-cert.pem'
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/cluster.env /var/lib/istio/envoy/cluster.env'
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/run/secrets/tokens
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/istio-token /var/run/secrets/tokens/istio-token'
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/mesh /etc/istio/config/mesh'
multipass exec vm-istio-etxernal-workload -- sudo chmod o+rx /usr/local/bin/{envoy,pilot-agent}
multipass exec vm-istio-etxernal-workload -- sudo chmod 2755 /usr/local/bin/{envoy,pilot-agent}

multipass exec vm-istio-etxernal-workload -- sudo chown -R istio-proxy.istio-proxy \
  /etc/certs \
  /etc/istio \
  /var/run/secrets \
  /var/lib/istio/envoy \
  /var/lib/istio/config \
  /var/log/istio \
  /var/lib/istio/config/mesh \
  /var/lib/istio/proxy
