#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"
mkdir -p "${base}/bin/"
wget -O "${base}/bin/gen-eastwest-gateway.sh" https://raw.githubusercontent.com/istio/istio/master/samples/multicluster/gen-eastwest-gateway.sh
chmod +x "${base}/bin/generate-eastwest-gateway.sh"

"${base}/bin/generate-eastwest-gateway.sh" \
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
