#!/bin/bash

no_fix_ca="false"
no_fix_pilot="false"

for var in "$@"
do
  [ "${var}" == "--no-fix-ca" ] && no_fix_ca="true"
  [ "${var}" == "--no-fix-pilot" ] && no_fix_pilot="true"
done

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
    --revision "${ISTIO_REVISION}" \
    --istioNamespace "${ISTIO_NAMESPACE}" \
    --autoregister
  sleep 5
done

if [ "${no_fix_ca}" == "false" ]; then
  echo "CA_ADDR=istiod-'${ISTIO_REVISION}.${ISTIO_NAMESPACE}.svc:${EWG_PORT_TLS_ISTIOD}'" >> "${DATA_DIR}/workload-files/cluster.env"
fi

if [ "${no_fix_pilot}" == "false" ]; then
  echo "PILOT_ADDRESS='istiod-${ISTIO_REVISION}.${ISTIO_NAMESPACE}.svc:${EWG_PORT_TLS_ISTIOD}'" >> "${DATA_DIR}/workload-files/cluster.env"
fi
