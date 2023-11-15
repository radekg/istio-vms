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
      caAddress: cert-manager-istio-csr.${CERT_MANAGER_NAMESPACE}.svc:443
      istioNamespace: ${ISTIO_NAMESPACE}
      meshID: ${ISTIO_MESH_ID}
      multiCluster:
        clusterName: "${ISTIO_CLUSTER}"
      network: "${CLUSTER_NETWORK}"
  components:
    pilot:
      k8s:
        env:
        - name: ENABLE_CA_SERVER
          value: "false"
        - name: PILOT_ENABLE_WORKLOAD_ENTRY_AUTOREGISTRATION
          value: "true"
        - name: PILOT_ENABLE_WORKLOAD_ENTRY_HEALTHCHECKS
          value: "true"
        overlays:
        - apiVersion: apps/v1
          kind: Deployment
          name: istiod-${ISTIO_REVISION}
          patches:

            # Mount istiod serving and webhook certificate from Secret mount
          - path: spec.template.spec.containers.[name:discovery].args[-1]
            value: "--tlsCertFile=/etc/cert-manager/tls/tls.crt"
          - path: spec.template.spec.containers.[name:discovery].args[-1]
            value: "--tlsKeyFile=/etc/cert-manager/tls/tls.key"
          - path: spec.template.spec.containers.[name:discovery].args[-1]
            value: "--caCertFile=/etc/cert-manager/ca/root-cert.pem"

          - path: spec.template.spec.containers.[name:discovery].volumeMounts[-1]
            value:
              name: cert-manager
              mountPath: "/etc/cert-manager/tls"
              readOnly: true
          - path: spec.template.spec.containers.[name:discovery].volumeMounts[-1]
            value:
              name: ca-root-cert
              mountPath: "/etc/cert-manager/ca"
              readOnly: true

          - path: spec.template.spec.volumes[-1]
            value:
              name: cert-manager
              secret:
                secretName: istiod-tls-${ISTIO_REVISION}
          - path: spec.template.spec.volumes[-1]
            value:
              name: ca-root-cert
              configMap:
                defaultMode: 420
                name: istio-ca-root-cert
EOP

istioctl install -y -f "${TEMP_DIR}/vm-cluster.yaml"
