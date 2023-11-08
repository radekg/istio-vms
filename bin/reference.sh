#!/bin/bash

set -eu pipefail

delete="false"
recreate="false"

for var in "$@"
do
  [ "${var}" == "--delete" ] && delete="true"
  [ "${var}" == "--recreate" ] && recreate="true"
done

if [ "${delete}" == "true" ]; then
  echo >&2 "Deleting the k3s cluster..."
  multipass delete k3s-master k3s-worker-1 k3s-worker-2
  multipass purge
  exit 0
fi

NORMAL="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"

_____="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

bail() {
    echo -e "Error: ${RED}$@${NORMAL}"
    echo
    exit 1
}

explain() {
    echo -e "${YELLOW}$@${NORMAL}"
    read -n1 -s -p "(paused)"
    echo
}

summary() {
    echo
    echo -e "${GREEN}$@${NORMAL}"
    echo
}

cyanide() {
    echo
    echo -e "🔥 Executing: ${CYAN}$@${NORMAL}"
    echo "🔥 ----------"
    $@
    echo
}

explain check tools

which_kubectl=`which kubectl`
which_istioctl=`which istioctl`
which_multipass=`which multipass`

[ -z "${which_kubectl}" ] && bail no kubectl found, kubectl is required
[ -z "`${which_istioctl}`" ] && bail no istioctl found, istioctl is required
[ -z "`${which_multipass}`" ] && bail no multipass found, multipass is required

echo "Using:"
echo "using kubectl:   ${which_kubectl}"
echo "using istioctl:  ${which_istioctl}"
echo "using multipass: ${which_multipass}"

explain get ourselves a directory

work_dir="/tmp/istio-vms-reference"
rm -rf "${work_dir}" && mkdir -p "${work_dir}"
cyanide cd "${work_dir}"

cleanup() {
  set +e
  summry cleaning up
  [ -f "${work_dir}/install.k3s.sh" ] && "${work_dir}/install.k3s.sh" --delete
  [ -f "${work_dir}/install.vm.sh" ] && "${work_dir}/install.vm.sh" --delete
  exit 2
}

trap cleanup SIGINT

summary we are now in "${work_dir}"

explain bring ourselves into the working directory "${work_dir}"

git clone https://github.com/radekg/istio-vms.git .

summary cloned required tools into this directory
tree "${work_dir}"

explain write and source the run.env file

cat <<'EOF' > "${work_dir}/run.env"
#!/bin/bash
env_base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export DATA_DIR="${env_base}/.data/"
mkdir -p "${DATA_DIR}"
export TEMP_DIR="${env_base}/.tmp/"
mkdir -p "${TEMP_DIR}"
export KUBECONFIG="${DATA_DIR}/.kubeconfig"
export CONTAINER_TOOL=${CONTAINER_TOOL:-docker}
# Settings:
export RUN_OS=22.04
export ISTIO_VERSION=${ISTIO_VERSION:-1.19.3}
export ISTIO_REVISION=$(echo $ISTIO_VERSION | tr '.' '-')
# Resources:
export CPU_MASTER=2
export CPU_WORKER=2
export DISK_MASTER=4G
export DISK_WORKER=8G
export MEM_MASTER=1G
export MEM_WORKER=8G
# VM-related configuration:
export WORKLOAD_VM_NAME=vm-istio-external-workload
export ISTIO_CLUSTER=test
export VM_APP="external-app"
export VM_NAMESPACE="vmns"
export SERVICE_ACCOUNT="vmsa"
export CLUSTER_NETWORK="kube-network"
export VM_NETWORK="vm-network"

# However, if there's a run.env file in pwd, use that one:
pwd=`pwd`
if [ "${pwd}" != "${env_base}" ]; then
  [ -f "${pwd}/run.env" ] && source "${pwd}/run.env" && >&2 echo "configured from ${pwd}/run.env"
fi
EOF
source "${work_dir}/run.env"

explain create the k3s cluster with multipass, traefik disabled
# To use Istio ingress as a gateway, Traefik needs to be switched off.

cat <<'EOF' > "${work_dir}/install.k3s.sh"
#!/bin/bash

delete="false"
recreate="false"

for var in "$@"
do
  [ "${var}" == "--delete" ] && delete="true"
  [ "${var}" == "--recreate" ] && recreate="true"
done

if [ "${delete}" == "true" ]; then
  echo >&2 "Deleting the k3s cluster..."
  multipass delete k3s-master k3s-worker-1 k3s-worker-2
  multipass purge
  exit 0
fi

if [ "${recreate}" == "true" ]; then
  echo >&2 "Recreating the k3s cluster..."
  multipass delete k3s-master k3s-worker-1 k3s-worker-2
  multipass purge
fi

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

set +e; multipass launch -c "${CPU_MASTER}" -m "${MEM_MASTER}" -d "${DISK_MASTER}" -n k3s-master "${RUN_OS}"; set -e

