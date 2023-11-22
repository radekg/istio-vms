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
      jwtPolicy: third-party-jwt
      meshID: ${ISTIO_MESH_ID}
      multiCluster:
        clusterName: "${ISTIO_CLUSTER}"
      network: "${CLUSTER_NETWORK}"
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: false
    - name: istio-csr-ingressgateway
      enabled: true
      k8s:
        env:
        - name: ISTIO_META_ROUTER_MODE
          value: isitio-csr
        service:
          ports:
          - name: https
            port: ${ISTIO_CSR_INGRESS_PORT_TLS}
      label:
        istio: istio-csr-ingressgateway
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

# Expose istio-csr via the dedicated ingress gateway.
# ---------------------------------------------------
# How does this work:
# The gateway accepts anything on HTTPS where the hostname is istio-csr's internal hostname.
# Since this is on the ingress, Istio happily takes it because this request did not originate
# from inside of the cluster, and sends it to exactly the same address but in the cluster.
# Now, the reason why this is necessary: the Istio sidecar validates the hostname using the TLS
# certificate. Since istio-csr serves under cert-manager-istio-csr.${CERT_MANAGER_NAMESPACE}.svc,
# any request routed to it from the ingress gateway, needs to be done via exactly the same hostname.

kubectl apply -f - <<EOF
---
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cert-manager-istio-csr-gtw
  namespace: ${CERT_MANAGER_NAMESPACE}
spec:
  selector:
    istio: istio-csr-ingressgateway
  servers:
  - port:
      number: ${ISTIO_CSR_INGRESS_PORT_TLS}
      name: https
      protocol: HTTPS
    tls:
      mode: PASSTHROUGH
    hosts:
    - cert-manager-istio-csr.${CERT_MANAGER_NAMESPACE}.svc
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: cert-manager-istio-csr-vs
  namespace: ${CERT_MANAGER_NAMESPACE}
spec:
  hosts:
  - cert-manager-istio-csr.${CERT_MANAGER_NAMESPACE}.svc
  gateways:
  - cert-manager-istio-csr-gtw
  tls:
  - match:
    - port: ${ISTIO_CSR_INGRESS_PORT_TLS}
      sniHosts:
      - cert-manager-istio-csr.${CERT_MANAGER_NAMESPACE}.svc
    route:
    - destination:
        host: cert-manager-istio-csr.${CERT_MANAGER_NAMESPACE}.svc.cluster.local
EOF

# Protect the Istio CSR ingress gateway so that it is accessible by the VMs only.
# The request will come from the IP address within the cluster CIDR, so let's
# prepare for that. The Istio CSR ingress will allow traffic only from the 
# cluster network.
CLUSTER_CIDR=$(kubectl get nodes k3s-master -o jsonpath='{.spec.podCIDR}')

kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: istio-csr-ingress-policy
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: istio-csr-ingressgateway
  action: ALLOW
  rules:
  - from:
    - source:
        remoteIpBlocks:
        - "${CLUSTER_CIDR}"
EOF
