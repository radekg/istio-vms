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

- `multipass`: macOS `brew install multipass`, Linux [official instructions](https://multipass.run/docs/installing-on-linux) or follow instructions for your distribution
- `go` for `yq`
- `yq`: `YQ_VERSION=v4.35.2 go install "github.com/mikefarah/yq/v4@${YQ_VERSION}"` or follow [an official guide](https://github.com/mikefarah/yq#install)
- `docker` or `podman` if you are on an _arm64-based_ host
- `istioctl`: instructions [further in the article](#install-istioctl)

## working directory

Remain in this directory all the time:

```sh
mkdir -p ~/.project && cd ~/.project
```

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
export ISTIO_CLUSTER=test
export VM_APP="external-app"
export VM_NAMESPACE="vmns"
export SERVICE_ACCOUNT="vmsa"
export CLUSTER_NETWORK="kube-network"
export VM_NETWORK="vm-network"

# However, if there's a run.env file in pwd, use that one:
[ -f `pwd`"/run.env" ] && source `pwd`"/run.env" && >&2 echo "configured from `pwd`/run.env"
EOF
```

## setting up the _k3s_ cluster

This program starts the cluster:

```sh
cat <<'EOF' > install.k3s.sh
#!/bin/bash

multipass delete k3s-master k3s-worker-1 k3s-worker-2
multipass purge

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

**Caution:** this program will remove and recreate your _k3s_ cluster on each run!

## setting up the client

To have your _kubectl_ and and other tools use the correct kube config:

```sh
source run.env
```

## verify the cluster

```sh
kubectl get nodes -o wide
```

Something along the lines of:

```
NAME           STATUS   ROLES                  AGE     VERSION        INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
k3s-master     Ready    control-plane,master   6m41s   v1.27.6+k3s1   192.168.64.57   <none>        Ubuntu 22.04.3 LTS   5.15.0-87-generic   containerd://1.7.6-k3s1.27
k3s-worker-2   Ready    <none>                 5m44s   v1.27.6+k3s1   192.168.64.59   <none>        Ubuntu 22.04.3 LTS   5.15.0-87-generic   containerd://1.7.6-k3s1.27
k3s-worker-1   Ready    <none>                 5m52s   v1.27.6+k3s1   192.168.64.58   <none>        Ubuntu 22.04.3 LTS   5.15.0-87-generic   containerd://1.7.6-k3s1.27
```

## install istioctl

```sh
cat <<'EOF' > install.istioctl.sh
#!/bin/bash
local_bin="${HOME}/.local/test-istio-vm-multipass/bin"
mkdir -p "${local_bin}/tmp/"
export PATH="${local_bin}:/usr/local/bin:${PATH}"
export ISTIO_VERSION=${ISTIO_VERSION:-1.19.3}
export ISTIO_ARCH=${ISTIO_ARCH:-osx-arm64} # linux-amd64
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

I decompressed it and kept the following:

```sh
tree .data/istio-sidecar/
```

```
.data/istio-sidecar/
├── lib
│   └── systemd
│       └── system
│           └── istio.service
├── usr
│   └── local
│       └── bin
│           └── istio-start.sh
└── var
    └── lib
        └── istio
            └── envoy
                ├── envoy_bootstrap_tmpl.json
                └── sidecar.env

11 directories, 4 files
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

set +e; multipass launch -c 2 -m 1G -d 4G -n vm-istio-etxernal-workload "${RUN_OS}"; set -e
WORKLOAD_IP=$(multipass info vm-istio-etxernal-workload --format yaml | yq '."vm-istio-etxernal-workload"[] | select(.state == "Running") | .ipv4[0]' -r)
echo "Workload IP address is: ${WORKLOAD_IP}"

# From the istio/proxyv2 image, copy arm64 binaries as istio-sidecar.deb is amd54 only:
arm64_patch_dir="${base}/.tmp/istio-proxy-${ISTIO_VERSION}-arm64"
if [ -f "${arm64_patch_dir}/usr/local/bin/envoy" ]; then
  multipass transfer --parents "${arm64_patch_dir}/usr/local/bin/envoy" vm-istio-etxernal-workload:./usr/local/bin/envoy
  multipass transfer --parents "${arm64_patch_dir}/usr/local/bin/pilot-agent" vm-istio-etxernal-workload:./usr/local/bin/pilot-agent
fi

# istio-sidecar.deb:
multipass transfer --parents "${DATA_DIR}/istio-sidecar/usr/local/bin/istio-start.sh" vm-istio-etxernal-workload:./usr/local/bin/istio-start.sh
multipass transfer --parents "${DATA_DIR}/istio-sidecar/lib/systemd/system/istio.service" vm-istio-etxernal-workload:./lib/systemd/system/istio.service 
multipass transfer --parents "${DATA_DIR}/istio-sidecar/var/lib/istio/envoy/envoy_bootstrap_tmpl.json" vm-istio-etxernal-workload:./var/lib/istio/envoy/envoy_bootstrap_tmpl.json
multipass transfer --parents "${DATA_DIR}/istio-sidecar/var/lib/istio/envoy/sidecar.env" vm-istio-etxernal-workload:./var/lib/istio/envoy/sidecar.env

# Configure the istio-sidecar.deb-like environment:
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /etc/certs
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /etc/istio/config
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/lib/istio/config
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/lib/istio/envoy
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/lib/istio/proxy
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/log/istio
multipass exec vm-istio-etxernal-workload -- sudo touch /var/lib/istio/config/mesh
if [ -f "${arm64_patch_dir}/usr/local/bin/envoy" ]; then
  multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v usr/local/bin/* /usr/local/bin/'
  multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v lib/systemd/system/istio.service /lib/systemd/system/istio.service'
  multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v var/lib/istio/envoy/* /var/lib/istio/envoy/'
  # From postinst:
  set +e; multipass exec vm-istio-etxernal-workload -- sudo groupadd --system istio-proxy; set -e
  set +e; multipass exec vm-istio-etxernal-workload -- sudo useradd --system --gid istio-proxy --home-dir /var/lib/istio istio-proxy; set -e
else
  multipass exec vm-istio-etxernal-workload -- sudo bash -c 'curl -LO https://storage.googleapis.com/istio-release/releases/'${ISTIO_VERSION}'/deb/istio-sidecar.deb && sudo dpkg -i istio-sidecar.deb'
fi

# Deploy workload files:
multipass transfer --parents "${base}/.data/workload-files/root-cert.pem" vm-istio-etxernal-workload:./workload/root-cert.pem
multipass transfer --parents "${base}/.data/workload-files/cluster.env" vm-istio-etxernal-workload:./workload/cluster.env
multipass transfer --parents "${base}/.data/workload-files/istio-token" vm-istio-etxernal-workload:./workload/istio-token
multipass transfer --parents "${base}/.data/workload-files/mesh.yaml" vm-istio-etxernal-workload:./workload/mesh

# Good tip from the Istio in Action book (page 364).
# --------------------------------------------------
# Concatenate the contents of the hosts file contents to the systems hosts file:
# --------------------------------------------------
cat > ${base}/.data/workload-files/all-hosts <<EOP
# Your system has configured 'manage_etc_hosts' as True.
# As a result, if you wish for changes to this file to persist
# then you will need to either
# a.) make changes to the master file in /etc/cloud/templates/hosts.debian.tmpl
# b.) change or remove the value of 'manage_etc_hosts' in
#     /etc/cloud/cloud.cfg or cloud-config from user-data
#
127.0.1.1 vm-istio-etxernal-workload vm-istio-etxernal-workload
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

$(cat ${base}/.data/workload-files/hosts)
EOP

multipass transfer --parents "${base}/.data/workload-files/all-hosts" vm-istio-etxernal-workload:./workload/hosts
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/hosts /etc/hosts'

# Another good tip from the Istio in Action book (page 364).
# ----------------------------------------------------------
# Hardcode the hostname of the machine to the hosts file so that the istio-agent doesn’t interfere with its hostname resolution:
# ----------------------------------------------------------
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'echo "'${WORKLOAD_IP}' $(hostname)" >> /etc/hosts'

multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/root-cert.pem /etc/certs/root-cert.pem'
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/cluster.env /var/lib/istio/envoy/cluster.env'
multipass exec vm-istio-etxernal-workload -- sudo mkdir -p /var/run/secrets/tokens
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/istio-token /var/run/secrets/tokens/istio-token'
multipass exec vm-istio-etxernal-workload -- sudo bash -c 'mv -v workload/mesh /etc/istio/config/mesh'
multipass exec vm-istio-etxernal-workload -- sudo chmod o+rx /usr/local/bin/{envoy,pilot-agent}
multipass exec vm-istio-etxernal-workload -- sudo chmod 2755 /usr/local/bin/{envoy,pilot-agent}

multipass exec vm-istio-etxernal-workload -- sudo chown -R istio-proxy.istio-proxy \
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

**TODO**: explain why and how.

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

## Summary

Success, a pod in the mesh can communicate to the VM via the service, VM is in the mesh and can communicate back to the mesh. Istio VM workloads are easy way to automate VM-mesh onboarding.