multipass exec k3s-master -- bash -c 'curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik" sh'
TOKEN=$(multipass exec k3s-master sudo cat /var/lib/rancher/k3s/server/node-token)
MASTER_IP=$(multipass info k3s-master | grep IPv4 | awk '{print $2}')

for f in 1 2; do
  set +e; multipass launch -c "${CPU_WORKER}" -m "${MEM_WORKER}" -d "${DISK_WORKER}" -n k3s-worker-$f "${RUN_OS}"; set -e
done

for f in 1 2; do
  multipass exec k3s-worker-$f -- \
    bash -c "curl -sfL https://get.k3s.io | K3S_URL=\"https://${MASTER_IP}:6443\" K3S_TOKEN=\"${TOKEN}\" sh -"
done


multipass exec k3s-master sudo cat /etc/rancher/k3s/k3s.yaml > "${KUBECONFIG}"
# Update the IP address to the one mapped by multipass
sed -i '' "s/127.0.0.1/${MASTER_IP}/" "${KUBECONFIG}"
chmod 600 "${KUBECONFIG}"
EOF
chmod +x "${work_dir}/install.k3s.sh" && "${work_dir}/install.k3s.sh" --recreate

explain what nodes do we have? is istioctl working?

kubectl get nodes
istioctl version

explain install Istio

cat <<'EOF' > "${work_dir}/install.istio.sh"
#!/bin/bash

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

set -eu

cat <<EOP > "${TEMP_DIR}/vm-cluster.yaml"
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio
spec:
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: "${ISTIO_CLUSTER}"
      network: "${CLUSTER_NETWORK}"
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: false
EOP

istioctl install -y -f "${TEMP_DIR}/vm-cluster.yaml" \
  --set values.pilot.env.PILOT_ENABLE_WORKLOAD_ENTRY_AUTOREGISTRATION=true \
  --set values.pilot.env.PILOT_ENABLE_WORKLOAD_ENTRY_HEALTHCHECKS=true
EOF
chmod +x "${work_dir}/install.istio.sh" && "${work_dir}/install.istio.sh"

explain wait for Istio to come up

cyanide kubectl get services -n istio-system
summary istio is up and running, note that we have no ingress service

explain install eastwest gateway

cat <<'EOF' > "${work_dir}/install.eastwest.gateway.sh"
#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"
mkdir -p "${base}/bin/"
wget -O "${base}/bin/gen-eastwest-gateway.sh" https://raw.githubusercontent.com/istio/istio/master/samples/multicluster/gen-eastwest-gateway.sh
chmod +x "${base}/bin/gen-eastwest-gateway.sh"

"${base}/bin/gen-eastwest-gateway.sh" \
  --mesh mesh1 --cluster "${ISTIO_CLUSTER}" --network "${CLUSTER_NETWORK}" | istioctl install -y -f -

kubectl apply -n istio-system -f - <<EOP
# Source: https://raw.githubusercontent.com/istio/istio/master/samples/multicluster/expose-istiod.yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: istiod-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        name: tls-istiod
        number: 15012
        protocol: tls
      tls:
        mode: PASSTHROUGH        
      hosts:
        - "*"
    - port:
        name: tls-istiodwebhook
        number: 15017
        protocol: tls
      tls:
        mode: PASSTHROUGH          
      hosts:
        - "*"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: istiod-vs
spec:
  hosts:
  - "*"
  gateways:
  - istiod-gateway
  tls:
  - match:
    - port: 15012
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod.istio-system.svc.cluster.local
        port:
          number: 15012
  - match:
    - port: 15017
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod.istio-system.svc.cluster.local
        port:
          number: 443
EOP

kubectl apply -n istio-system -f - <<EOP
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
EOP

kubectl label namespace istio-system topology.istio.io/network="${CLUSTER_NETWORK}"
EOF
chmod +x "${work_dir}/install.eastwest.gateway.sh" && "${work_dir}/install.eastwest.gateway.sh"

explain wait for istio-eastwestgateway external-ip assignment

cyanide kubectl get services -n istio-system
summary repeat until istio-eastwestgateway received the external IP

summary arm64 binary patches, system specific

cat <<'EOF' > "${work_dir}/install.arm64.binary.patches.sh"
#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

arm64_patch_dir="${TEMP_DIR}/istio-proxy-${ISTIO_VERSION}-arm64"
rm -rf "${arm64_patch_dir}" && mkdir -p "${arm64_patch_dir}" && cd "${arm64_patch_dir}"
${CONTAINER_TOOL} create --name="istio-export-${ISTIO_REVISION}" "docker.io/istio/proxyv2:${ISTIO_VERSION}" --platform linux/arm64
${CONTAINER_TOOL} export istio-export-1-19-3 | tar x
${CONTAINER_TOOL} rm "istio-export-${ISTIO_REVISION}"
EOF
chmod +x "${work_dir}/install.arm64.binary.patches.sh" && "${work_dir}/install.arm64.binary.patches.sh"

explain create the workload

