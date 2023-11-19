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

MASTER_IP=$(multipass info k3s-master --format yaml | yq '.k3s-master[] | select(.state == "Running") | .ipv4[0]' -r)
echo "Master IP address is: ${MASTER_IP}"

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

mv -v "${base}/.data/workload-files/hosts" "${base}/.data/workload-files/hosts.back"
cat > ${base}/.data/workload-files/hosts <<EOP
# Your system has configured 'manage_etc_hosts' as True.
# As a result, if you wish for changes to this file to persist
# then you will need to either
# a.) make changes to the master file in /etc/cloud/templates/hosts.debian.tmpl
# b.) change or remove the value of 'manage_etc_hosts' in
#     /etc/cloud/cloud.cfg or cloud-config from user-data
#
127.0.1.1 ${WORKLOAD_VM_NAME} ${WORKLOAD_VM_NAME}
127.0.0.1 localhost

# We need this so that we can reach the cert manager service through the load balancer.
# Our istio-csr is routable via the dedicated ingress.
# TODO: investigate how to protect this resource.
${MASTER_IP} cert-manager-istio-csr.${CERT_MANAGER_NAMESPACE}.svc

# The following lines are desirable for IPv6 capable hosts
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

$(cat ${base}/.data/workload-files/hosts.back)
EOP
rm -rfv "${base}/.data/workload-files/hosts.back"

if [ "${no_fix_ca}" == "false" ]; then
  echo "CA_ADDR='cert-manager-istio-csr.${CERT_MANAGER_NAMESPACE}.svc:${ISTIO_CSR_INGRESS_PORT_TLS}'" >> "${DATA_DIR}/workload-files/cluster.env"
fi

if [ "${no_fix_pilot}" == "false" ]; then
  echo "PILOT_ADDRESS='istiod-${ISTIO_REVISION}.${ISTIO_NAMESPACE}.svc:${EWG_PORT_TLS_ISTIOD}'" >> "${DATA_DIR}/workload-files/cluster.env"
fi

# istioctl proxy-config secret workloadgroup/external-app.vmns -o json
