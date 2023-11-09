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
