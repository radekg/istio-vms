#!/bin/bash

set -eu
base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

wget -O "${TEMP_DIR}/gen-eastwest-gateway.sh" https://raw.githubusercontent.com/istio/istio/master/samples/multicluster/gen-eastwest-gateway.sh
sed -i '' 's!port: '${DEFAULT_PORT_STATUS}'!port: '${EWG_PORT_STATUS}'!' "${TEMP_DIR}/gen-eastwest-gateway.sh"
sed -i '' 's!port: '${DEFAULT_PORT_TLS_ISTIOD}'!port: '${EWG_PORT_TLS_ISTIOD}'!' "${TEMP_DIR}/gen-eastwest-gateway.sh"
sed -i '' 's!port: '${DEFAULT_PORT_TLS_WEBHOOK}'!port: '${EWG_PORT_TLS_WEBHOOK}'!' "${TEMP_DIR}/gen-eastwest-gateway.sh"
chmod +x "${TEMP_DIR}/gen-eastwest-gateway.sh"

"${TEMP_DIR}/gen-eastwest-gateway.sh" \
  --mesh "${ISTIO_MESH_ID}" \
  --cluster "${ISTIO_CLUSTER}" \
  --network "${CLUSTER_NETWORK}" \
  --revision "${ISTIO_REVISION}" | istioctl install --istioNamespace="${ISTIO_NAMESPACE}" -y -f -

kubectl apply -f - <<EOP
# Source: https://raw.githubusercontent.com/istio/istio/master/samples/multicluster/expose-istiod.yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: istiod-gateway
  namespace: ${ISTIO_NAMESPACE}
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        name: tls-istiod
        number: ${EWG_PORT_TLS_ISTIOD}
        protocol: tls
      tls:
        mode: PASSTHROUGH        
      hosts:
        - "*"
    - port:
        name: tls-istiodwebhook
        number: ${EWG_PORT_TLS_WEBHOOK}
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
  namespace: ${ISTIO_NAMESPACE}
spec:
  hosts:
  - "*"
  gateways:
  - istiod-gateway
  tls:
  - match:
    - port: ${EWG_PORT_TLS_ISTIOD}
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod-${ISTIO_REVISION}.${ISTIO_NAMESPACE}.svc.cluster.local
        port:
          number: ${DEFAULT_PORT_TLS_ISTIOD}
  - match:
    - port: ${EWG_PORT_TLS_WEBHOOK}
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod-${ISTIO_REVISION}.${ISTIO_NAMESPACE}.svc.cluster.local
        port:
          number: 443
---
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cross-network-gateway
  namespace: ${ISTIO_NAMESPACE}
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

kubectl label namespace "${ISTIO_NAMESPACE}" topology.istio.io/network="${CLUSTER_NETWORK}"
