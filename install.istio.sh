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
  namespace: ${ISTIO_NAMESPACE}
  revision: ${ISTIO_REVISION}
  tag: ${ISTIO_VERSION}
  values:
    global:
      istioNamespace: ${ISTIO_NAMESPACE}
      meshID: ${ISTIO_MESH_ID}
      multiCluster:
        clusterName: "${ISTIO_CLUSTER}"
      network: "${CLUSTER_NETWORK}"
  components:
    pilot:
      k8s:
        env:
        - name: PILOT_ENABLE_WORKLOAD_ENTRY_AUTOREGISTRATION
          value: "true"
        - name: PILOT_ENABLE_WORKLOAD_ENTRY_HEALTHCHECKS
          value: "true"
EOP

istioctl install -y -f "${TEMP_DIR}/vm-cluster.yaml"
