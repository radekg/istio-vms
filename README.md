I am going to connect a VM to the Istio mesh running in the Kubernetes cluster.

I will need:

- A VM.
- A Kubernetes cluster.
- Containers.

This is not a job for _KinD_ because I need a VM. So, it's _Multipass_. I am going to run:

- A _k3s_ cluster on _Multipass_.
- A VM on _Multipass_, same network as the _k3s_ cluster.

After setting up the _k3s_ cluster, I follow the steps from Istio documentation: [Virtual Machine Installation](https://istio.io/latest/docs/setup/install/virtual-machine/).

## how to use this document

Either follow for the hard way, or consult `./bin/reference.sh` for a more condensed walk-through.

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

The environment is configured through the `run.env` file.

## setting up the _k3s_ cluster

This program starts the cluster:

```sh
./install.k3s.sh
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

- `ISTIO_VERSION`: Istio version, default `1.19.3`
- `ISTIO_ARCH`: one of `< osx-arm64`, `osx-amd64`, `linux-armv7`, `linux-arm64`, `linux-amd64 >`

```sh
./install.istioctl.sh
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

Install Istio:

```sh
./install.istio.sh
```

Verify:

```sh
kubectl get services -n "${ISTIO_NAMESPACE}"
```

```
NAME            TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)                                 AGE
istiod-1-19-3   ClusterIP   10.43.255.139   <none>        15010/TCP,15012/TCP,443/TCP,15014/TCP   39s
```

```sh
istioctl tag list
```

```
TAG     REVISION NAMESPACES
default 1-19-3
```

## install _eastwest_ gateway

```sh
./install.eastwest.gateway.sh
```

## create the vm

Before a workload group can be created, we need to have the VM because, in this case, the IP address is needed for the workload group. To create the VM:

```sh
./install.vm.create.sh
```

## the workload group

It's time to turn the attention to the VM. Start by creating a workload:

```sh
./install.workload.sh
```

Verify:

```sh
cat .data/workload-files/hosts
```

output similar to:

```
192.168.64.60 istiod-1-19-3.istio-system.svc
```

If there are no hosts here, your _eastwest_ gateway is most likely not working correctly.

### workload group ca_addr

The _CA\_ADDR_ environment variable exported in the _cluster.env_ file points by default to the Istio TLS port, the _15012_.

```sh
./install.workload.sh --no-fix-ca
cat .data/workload-files/cluster.env | grep CA_ADDR
```

```
CA_ADDR='istiod-1-19-3.istio-system.svc:15012'
```

The service name is correct but the port isn't. I hoped that the tool would pick up the port from the ingress gateway service but the help for _istioctl x workload entry configure_ says:

```
      --ingressService string   Name of the Service to be used as the ingress gateway, in the format <service>.<namespace>. If no namespace is provided, the default istio-system namespace will be used. (default "istio-eastwestgateway")
```

Since that's our gateway name, it obviously doesn't detect ports. By default _install.workload.sh_ program fixes that by simply appending a fixed _CA\_ADDR_ value to the end of the _cluster.env_.

```sh
cat .data/workload-files/cluster.env | grep CA_ADDR
```

```
CA_ADDR='istiod-1-19-3.istio-system.svc:15012'
CA_ADDR=istiod-'1-19-3.istio-system.svc:15013'
```

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

## bootstrap the vm

**TODO:**: this should be using `cloud-init`, really...

```sh
./install.vm.bootstrap.sh
```

### validate the vm

Get the shell on the VM:

```sh
multipass exec vm-istio-external-workload -- bash
```

On the VM `ubuntu@vm-istio-external-workload:~$`, regardless of the fact that we set the _CA\_ADDR_, we still have to use the correct value for the _PILOT\_ADDRESS_.

```sh
cd / && sudo PILOT_ADDRESS=istiod-1-19-3.istio-system.svc:15013 istio-start.sh
# cd / && sudo PILOT_ADDRESS=istiod-${ISTIO_REVISION}.${ISTIO_NAMESPACE}.svc:${EWG_PORT_TLS_ISTIOD} istio-start.sh
```

However, this is also already dealt with in _install.workload.sh_. We can start the program with:

```sh
cd / && sudo istio-start.sh
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
2023-11-01T01:27:04.006124Z	info	ads	SDS: PUSH request for node:vm-istio-external-workload.vmns resources:1 size:4.0kB resource:default
2023-11-01T01:27:04.006176Z	info	ads	SDS: PUSH request for node:vm-istio-external-workload.vmns resources:1 size:1.1kB resource:ROOTCA
2023-11-01T01:27:04.006204Z	info	cache	returned workload trust anchor from cache	ttl=23h59m58.99379629s
```

**If your istio-start.sh command doesn't produce any output** after iptables output:

```
-A OUTPUT -p udp --dport 53 -d 127.0.0.53/32 -j REDIRECT --to-port 15053
COMMIT
2023-11-09T11:21:47.136622Z	info	Running command: iptables-restore --noflush
(hangs here)
```

`CTRL+C`, exec to the VM, and rerun last command again.

#### validate DNS resolution

Open another terminal:

```sh
multipass exec vm-istio-external-workload -- bash
```

On the VM `ubuntu@vm-istio-external-workload:~$`:

```sh
dig istiod-1-19-3.istio-system.svc
# dig istiod-${ISTIO_REVISION}.${ISTIO_NAMESPACE}.svc
```

```
; <<>> DiG 9.18.12-0ubuntu0.22.04.3-Ubuntu <<>> istiod-1-19-3.istio-system.svc
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 27953
;; flags: qr aa rd; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
;; WARNING: recursion requested but not available

;; QUESTION SECTION:
;istiod-1-19-3.istio-system.svc.	IN	A

;; ANSWER SECTION:
istiod-1-19-3.istio-system.svc. 30	IN	A	10.43.26.124

;; Query time: 0 msec
;; SERVER: 127.0.0.53#53(127.0.0.53) (UDP)
;; WHEN: Wed Nov 01 02:31:59 CET 2023
;; MSG SIZE  rcvd: 80
```

The IP address should be equal to the cluster IP:

```sh
kubectl get service "istiod-${ISTIO_REVISION}" -n "${ISTIO_NAMESPACE}"
```

```
NAME            TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)                                 AGE
istiod-1-19-3   ClusterIP   10.43.26.124   <none>        15010/TCP,15012/TCP,443/TCP,15014/TCP   19m
```

### validating communication

Deploy a sample application allowing us to validate the connection from the VM to the mesh.

#### create and configure the namespace

```sh
kubectl create namespace sample
kubectl label namespace sample "istio.io/rev=${ISTIO_REVISION}"
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

In a shell on a VM `ubuntu@vm-istio-external-workload`:

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
./install.route.to.vm.sh
```

Find the workload entry, this exists only when `pilot-agent` is running in the VM.

### workload entry is unhealthy

```sh
kubectl get workloadentry -n "${VM_NAMESPACE}"
```

```
NAME                                    AGE     ADDRESS
external-app-192.168.64.64-vm-network   2m33s   192.168.64.64
```

Check its status, it will be unhealthy:

```sh
kubectl get workloadentry external-app-192.168.64.64-vm-network -n "${VM_NAMESPACE}" -o yaml | yq '.status'
```

```yaml
conditions:
  - lastProbeTime: "2023-11-01T21:04:50.343243250Z"
    lastTransitionTime: "2023-11-01T21:04:50.343245959Z"
    message: 'Get "http://localhost:8000/": dial tcp 127.0.0.6:0->127.0.0.1:8000: connect: connection refused'
    status: "False"
    type: Healthy
```

### fix it by starting the workload

The reason why it is unhealthy is because the service on the VM isn't running. Start a simple HTTP server to fix this, on the VM `ubuntu@vm-istio-external-workload`:

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
2023-11-01T21:32:12.943221Z	info	xdsproxy	connected to upstream XDS server: istiod-1-19-3.istio-system.svc:15012
2023-11-01T21:44:25.343463Z	info	healthcheck	success threshold hit, marking as healthy
```

The status of the workload entry has changed:

```sh
kubectl get workloadentry external-app-192.168.64.64-vm-network -n "${VM_NAMESPACE}" -o yaml | yq '.status'
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
# Use the VM_NAMESPACE from run.env
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
kubectl apply -f - <<EOP
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: ${ISTIO_NAMESPACE}
spec:
  mtls:
    mode: STRICT
EOP
```

## network policies

### caveat: cannot select a workload entry in a network policy

Because a network policy selects pods using `.spec.podSelector`, and we have no pods, we have a workload entry:


```sh
kubectl apply -f - <<EOF
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: deny-all
  namespace: ${VM_NAMESPACE}
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
# Use the VM_NAMESPACE from run.env
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
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: deny-egress-tovm
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
          values: ["${VM_NAMESPACE}"]
EOF
```

```sh
kubectl run vm-response-test -n sample --image=curlimages/curl:8.4.0 --rm -i --tty -- sh
```

in that shell:

```sh
curl http://external-app.vmns.svc:8000/
# Use the VM_NAMESPACE from run.env
```

```
upstream connect error or disconnect/reset before headers. retried and the latest reset reason: remote connection failure, transport failure reason: delayed connect error: 111~ $ ^C
~ $ exit
Session ended, resume using 'kubectl attach vm-response-test -c vm-response-test -i -t' command when the pod is running
pod "vm-response-test" deleted
```

```sh
kubectl delete networkpolicy deny-egress-tovm -n sample
```

```sh
kubectl run vm-response-test -n sample --image=curlimages/curl:8.4.0 --rm -i --tty -- sh
```

in that shell:

```sh
curl http://external-app.vmns.svc:8000/
# Use the VM_NAMESPACE from run.env
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
