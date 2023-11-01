#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

WORKLOAD_IP=$(multipass info vm-istio-etxernal-workload --format yaml | yq '."vm-istio-etxernal-workload"[] | select(.state == "Running") | .ipv4[0]' -r)
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
    serviceAccount: "${SERVICE_ACCOUNT}"
    network: "${VM_NETWORK}"
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
