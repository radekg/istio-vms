I am going to connect a VM to the Istio mesh running in the Kubernetes cluster.

I will need:

- A VM.
- A Kubernetes cluster.
- Containers.

This is not a job for _KinD_ because I need a VM. So, it's _Multipass_. I am going to run:

- A _k3s_ cluster on _Multipass_.
- A VM on _Multipass_, same network as the _k3s_ cluster.

After setting up the _k3s_ cluster, I follow the steps from Istio documentation: [Virtual Machine Installation](https://istio.io/latest/docs/setup/install/virtual-machine/).

## tools

Besides the standard `kubectl`:

- `multipass`: macOS `brew install multipass`, Linux [official instructions](https://multipass.run/docs/installing-on-linux) or follow instructions for your distribution,
- `git`: to fetch the additional data,
- `yq`: follow [an official guide](https://github.com/mikefarah/yq#install),
- `docker` or `podman` if you are on an _arm64-based_ host,
- `istioctl`: instructions [further in the article](#install-istioctl).

## working directory

Remain in this directory all the time:

```sh
mkdir -p ~/.project && cd ~/.project
git clone https://github.com/radekg/istio-vms.git .
```

The _git_ command brings all the additional data files required by various steps.

## configure the environment

```sh
cat <<'EOF' > run.env
#!/bin/bash
env_base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export DATA_DIR="${env_base}/.data/"
mkdir -p "${DATA_DIR}"
export TEMP_DIR="${env_base}/.tmp/"
mkdir -p "${TEMP_DIR}"
export KUBECONFIG="${DATA_DIR}/.kubeconfig"
export CONTAINER_TOOL=${CONTAINER_TOOL:-docker}
# Settings:
export RUN_OS=22.04
export ISTIO_VERSION=${ISTIO_VERSION:-1.19.3}
export ISTIO_REVISION=$(echo $ISTIO_VERSION | tr '.' '-')
# Resources:
export CPU_MASTER=2
export CPU_WORKER=2
export DISK_MASTER=4G
export DISK_WORKER=8G
export MEM_MASTER=1G
export MEM_WORKER=8G
# VM-related configuration:
export WORKLOAD_VM_NAME=vm-istio-external-workload
export ISTIO_CLUSTER=test
export VM_APP="external-app"
export VM_NAMESPACE="vmns"
export SERVICE_ACCOUNT="vmsa"
export CLUSTER_NETWORK="kube-network"
export VM_NETWORK="vm-network"

# However, if there's a run.env file in pwd, use that one:
pwd=`pwd`
if [ "${pwd}" != "${env_base}" ]; then
  [ -f "${pwd}/run.env" ] && source "${pwd}/run.env" && >&2 echo "configured from ${pwd}/run.env"
fi
EOF
```

## setting up the _k3s_ cluster

This program starts the cluster:

```sh
cat <<'EOF' > install.k3s.sh
#!/bin/bash

delete="false"
recreate="false"

for var in "$@"
do
  [ "${var}" == "--delete" ] && delete="true"
  [ "${var}" == "--recreate" ] && recreate="true"
done

if [ "${delete}" == "true" ]; then
  echo >&2 "Deleting the k3s cluster..."
  multipass delete k3s-master k3s-worker-1 k3s-worker-2
  multipass purge
  exit 0
fi

if [ "${recreate}" == "true" ]; then
  echo >&2 "Recreating the k3s cluster..."
  multipass delete k3s-master k3s-worker-1 k3s-worker-2
  multipass purge
fi

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

set +e; multipass launch -c "${CPU_MASTER}" -m "${MEM_MASTER}" -d "${DISK_MASTER}" -n k3s-master "${RUN_OS}"; set -e

multipass exec k3s-master -- bash -c 'curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik" sh'
TOKEN=$(multipass exec k3s-master sudo cat /var/lib/rancher/k3s/server/node-token)
MASTER_IP=$(multipass info k3s-master | grep IPv4 | awk '{print $2}')

for f in 1 2; do
  set +e; multipass launch -c "${CPU_WORKER}" -m "${MEM_WORKER}" -d "${DISK_WORKER}" -n k3s-worker-$f "${RUN_OS}"; set -e
done

for f in 1 2; do
  multipass exec k3s-worker-$f -- \
    bash -c "curl -sfL https://get.k3s.io | K3S_URL=\"https://${MASTER_IP}:6443\" K3S_TOKEN=\"${TOKEN}\" sh -"
done


multipass exec k3s-master sudo cat /etc/rancher/k3s/k3s.yaml > "${KUBECONFIG}"
# Update the IP address to the one mapped by multipass
sed -i '' "s/127.0.0.1/${MASTER_IP}/" "${KUBECONFIG}"
chmod 600 "${KUBECONFIG}"
EOF

chmod +x install.k3s.sh && ./install.k3s.sh
```

This will start a _k3s_ cluster with one control plane and two workers. _Traefik_ is disabled because we use Istio. Also, the default load balancer is on: _Klipper_.

Please be mindful of the rather high resource requirement. Adjust as you see fit.

The cluster can be deleted with:

```sh
./install.k3s.sh --delete
```

and recreated (removed and created again) with:

```sh
./install.k3s.sh --recreate
```

## setting up the client

To have your _kubectl_ and and other tools use the correct kube config:

```sh
source run.env
```

## verify the cluster

```sh
kubectl get nodes
```

Something along the lines of:

```
NAME           STATUS   ROLES                  AGE     VERSION
k3s-master     Ready    control-plane,master   10m     v1.27.7+k3s1
k3s-worker-1   Ready    <none>                 9m26s   v1.27.7+k3s1
k3s-worker-2   Ready    <none>                 9m18s   v1.27.7+k3s1
```

## install istioctl

- `ISTIO_ARCH`: one of `< osx-arm64`, `osx-amd64`, `linux-armv7`, `linux-arm64`, `linux-amd64 >`

```sh
cat <<'EOF' > install.istioctl.sh
#!/bin/bash
local_bin="${HOME}/.local/test-istio-vm-multipass/bin"
mkdir -p "${local_bin}/tmp/"
export PATH="${local_bin}:/usr/local/bin:${PATH}"
export ISTIO_VERSION=${ISTIO_VERSION:-1.19.3}
export ISTIO_ARCH=${ISTIO_ARCH:-osx-arm64}
wget "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz" -O "${local_bin}/tmp/istioctl-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz"
tar xvzf "${local_bin}/tmp/istioctl-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz" -C "${local_bin}/tmp"
mv -v "${local_bin}/tmp/istioctl" "${local_bin}/istioctl-${ISTIO_VERSION}"
ln -sfv "${local_bin}/istioctl-${ISTIO_VERSION}" "${local_bin}/istioctl"
rm -rf "${local_bin}/tmp/*"
EOF
chmod +x install.istioctl.sh && ./install.istioctl.sh && which istioctl
```

Verify:

```sh
istioctl version
```

```
no ready Istio pods in "istio-system"
1.19.3
```

## preparing Istio installation

This is where I start to follow Istio documentation. First, I install Istio with one change:

- I disable the default ingress because it interferes [later on with the _eastwest_ gateway](#why-no-default-ingress-gateway).

Install Istio:

```sh
cat <<'EOF' > install.istio.sh
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
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: "${ISTIO_CLUSTER}"
      network: "${CLUSTER_NETWORK}"
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: false
EOP

istioctl install -y -f "${TEMP_DIR}/vm-cluster.yaml" \
  --set values.pilot.env.PILOT_ENABLE_WORKLOAD_ENTRY_AUTOREGISTRATION=true \
  --set values.pilot.env.PILOT_ENABLE_WORKLOAD_ENTRY_HEALTHCHECKS=true
EOF
chmod +x ./install.istio.sh && ./install.istio.sh
```

Verify:

```sh
kubectl get services -n istio-system
```

```
NAME     TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                                 AGE
istiod   ClusterIP   10.43.255.139   <none>        15010/TCP,15012/TCP,443/TCP,15014/TCP   39s
```

## install _eastwest_ gateway

```sh
cat <<'EOF' > install.eastwest.gateway.sh
#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"
mkdir -p "${base}/bin/"
wget -O "${base}/bin/gen-eastwest-gateway.sh" https://raw.githubusercontent.com/istio/istio/master/samples/multicluster/gen-eastwest-gateway.sh
chmod +x "${base}/bin/gen-eastwest-gateway.sh"

"${base}/bin/gen-eastwest-gateway.sh" \
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
EOF
chmod +x ./install.eastwest.gateway.sh && ./install.eastwest.gateway.sh
```

### why no default ingress gateway?

Okay, assuming that you'd have installed the default Istio ingress gateway, you'd be in this situation right now:

```sh
kubectl get services -n istio-system -w
```

```
kubectl get services -n istio-system -w
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP                                 PORT(S)                                                           AGE
istiod                  ClusterIP      10.43.255.139   <none>                                      15010/TCP,15012/TCP,443/TCP,15014/TCP                             17m
istio-ingressgateway    LoadBalancer   10.43.217.75    192.168.64.60,192.168.64.61,192.168.64.62   15021:31941/TCP,80:30729/TCP,443:32187/TCP                        11m
istio-eastwestgateway   LoadBalancer   10.43.106.169   <pending>                                   15021:31036/TCP,15443:32297/TCP,15012:31263/TCP,15017:32660/TCP   15s
```

The _eastwest_ gateway would be hanging in pending state because the default ingress already bound on required host ports. Hence, if you are in this situation, simply:

```sh
kubectl delete service istio-ingressgateway -n istio-system
```

and wait until:

```sh
kubectl get services -n istio-system -w
```

output similar to:

```
istio-eastwestgateway   LoadBalancer   10.43.106.169   192.168.64.60,192.168.64.61,192.168.64.62   15021:31036/TCP,15443:32297/TCP,15012:31263/TCP,15017:32660/TCP   3m43s
```

## the workload group

It's time to turn the attention to the VM. Start by creating a workload:

```sh
cat <<'EOF' > install.workload.sh
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
    --autoregister
  sleep 5
done
EOF
chmod +x install.workload.sh && ./install.workload.sh
```

Verify:

```sh
cat .data/workload-files/hosts
```

output similar to:

```
192.168.64.60 istiod.istio-system.svc
```

If there are no hosts here, your _eastwest_ gateway is most likely not working correctly. Do you have the default Istio ingress running? [I discussed this earlier in this article](#preparing-istio-installation).

## the vm: caveat on `arm64`

For example if you are on an M2 mac, like me... Istio documentation instructs to install Istio sidecar on the VM using a _deb_ package from a downloaded file. The problem is, _Multipass_ runs an `arm64` build of Ubuntu and the _deb_ package is available only for the `amd64` architecture. Eventually, trying to start Istio on the VM, you'd end up with:

```sh
sudo dpkg -i istio-sidecar.deb
```

```
dpkg: error processing archive istio-sidecar.deb (--install):
 package architecture (amd64) does not match system (arm64)
Errors were encountered while processing:
 istio-sidecar.deb
```

So, a workaround is necessary. I have to replicate the work done in the _deb_ package but I have to source `arm64` binaries.

### the _deb_ package

I decompressed it:

```sh
source run.env
wget "https://storage.googleapis.com/istio-release/releases/${ISTIO_VERSION}/deb/istio-sidecar.deb" \
  -O "${DATA_DIR}/istio-sidecar/istio-sidecar.deb"
tar xf "${DATA_DIR}/istio-sidecar/istio-sidecar.deb" -C "${DATA_DIR}/istio-sidecar/"
tar xf "${DATA_DIR}/istio-sidecar/data.tar.gz" -C "${DATA_DIR}/istio-sidecar/"
```

and kept the following:

```sh
git ls-tree -r HEAD ${DATA_DIR}/istio-sidecar
```

```
100644 blob c18ec3ce73f52fafe05585de91cd4cda2cdf3951	.data/istio-sidecar/lib/systemd/system/istio.service
100755 blob e022fbb08d4375a66276263b70380230e4702dbe	.data/istio-sidecar/usr/local/bin/istio-start.sh
100644 blob ab4bbffd39a7462db68312b7049828c7b4c1d673	.data/istio-sidecar/var/lib/istio/envoy/envoy_bootstrap_tmpl.json
100644 blob fc42e5483094378ca0f0b00cd52f81d1827531cb	.data/istio-sidecar/var/lib/istio/envoy/sidecar.env
```

### `arm64` binaries

**Skip if not on an `arm64` host**.

Two binaries have to be replaced with their `arm64` versions:

- `/usr/local/bin/envoy`
- `/usr/local/bin/pilot-agent`

For me, the easiest way I could come up with was to:

- Download the `linux/arm64` Istio `proxyv2` Docker image.
- Create a container, don't start it.
- Copy the files out of the file system.
- Remove the container.
- Reference exported filesystem for required `arm64` binaries.

```sh
cat <<'EOF' > install.arm64.binary.patches.sh
#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

arm64_patch_dir="${TEMP_DIR}/istio-proxy-${ISTIO_VERSION}-arm64"
rm -rf "${arm64_patch_dir}" && mkdir -p "${arm64_patch_dir}" && cd "${arm64_patch_dir}"
${CONTAINER_TOOL} create --name="istio-export-${ISTIO_REVISION}" "docker.io/istio/proxyv2:${ISTIO_VERSION}" --platform linux/arm64
${CONTAINER_TOOL} export istio-export-1-19-3 | tar x
${CONTAINER_TOOL} rm "istio-export-${ISTIO_REVISION}"
EOF
chmod +x install.arm64.binary.patches.sh && ./install.arm64.binary.patches.sh
```

You can run this with `podman` by executing:

```sh
chmod +x install.arm64.binary.patches.sh && CONTAINER_TOOL=podman ./install.arm64.binary.patches.sh
```

## the vm

By far the largest program:

```sh
cat <<'EOF' > install.vm.sh
#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

delete="false"
recreate="false"

for var in "$@"
do
  [ "${var}" == "--delete" ] && delete="true"
  [ "${var}" == "--recreate" ] && recreate="true"
done

if [ "${delete}" == "true" ]; then
  echo >&2 "Deleting the workload machine..."
  rm -rfv "${DATA_DIR}/workload-files"
  multipass delete "${WORKLOAD_VM_NAME}"
  multipass purge
  exit 0
fi

if [ "${recreate}" == "true" ]; then
  echo >&2 "Recreating the workload machine..."
  rm -rfv "${DATA_DIR}/workload-files"
  multipass delete "${WORKLOAD_VM_NAME}"
  multipass purge
fi

set +e; multipass launch -c 2 -m 1G -d 4G -n "${WORKLOAD_VM_NAME}" "${RUN_OS}"; set -e
WORKLOAD_IP=$(multipass info "${WORKLOAD_VM_NAME}" --format yaml | yq '.""${WORKLOAD_VM_NAME}""[] | select(.state == "Running") | .ipv4[0]' -r)
echo "Workload IP address is: ${WORKLOAD_IP}"

# From the istio/proxyv2 image, copy arm64 binaries as istio-sidecar.deb is amd54 only:
arm64_patch_dir="${base}/.tmp/istio-proxy-${ISTIO_VERSION}-arm64"
if [ -f "${arm64_patch_dir}/usr/local/bin/envoy" ]; then
  echo >&2 "Deploying arm64 binaries..."
  multipass transfer --parents "${arm64_patch_dir}/usr/local/bin/envoy" "${WORKLOAD_VM_NAME}":./usr/local/bin/envoy
  multipass transfer --parents "${arm64_patch_dir}/usr/local/bin/pilot-agent" "${WORKLOAD_VM_NAME}":./usr/local/bin/pilot-agent
else
  echo >&2 "Deploying without arm64 binaries."
fi

# istio-sidecar.deb:
multipass transfer --parents "${DATA_DIR}/istio-sidecar/usr/local/bin/istio-start.sh" "${WORKLOAD_VM_NAME}":./usr/local/bin/istio-start.sh
multipass transfer --parents "${DATA_DIR}/istio-sidecar/lib/systemd/system/istio.service" "${WORKLOAD_VM_NAME}":./lib/systemd/system/istio.service 
multipass transfer --parents "${DATA_DIR}/istio-sidecar/var/lib/istio/envoy/envoy_bootstrap_tmpl.json" "${WORKLOAD_VM_NAME}":./var/lib/istio/envoy/envoy_bootstrap_tmpl.json
multipass transfer --parents "${DATA_DIR}/istio-sidecar/var/lib/istio/envoy/sidecar.env" "${WORKLOAD_VM_NAME}":./var/lib/istio/envoy/sidecar.env

# Configure the istio-sidecar.deb-like environment:
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /etc/certs
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /etc/istio/config
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/lib/istio/config
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/lib/istio/envoy
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/lib/istio/proxy
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/log/istio
multipass exec "${WORKLOAD_VM_NAME}" -- sudo touch /var/lib/istio/config/mesh
if [ -f "${arm64_patch_dir}/usr/local/bin/envoy" ]; then
  multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v usr/local/bin/* /usr/local/bin/'
  multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v lib/systemd/system/istio.service /lib/systemd/system/istio.service'
  multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v var/lib/istio/envoy/* /var/lib/istio/envoy/'
  # From postinst:
  set +e; multipass exec "${WORKLOAD_VM_NAME}" -- sudo groupadd --system istio-proxy; set -e
  set +e; multipass exec "${WORKLOAD_VM_NAME}" -- sudo useradd --system --gid istio-proxy --home-dir /var/lib/istio istio-proxy; set -e
else
  multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'curl -LO https://storage.googleapis.com/istio-release/releases/'${ISTIO_VERSION}'/deb/istio-sidecar.deb && sudo dpkg -i istio-sidecar.deb'
fi

# Deploy workload files:
multipass transfer --parents "${base}/.data/workload-files/root-cert.pem" "${WORKLOAD_VM_NAME}":./workload/root-cert.pem
multipass transfer --parents "${base}/.data/workload-files/cluster.env" "${WORKLOAD_VM_NAME}":./workload/cluster.env
multipass transfer --parents "${base}/.data/workload-files/istio-token" "${WORKLOAD_VM_NAME}":./workload/istio-token
multipass transfer --parents "${base}/.data/workload-files/mesh.yaml" "${WORKLOAD_VM_NAME}":./workload/mesh

cat > ${base}/.data/workload-files/all-hosts <<EOP
# Your system has configured 'manage_etc_hosts' as True.
# As a result, if you wish for changes to this file to persist
# then you will need to either
# a.) make changes to the master file in /etc/cloud/templates/hosts.debian.tmpl
# b.) change or remove the value of 'manage_etc_hosts' in
#     /etc/cloud/cloud.cfg or cloud-config from user-data
#
127.0.1.1 ${WORKLOAD_VM_NAME}
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

$(cat ${base}/.data/workload-files/hosts)
EOP

multipass transfer --parents "${base}/.data/workload-files/all-hosts" "${WORKLOAD_VM_NAME}":./workload/hosts
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/hosts /etc/hosts'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/root-cert.pem /etc/certs/root-cert.pem'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/cluster.env /var/lib/istio/envoy/cluster.env'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo mkdir -p /var/run/secrets/tokens
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/istio-token /var/run/secrets/tokens/istio-token'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo bash -c 'mv -v workload/mesh /etc/istio/config/mesh'
multipass exec "${WORKLOAD_VM_NAME}" -- sudo chmod o+rx /usr/local/bin/{envoy,pilot-agent}
multipass exec "${WORKLOAD_VM_NAME}" -- sudo chmod 2755 /usr/local/bin/{envoy,pilot-agent}

multipass exec "${WORKLOAD_VM_NAME}" -- sudo chown -R istio-proxy.istio-proxy \
  /etc/certs \
  /etc/istio \
  /var/run/secrets \
  /var/lib/istio/envoy \
  /var/lib/istio/config \
  /var/log/istio \
  /var/lib/istio/config/mesh \
  /var/lib/istio/proxy
EOF
chmod +x install.vm.sh && ./install.vm.sh
```

Let's break it down:

- Start the `vm-istio-etxernal-workload` VM.
- Fetch its IP address, the workload IP.
- Honor any possible `arm64` binary patches.
- Transfer files extracted from the _deb_ package to their respective locations on in the VM.
- Transfer workload files to the VM into their respective destinations.
- Execute relevant _deb_ `postinst` script steps, if necessary.

### validate the vm

Get the shell on the VM:

```sh
multipass exec vm-istio-external-workload -- bash
```

On the VM `ubuntu@vm-istio-etxernal-workload:~$`:

```sh
cd /
sudo istio-start.sh
```

```
2023-11-01T01:27:02.836001Z	info	Running command: iptables -t nat -D PREROUTING -p tcp -j ISTIO_INBOUND
2023-11-01T01:27:02.837879Z	info	Running command: iptables -t mangle -D PREROUTING -p tcp -j ISTIO_INBOUND
2023-11-01T01:27:02.839355Z	info	Running command: iptables -t nat -D OUTPUT -p tcp -j ISTIO_OUTPUT
...
2023-11-01T01:27:04.000569Z	error	citadelclient	Failed to load key pair open etc/certs/cert-chain.pem: no such file or directory
2023-11-01T01:27:04.004712Z	info	cache	generated new workload certificate	latency=118.57166ms ttl=23h59m58.995289161s
2023-11-01T01:27:04.004744Z	info	cache	Root cert has changed, start rotating root cert
2023-11-01T01:27:04.004759Z	info	ads	XDS: Incremental Pushing ConnectedEndpoints:2 Version:
2023-11-01T01:27:04.004885Z	info	cache	returned workload certificate from cache	ttl=23h59m58.995116686s
2023-11-01T01:27:04.004954Z	info	cache	returned workload trust anchor from cache	ttl=23h59m58.995045987s
2023-11-01T01:27:04.005150Z	info	cache	returned workload trust anchor from cache	ttl=23h59m58.994850182s
2023-11-01T01:27:04.006124Z	info	ads	SDS: PUSH request for node:vm-istio-etxernal-workload.vmns resources:1 size:4.0kB resource:default
2023-11-01T01:27:04.006176Z	info	ads	SDS: PUSH request for node:vm-istio-etxernal-workload.vmns resources:1 size:1.1kB resource:ROOTCA
2023-11-01T01:27:04.006204Z	info	cache	returned workload trust anchor from cache	ttl=23h59m58.99379629s
```

#### validate DNS resolution

Open another terminal:

```sh
multipass exec vm-istio-external-workload -- bash
```

On the VM `ubuntu@vm-istio-etxernal-workload:~$`:

```sh
dig istiod.istio-system.svc
```

```
; <<>> DiG 9.18.12-0ubuntu0.22.04.3-Ubuntu <<>> istiod.istio-system.svc
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 27953
;; flags: qr aa rd; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
;; WARNING: recursion requested but not available

;; QUESTION SECTION:
;istiod.istio-system.svc.	IN	A

;; ANSWER SECTION:
istiod.istio-system.svc. 30	IN	A	10.43.26.124

;; Query time: 0 msec
;; SERVER: 127.0.0.53#53(127.0.0.53) (UDP)
;; WHEN: Wed Nov 01 02:31:59 CET 2023
;; MSG SIZE  rcvd: 80
```

The IP address should be equal to the cluster IP:

```sh
kubectl get service istiod -n istio-system
```

```
NAME     TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)                                 AGE
istiod   ClusterIP   10.43.26.124   <none>        15010/TCP,15012/TCP,443/TCP,15014/TCP   19m
```

### validating communication

Deploy a sample application allowing us to validate the connection from the VM to the mesh.

#### create and configure the namespace

```sh
kubectl create namespace sample
kubectl label namespace sample istio-injection=enabled
```

#### on `amd64` host

```sh
kubectl apply -n sample -f https://raw.githubusercontent.com/istio/istio/release-1.19/samples/helloworld/helloworld.yaml
```
#### on `arm64` host

```sh
curl --silent https://raw.githubusercontent.com/istio/istio/release-1.19/samples/helloworld/helloworld.yaml \
  | sed -E 's!istio/examples!radekg/examples!g' \
  | kubectl apply -n sample -f -
```

Again, both example images published by Istio do not exist for the _linux/arm64_ architecture, I build them from my own _Dockerfile_ for _linux/arm64_. [The source code is here](https://github.com/radekg/istio-vms/tree/version-1/istio-examples).

#### hello world pods are running

```sh
kubectl get pods -n sample -w
```

```
NAME                            READY   STATUS            RESTARTS   AGE
helloworld-v1-cff64bf8c-z5nq5   0/2     PodInitializing   0          8s
helloworld-v2-9fdc9f56f-tbmk8   0/2     PodInitializing   0          8s
helloworld-v1-cff64bf8c-z5nq5   1/2     Running           0          20s
helloworld-v2-9fdc9f56f-tbmk8   1/2     Running           0          21s
helloworld-v1-cff64bf8c-z5nq5   2/2     Running           0          21s
helloworld-v2-9fdc9f56f-tbmk8   2/2     Running           0          22s
```

#### checking vm to mesh connectivity

In a shell on a VM `ubuntu@vm-istio-etxernal-workload`:

```sh
curl -v helloworld.sample.svc:5000/hello
```

```
*   Trying 10.43.109.101:5000...
* Connected to helloworld.sample.svc (10.43.109.101) port 5000 (#0)
> GET /hello HTTP/1.1
> Host: helloworld.sample.svc:5000
> User-Agent: curl/7.81.0
> Accept: */*
>
* Mark bundle as not supporting multiuse
< HTTP/1.1 200 OK
< server: envoy
< date: Wed, 01 Nov 2023 01:59:55 GMT
< content-type: text/html; charset=utf-8
< content-length: 59
< x-envoy-upstream-service-time: 88
<
Hello version: v2, instance: helloworld-v2-9fdc9f56f-tbmk8
* Connection #0 to host helloworld.sample.svc left intact
```

## routing mesh traffic to the vm

Create a service pointing at the workload group:

```sh
cat <<'EOF' > install.route.to-vm.sh
#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

kubectl apply -n vmns -f - <<EOP
apiVersion: v1
kind: Service
metadata:
  labels:
    app: external-app
  name: external-app
spec:
  ports:
  - name: http
    port: 8000
    protocol: TCP
    targetPort: 8000
  selector:
    app: external-app
EOP
EOF
chmod +x install.route.to-vm.sh && ./install.route.to-vm.sh
```

Find the workload entry, this exists only when `pilot-agent` is running in the VM.

### workload entry is unhealthy

```sh
kubectl get workloadentry -n vmns
```

```
NAME                                    AGE     ADDRESS
external-app-192.168.64.64-vm-network   2m33s   192.168.64.64
```

Check its status, it will be unhealthy:

```sh
kubectl get workloadentry external-app-192.168.64.64-vm-network -n vmns -o yaml | yq '.status'
```

```yaml
conditions:
  - lastProbeTime: "2023-11-01T21:04:50.343243250Z"
    lastTransitionTime: "2023-11-01T21:04:50.343245959Z"
    message: 'Get "http://localhost:8000/": dial tcp 127.0.0.6:0->127.0.0.1:8000:
      connect: connection refused'
    status: "False"
    type: Healthy
```

### fix it by starting the workload

The reason why it is unhealthy is because the service on the VM isn't running. Start a simple HTTP server to fix this, on the VM `ubuntu@vm-istio-etxernal-workload`:

```sh
python3 -m http.server
```

```
Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...
127.0.0.6 - - [01/Nov/2023 22:44:25] "GET / HTTP/1.1" 200 -
127.0.0.6 - - [01/Nov/2023 22:44:30] "GET / HTTP/1.1" 200 -
127.0.0.6 - - [01/Nov/2023 22:44:35] "GET / HTTP/1.1" 200 -
...
```

Almost immediately we see requests arriving. This is the health check. Istio sidecar on the VM logged:

```
2023-11-01T21:04:50.337302Z	info	healthcheck	failure threshold hit, marking as unhealthy: Get "http://localhost:8000/": dial tcp 127.0.0.6:0->127.0.0.1:8000: connect: connection refused
2023-11-01T21:32:12.943221Z	info	xdsproxy	connected to upstream XDS server: istiod.istio-system.svc:15012
2023-11-01T21:44:25.343463Z	info	healthcheck	success threshold hit, marking as healthy
```

The status of the workload entry has changed:

```sh
kubectl get workloadentry external-app-192.168.64.64-vm-network -n vmns -o yaml | yq '.status'
```

```yaml
conditions:
  - lastProbeTime: "2023-11-01T21:44:25.339260737Z"
    lastTransitionTime: "2023-11-01T21:44:25.339264070Z"
    status: "True"
    type: Healthy
```

### verify connectivity with `curl`

Finally, run an actual command to verify:

```sh
kubectl run vm-response-test -n sample --image=curlimages/curl:8.4.0 --rm -i --tty -- sh
```

```
If you don't see a command prompt, try pressing enter.
~ $
```

**Pay attention** to the **namespace** used in the last command above. The `curl` pod must be launched in an _Istio-enabled_ namespace, and _sample_ already existed.

Execute the following command in that terminal:

```sh
curl -v http://external-app.vmns.svc:8000/
```

```
*   Trying 10.43.122.27:8000...
* Connected to external-app.vmns.svc (10.43.122.27) port 8000
> GET / HTTP/1.1
> Host: external-app.vmns.svc:8000
> User-Agent: curl/8.4.0
> Accept: */*
>
< HTTP/1.1 200 OK
< server: envoy
< date: Wed, 01 Nov 2023 22:10:20 GMT
< content-type: text/html; charset=utf-8
< content-length: 768
< x-envoy-upstream-service-time: 7
<
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>Directory listing for /</title>
</head>
<body>
<h1>Directory listing for /</h1>
<hr>
<ul>
<li><a href=".bash_history">.bash_history</a></li>
<li><a href=".bash_logout">.bash_logout</a></li>
<li><a href=".bashrc">.bashrc</a></li>
<li><a href=".cache/">.cache/</a></li>
<li><a href=".profile">.profile</a></li>
<li><a href=".ssh/">.ssh/</a></li>
<li><a href=".sudo_as_admin_successful">.sudo_as_admin_successful</a></li>
<li><a href="lib/">lib/</a></li>
<li><a href="usr/">usr/</a></li>
<li><a href="var/">var/</a></li>
<li><a href="workload/">workload/</a></li>
</ul>
<hr>
</body>
</html>
* Connection #0 to host external-app.vmns.svc left intact
```

## enable strict tls

```sh
cat <<'EOF' > install.strict.tls.sh
#!/bin/bash

set -eu

base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${base}/run.env"

kubectl apply -f - <<EOP
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOP
EOF
chmod +x install.strict.tls.sh && ./install.strict.tls.sh
```

## network policies

### caveat: cannot select a workload entry in a network policy

Because a network policy selects pods using `.spec.podSelector`, and we have no pods, we have a workload entry:


```sh
kubectl apply -n vmns -f - <<EOF
---
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: deny-all
spec:
  podSelector:
    matchLabels:
      app: external-app
  ingress: []
EOF
```

```sh
kubectl run vm-response-test -n sample --image=curlimages/curl:8.4.0 --rm -i --tty -- sh
```

in that shell:

```sh
curl -v http://external-app.vmns.svc:8000/
```

```
*   Trying 10.43.122.27:8000...
* Connected to external-app.vmns.svc (10.43.122.27) port 8000
> GET / HTTP/1.1
> Host: external-app.vmns.svc:8000
> User-Agent: curl/8.4.0
> Accept: */*
>
< HTTP/1.1 200 OK
< server: envoy
...
```

**Cosider future work**: is this working when using Istio CNI?

### guarding the vm from the source of traffic namespace

```sh
kubectl apply -n sample -f - <<EOF
---
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: deny-egress-tovmns
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchExpressions:
        - key: namespace
          operator: NotIn
          values: ["vmns"]
EOF
```

```sh
kubectl run vm-response-test -n sample --image=curlimages/curl:8.4.0 --rm -i --tty -- sh
```

in that shell:

```sh
curl http://external-app.vmns.svc:8000/
```

```
upstream connect error or disconnect/reset before headers. retried and the latest reset reason: remote connection failure, transport failure reason: delayed connect error: 111~ $ ^C
~ $ exit
Session ended, resume using 'kubectl attach vm-response-test -c vm-response-test -i -t' command when the pod is running
pod "vm-response-test" deleted
```

```sh
kubectl delete networkpolicy deny-egress-tovmns -n sample
```

```sh
kubectl run vm-response-test -n sample --image=curlimages/curl:8.4.0 --rm -i --tty -- sh
```

in that shell:

```sh
curl http://external-app.vmns.svc:8000/
```

```
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>Directory listing for /</title>
</head>
<body>
<h1>Directory listing for /</h1>
<hr>
<ul>
<li><a href=".bash_history">.bash_history</a></li>
<li><a href=".bash_logout">.bash_logout</a></li>
<li><a href=".bashrc">.bashrc</a></li>
<li><a href=".cache/">.cache/</a></li>
<li><a href=".profile">.profile</a></li>
<li><a href=".ssh/">.ssh/</a></li>
<li><a href=".sudo_as_admin_successful">.sudo_as_admin_successful</a></li>
<li><a href="lib/">lib/</a></li>
<li><a href="usr/">usr/</a></li>
<li><a href="var/">var/</a></li>
<li><a href="workload/">workload/</a></li>
</ul>
<hr>
</body>
</html>
```

### network boundary for network policies

Current situation:

- Egress from source to the VM can be blocked only on a namespace level.
- On the VM side, network policies aren't capable selecting workload entries. These only select pods using `.spec.podSelector`.

The natural network boundary is the namespace and explicit deny of egress to the namespace with the VM.

## Summary

Success, a pod in the mesh can communicate to the VM via the service, VM is in the mesh and can communicate back to the mesh. Istio VM workloads are easy way to automate VM-mesh onboarding.
