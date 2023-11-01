#!/bin/bash

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

set -eu

ISTIO_CLUSTER=test
VM_APP="external-app"
VM_NAMESPACE="vmns"
SERVICE_ACCOUNT="vmsa"
CLUSTER_NETWORK="kube-network"
VM_NETWORK="vm-network"

cat <<EOF > "${base}/.tmp/vm-cluster.yaml"
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
EOF

istioctl install -f "${base}/.tmp/vm-cluster.yaml" \
  --set values.pilot.env.PILOT_ENABLE_WORKLOAD_ENTRY_AUTOREGISTRATION=true \
  --set values.pilot.env.PILOT_ENABLE_WORKLOAD_ENTRY_HEALTHCHECKS=true

"${base}/bin/generate-eastwest-gateway.sh" --mesh mesh1 --cluster "${ISTIO_CLUSTER}" --network "${CLUSTER_NETWORK}" | \
  istioctl install -y -f -

kubectl apply -n istio-system -f - <<EOF
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
EOF

kubectl apply -n istio-system -f - <<EOF
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
EOF

kubectl label namespace istio-system topology.istio.io/network="${CLUSTER_NETWORK}"

set +e; kubectl create namespace "${VM_NAMESPACE}"; set -e
kubectl wait --for jsonpath='{.status.phase}=Active' --timeout=5s "namespace/${VM_NAMESPACE}"
set +e; kubectl create serviceaccount "${SERVICE_ACCOUNT}" -n "${VM_NAMESPACE}"; set -e

cat <<EOF > "${base}/.tmp/workloadgroup.yaml"
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
EOF

kubectl apply -n "${VM_NAMESPACE}" -f "${base}/.tmp/workloadgroup.yaml"

rm -rf "${DATA_DIR}/workload-files"
mkdir -p "${DATA_DIR}/workload-files"

while [ ! -f "${DATA_DIR}/workload-files/root-cert.pem" ]; do
  istioctl x workload entry configure -f "${base}/.tmp/workloadgroup.yaml" \
    -o "${DATA_DIR}/workload-files" \
    --clusterID "${ISTIO_CLUSTER}" \
    --autoregister
  sleep 5
done

exit 0

kubectl create namespace sample
kubectl label namespace sample istio-injection=enabled
kubectl apply -n sample -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: helloworld
  labels:
    app: helloworld
    service: helloworld
spec:
  ports:
  - port: 5000
    name: http
  selector:
    app: helloworld
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloworld-v1
  labels:
    app: helloworld
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: helloworld
      version: v1
  template:
    metadata:
      labels:
        app: helloworld
        version: v1
    spec:
      containers:
      - name: helloworld
        image: docker.io/radekg/examples-helloworld-v1
        resources:
          requests:
            cpu: "100m"
        imagePullPolicy: IfNotPresent #Always
        ports:
        - containerPort: 5000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloworld-v2
  labels:
    app: helloworld
    version: v2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: helloworld
      version: v2
  template:
    metadata:
      labels:
        app: helloworld
        version: v2
    spec:
      containers:
      - name: helloworld
        image: docker.io/radekg/examples-helloworld-v2
        resources:
          requests:
            cpu: "100m"
        imagePullPolicy: IfNotPresent #Always
        ports:
        - containerPort: 5000
EOF
```

