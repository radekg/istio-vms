#!/bin/bash

set -eu
base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml

kubectl wait --for condition=available -n "${CERT_MANAGER_NAMESPACE}" --timeout=${TIMEOUT_DEPLOYMENT_WAIT} deployment/cert-manager-cainjector
kubectl wait --for condition=available -n "${CERT_MANAGER_NAMESPACE}" --timeout=${TIMEOUT_DEPLOYMENT_WAIT} deployment/cert-manager
kubectl wait --for condition=available -n "${CERT_MANAGER_NAMESPACE}" --timeout=${TIMEOUT_DEPLOYMENT_WAIT} deployment/cert-manager-webhook

# The namespace needs to exist because we need to place secrets in it.
set +e; kubectl create namespace "${ISTIO_NAMESPACE}"; set -e
kubectl wait --for jsonpath='{.status.phase}=Active' --timeout="${TIMEOUT_NAMESPACE_ACTIVE_WAIT}" "namespace/${ISTIO_NAMESPACE}"

# Create a self-signed root certificate, generate the istio root CA out of it,
# prepare the issuer for Istio. This new Issuer needs a secret that we create
# in the next step. We do it like this as we follow instructions from cert-manager
# documentation: https://cert-manager.io/docs/tutorials/istio-csr/istio-csr/#export-the-root-ca-to-a-local-file.
# Apparently we prevent a signer hijacking attack in this way.
kubectl apply -f -<<EOF
# SelfSigned issuers are useful for creating root certificates
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned
  namespace: ${ISTIO_NAMESPACE}
spec:
  selfSigned: {}
---
# Request a self-signed certificate from our Issuer; this will function as our
# issuing root certificate when we pass it into a CA Issuer.

# It's generally fine to issue root certificates like this one with long lifespans;
# the certificates which istio-csr issues will be much shorter lived.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ca
  namespace: ${ISTIO_NAMESPACE}
spec:
  isCA: true
  duration: 87600h # 10 years
  secretName: istio-ca
  commonName: istio-ca
  privateKey:
    algorithm: ECDSA
    size: 256
  subject:
    organizations:
    - cluster.local
    - ${CERT_MANAGER_NAMESPACE}
  issuerRef:
    name: selfsigned
    kind: Issuer
    group: cert-manager.io
---
# Create a CA issuer using our root. This will be the Issuer which istio-csr will use.
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: istio-ca
  namespace: ${ISTIO_NAMESPACE}
spec:
  ca:
    secretName: istio-ca
EOF

# Here we create the secret used by the istio-ca Issuer.
wait-for-k8s-secret istio-ca "${ISTIO_NAMESPACE}"
kubectl get -n "${ISTIO_NAMESPACE}" secret istio-ca -ogo-template='{{index .data "tls.crt"}}' | base64 -d > "${TEMP_DIR}/ca.pem"
kubectl delete secret -n "${CERT_MANAGER_NAMESPACE}" istio-root-ca --ignore-not-found=true
kubectl create secret generic -n "${CERT_MANAGER_NAMESPACE}" istio-root-ca --from-file="ca.pem=${TEMP_DIR}/ca.pem"

# Because we use revisioned Istio installation, we require a TLS certifiate for every Istiod we run.
kubectl apply -f -<<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istiod-${ISTIO_REVISION}
  namespace: ${ISTIO_NAMESPACE}
spec:
  commonName: istiod-${ISTIO_REVISION}.${ISTIO_NAMESPACE}.svc
  dnsNames:
  - istiod-${ISTIO_REVISION}.${ISTIO_NAMESPACE}.svc
  duration: 1h0m0s
  issuerRef:
    group: cert-manager.io
    kind: Issuer
    name: istio-ca
  privateKey:
    algorithm: RSA
    rotationPolicy: Always
    size: 4096
  renewBefore: 15m0s
  secretName: istiod-tls-${ISTIO_REVISION}
  uris:
  - spiffe://cluster.local/ns/${ISTIO_NAMESPACE}/istiod-${ISTIO_REVISION}
EOF

# Install istio-csr:
helm repo add jetstack https://charts.jetstack.io
helm repo update

# CAUTION: We do have to change the app.server.clusterID to match our Istio cluster ID.
# If we don't, we will observe an error similar to this one:
#    error	klog	grpc-server "msg"="failed to authenticate request" "error"="could not get cluster test's kube client" "serving-addr"="0.0.0.0:16443"
# This error is a little bit confusing because it will tell us that the client for our clusterID cannot
# be found while the default clusterID name used by istio-csr is Kubernetes.
# Which makes sense because istio-csr tries contacting the Kubernetes clusterID
# but Istio wasnts ISTIO_CLUSTER value, which in the case of an error above, was test.
set +e
helm install -n "${CERT_MANAGER_NAMESPACE}" cert-manager-istio-csr jetstack/cert-manager-istio-csr \
	--set "app.tls.trustDomain=cluster.local" \
  --set "app.tls.rootCAFile=/var/run/secrets/istio-csr/ca.pem" \
  --set "app.istio.revisions[0]=default" \
  --set "app.istio.revisions[1]=${ISTIO_REVISION}" \
  --set "app.server.clusterID=${ISTIO_CLUSTER}" \
  --set "app.server.serving.port=16443" \
	--set "volumeMounts[0].name=root-ca" \
	--set "volumeMounts[0].mountPath=/var/run/secrets/istio-csr" \
	--set "volumes[0].name=root-ca" \
	--set "volumes[0].secret.secretName=istio-root-ca"
set -e

kubectl wait --for condition=available -n "${CERT_MANAGER_NAMESPACE}" --timeout=${TIMEOUT_DEPLOYMENT_WAIT} deployment/cert-manager-istio-csr