cat <<'EOF' > "${work_dir}/install.workload.sh"
#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

WORKLOAD_IP=$(multipass info "${WORKLOAD_VM_NAME}" --format yaml | yq '.'${WORKLOAD_VM_NAME}'[] | select(.state == "Running") | .ipv4[0]' -r)
echo "Workload IP address is: ${WORKLOAD_IP}"

set +e; kubectl create namespace "${VM_NAMESPACE}"; set -e
kubectl wait --for jsonpath='{.status.phase}=Active' --timeout=5s "namespace/${VM_NAMESPACE}"
set +e; kubectl create serviceaccount "${SERVICE_ACCOUNT}" -n "${VM_NAMESPACE}"; set -e

cat <<EOP > "${base}/.tmp/workloadgroup.yaml"
apiVersion: networking.istio.io/v1alpha3
kind: WorkloadGroup
metadata:
  name: "${VM_APP}"
  namespace: "${VM_NAMESPACE}"
spec:
  metadata:
    labels:
      app: "${VM_APP}"
  template:
    ports:
      http: 8000
    serviceAccount: "${SERVICE_ACCOUNT}"
    network: "${VM_NETWORK}"
  probe:
    periodSeconds: 5
    initialDelaySeconds: 1
    httpGet:
      port: 8000
      path: /
EOP

kubectl apply -n "${VM_NAMESPACE}" -f "${TEMP_DIR}/workloadgroup.yaml"

rm -rf "${DATA_DIR}/workload-files"
mkdir -p "${DATA_DIR}/workload-files"

while [ ! -f "${DATA_DIR}/workload-files/root-cert.pem" ]; do
  istioctl x workload entry configure -f "${TEMP_DIR}/workloadgroup.yaml" \
    -o "${DATA_DIR}/workload-files" \
    --clusterID "${ISTIO_CLUSTER}" \
    --externalIP "${WORKLOAD_IP}" \
    --autoregister
  sleep 5
done
EOF
chmod +x "${work_dir}/install.workload.sh" && "${work_dir}/install.workload.sh"

explain what just happened

summary we generated those files
cyanide ls -la ${DATA_DIR}/workload-files/

summary we have a workload group...
cyanide kubectl get workloadgroup -A

summary ... but no workload entries, as expected!
cyanide kubectl get workloadentry -A

summary for example, let\'s look at the "${DATA_DIR}/workload-files/hosts"
cat "${DATA_DIR}/workload-files/hosts"

explain install the vm

cat <<'EOF' > "${work_dir}/install.vm.sh"
#!/bin/bash

delete="false"
recreate="false"

for var in "$@"
do
  [ "${var}" == "--delete" ] && delete="true"
  [ "${var}" == "--recreate" ] && recreate="true"
done

if [ "${delete}" == "true" ]; then
  echo >&2 "Deleting the workload machine..."
  rm -rfv "${DATA_DIR}/workload-files"
  multipass delete "${WORKLOAD_VM_NAME}"
  multipass purge
  exit 0
fi

if [ "${recreate}" == "true" ]; then
  echo >&2 "Recreating the workload machine..."
  rm -rfv "${DATA_DIR}/workload-files"
  multipass delete "${WORKLOAD_VM_NAME}"
  multipass purge
fi

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

set +e; multipass launch -c 2 -m 1G -d 4G -n "${WORKLOAD_VM_NAME}" "${RUN_OS}"; set -e
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
multipass transfer --parents "${DATA_DIR}/workload-files/root-cert.pem" "${WORKLOAD_VM_NAME}":./workload/root-cert.pem
multipass transfer --parents "${DATA_DIR}/workload-files/cluster.env" "${WORKLOAD_VM_NAME}":./workload/cluster.env
multipass transfer --parents "${DATA_DIR}/workload-files/istio-token" "${WORKLOAD_VM_NAME}":./workload/istio-token
multipass transfer --parents "${DATA_DIR}/workload-files/mesh.yaml" "${WORKLOAD_VM_NAME}":./workload/mesh

cat > ${DATA_DIR}/workload-files/all-hosts <<EOP
# Your system has configured 'manage_etc_hosts' as True.
# As a result, if you wish for changes to this file to persist
# then you will need to either
# a.) make changes to the master file in /etc/cloud/templates/hosts.debian.tmpl
# b.) change or remove the value of 'manage_etc_hosts' in
#     /etc/cloud/cloud.cfg or cloud-config from user-data
#
127.0.1.1 ${WORKLOAD_VM_NAME} ${WORKLOAD_VM_NAME}
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

$(cat ${DATA_DIR}/workload-files/hosts)
EOP

multipass transfer --parents "${DATA_DIR}/workload-files/all-hosts" "${WORKLOAD_VM_NAME}":./workload/hosts
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
EOF
chmod +x "${work_dir}/install.vm.sh" && "${work_dir}/install.vm.sh"

summary "we have a vm, we can get access to it, time to switch to the readme: ### the vm: tl;dr"
