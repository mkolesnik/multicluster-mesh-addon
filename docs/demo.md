# OpenShift ACM and OSSM demo

This walkthrough tells a simple Bookinfo story across three OpenShift clusters.
ACM provides the hub, the mesh add-on prepares the selected clusters, and you create the Istio and application resources just as a customer would.
We start with two clusters, show reviews traffic crossing them, and then add a third cluster to show scale-out.

The commands are written out so you can follow along by hand, and the script pauses between sections.
This guide follows the OpenShift path in `hack/demo.sh`.
The script also supports a local kind/Sail run with `make demo-sail`; that path uses a port-forward for Bookinfo and skips the OSSM Console step.
ManifestWorks and other implementation details happen behind the scenes; the focus here is the mesh and its traffic.

The final section sets up the OSSM Console plugin on the ACM hub and opens the Fleet Service Mesh view of the same MultiClusterMesh.

This is a demo flow, not a production installation.
Use the certificate issuer, OSSM version, network configuration, and application deployment process required by your organization in production.

## Before you start

The following must already exist:

- An OpenShift cluster that is an ACM hub.
- Three ACM managed clusters that are joined and available.
- The ACM managed-serviceaccount add-on installed and available.
- OLM on all three managed clusters.
- Permission to enable the ManifestWorkReplicaSet feature gate on the ACM hub if it is not already enabled.
- kubectl, helm, clusteradm, istioctl, envsubst, yq, and bat on the machine running the commands.
- A kubeconfig context for the hub and each spoke.
- Permission to install cluster-scoped operators and the add-on.

The third cluster is registered and available, but it is intentionally not in the mesh ClusterSet at the beginning.
Do not install the OSSM operator subscription manually on the spokes for this demo.
The add-on bootstraps it after the MultiClusterMesh is created.

The commands below use kubectl.
On OpenShift, oc can be substituted for kubectl.

## Set the demo names

Replace the contexts and cluster names with the values from your ACM inventory.
Keep the mesh namespace, mesh name, and ClusterSet names shown below unless you also edit the sample manifests.

~~~bash
export HUB_CONTEXT=acm-hub
export SPOKE_A_CONTEXT=cluster1
export SPOKE_B_CONTEXT=cluster2
export SPOKE_C_CONTEXT=cluster3

export CLUSTER_A=cluster1
export CLUSTER_B=cluster2
export CLUSTER_C=cluster3

export MESH_NAMESPACE=mesh-system
export MESH_NAME=openshift-mesh
export CLUSTER_SET=mesh-cluster-set
~~~

Confirm that the contexts point to the intended clusters before continuing:

~~~bash
kubectl --context "$HUB_CONTEXT" cluster-info
kubectl --context "$SPOKE_A_CONTEXT" cluster-info
kubectl --context "$SPOKE_B_CONTEXT" cluster-info
kubectl --context "$SPOKE_C_CONTEXT" cluster-info
~~~

## 1. Prepare ACM prerequisites

ACM is already installed for this demo.
This step checks the ACM inventory, makes sure ManifestWorkReplicaSet is enabled, and prepares Gateway API for the east-west gateways.

~~~bash
kubectl --context "$HUB_CONTEXT" get managedclusters
kubectl --context "$HUB_CONTEXT" wait \
  --for=condition=ManagedClusterConditionAvailable=True \
  "managedcluster/$CLUSTER_A" \
  "managedcluster/$CLUSTER_B" \
  "managedcluster/$CLUSTER_C" \
  --timeout=5m
~~~

ManifestWorkReplicaSet lets the add-on distribute resources through ACM.
Enable it on the hub:

~~~bash
kubectl --context "$HUB_CONTEXT" patch clustermanager cluster-manager \
  --type=merge \
  -p '{"spec":{"workConfiguration":{"featureGates":[{"feature":"ManifestWorkReplicaSet","mode":"Enable"}]}}}'
~~~

Gateway API provides the resource used by the east-west gateway.
OpenShift may already provide these CRDs; the local Sail demo installs them here when they are missing.
For production, use the Gateway API version approved for your OpenShift and OSSM releases.

~~~bash
for CONTEXT in "$SPOKE_A_CONTEXT" "$SPOKE_B_CONTEXT" "$SPOKE_C_CONTEXT"; do
  kubectl --context "$CONTEXT" get crd \
    gateways.gateway.networking.k8s.io \
    gatewayclasses.gateway.networking.k8s.io \
    --ignore-not-found -o name
done

for CONTEXT in "$SPOKE_A_CONTEXT" "$SPOKE_B_CONTEXT" "$SPOKE_C_CONTEXT"; do
  if ! kubectl --context "$CONTEXT" get crd \
    gateways.gateway.networking.k8s.io \
    gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
    kubectl --context "$CONTEXT" apply --server-side \
      -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
  fi
done
~~~

The ACM managed-serviceaccount add-on and OLM are prerequisites for this walkthrough.
They are used behind the scenes by the mesh add-on and should already be healthy.

## 2. Install the add-on on the ACM hub

The add-on is not installed from an ACM or OLM catalog in this demo.
Install it explicitly from its Helm repository.

~~~bash
helm repo add multicluster-mesh-addon \
  https://stolostron.github.io/multicluster-mesh-addon
helm repo update
helm upgrade --install multicluster-mesh-addon \
  multicluster-mesh-addon/multicluster-mesh-addon \
  --kube-context "$HUB_CONTEXT" \
  --namespace multicluster-mesh-system \
  --create-namespace \
  --wait \
  --timeout 5m
~~~

Confirm that the controller is ready:

~~~bash
kubectl --context "$HUB_CONTEXT" wait \
  --for=condition=Available \
  deployment/multicluster-mesh-controller \
  -n multicluster-mesh-system \
  --timeout=5m
~~~

## 3. Prepare cert-manager and the demo trust root

The script checks whether cert-manager is already deployed on the hub.
If it is missing, install the Red Hat cert-manager Operator from the `redhat-operators` catalog on the `stable-v1` channel:

~~~bash
if ! kubectl --context "$HUB_CONTEXT" get deployment cert-manager \
  -n cert-manager >/dev/null 2>&1; then
  kubectl --context "$HUB_CONTEXT" apply \
    -f hack/demo/cert-manager-operator.yaml
fi

kubectl --context "$HUB_CONTEXT" wait \
  --for=create \
  --for=condition=Available \
  deployment/cert-manager \
  deployment/cert-manager-cainjector \
  deployment/cert-manager-webhook \
  -n cert-manager \
  --timeout=5m
~~~

Do not install the Red Hat and community cert-manager Operators together.

Create the namespace and a simple self-signed trust chain using the [cert-manager sample](../samples/cert-manager-issuer.yaml):

~~~bash
kubectl --context "$HUB_CONTEXT" apply -f hack/demo/mesh-namespace.yaml
kubectl --context "$HUB_CONTEXT" apply \
  -n "$MESH_NAMESPACE" \
  -f samples/cert-manager-issuer.yaml

kubectl --context "$HUB_CONTEXT" wait \
  --for=condition=Ready \
  issuer/mesh-selfsigned-issuer \
  certificate/mesh-root-ca \
  issuer/mesh-root-ca \
  -n "$MESH_NAMESPACE" \
  --timeout=5m
~~~

This root is self-signed only to keep the demo self-contained.
Customers should provide the issuer and trust policy required by their environment.

## 4. Prepare the exclusive ClusterSet

Create the ClusterSet and add the first two spokes.
The default clusteradm create clusterset behavior creates an exclusive ClusterSet.
Record existing ClusterSet membership and network labels if you need to restore them after the demo.

~~~bash
clusteradm --context "$HUB_CONTEXT" create clusterset "$CLUSTER_SET"
clusteradm --context "$HUB_CONTEXT" clusterset set "$CLUSTER_SET" \
  --clusters "$CLUSTER_A,$CLUSTER_B"
~~~

Give the first two clusters stable network identities for the Istio configuration that follows:

~~~bash
kubectl --context "$HUB_CONTEXT" label managedcluster "$CLUSTER_A" \
  topology.istio.io/network=network-a --overwrite
kubectl --context "$HUB_CONTEXT" label managedcluster "$CLUSTER_B" \
  topology.istio.io/network=network-b --overwrite
~~~

## 5. Create the MultiClusterMesh resource

The [OpenShift sample](../samples/openshift.yaml) targets OSSM from the Red Hat catalog.
It references the ClusterSet and issuer names used above.

~~~bash
kubectl --context "$HUB_CONTEXT" apply \
  -n "$MESH_NAMESPACE" \
  -f samples/openshift.yaml

kubectl --context "$HUB_CONTEXT" get \
  "multiclustermesh/$MESH_NAME" \
  -n "$MESH_NAMESPACE" \
  -o yaml | yq .status

kubectl --context "$HUB_CONTEXT" get \
  "multiclustermesh/$MESH_NAME" \
  -n "$MESH_NAMESPACE"

kubectl --context "$HUB_CONTEXT" wait \
  --for=condition=Ready=True \
  "multiclustermesh/$MESH_NAME" \
  -n "$MESH_NAMESPACE" \
  --timeout=5m

kubectl --context "$HUB_CONTEXT" get \
  "multiclustermesh/$MESH_NAME" \
  -n "$MESH_NAMESPACE"
~~~

The important result is status.conditions[type=Ready].status=True and an OperatorInstalled=True condition for each member cluster.
That status means the add-on has bootstrapped the OSSM operator on the selected clusters.
It does not mean that an Istio control plane or Bookinfo is running yet.

The add-on also creates trust and endpoint-discovery resources behind the scenes.
Those resources support the mesh but are not the primary demo object.

## 6. Configure Istio on the initial mesh members

The add-on does not create Istio resources.
Apply the Istio configuration on each spoke as the customer would, directly or through GitOps.

The [Istio CNI](../samples/istio/istiocni.yaml), [Istio control plane](../samples/istio/istio.yaml), and [east-west Gateway](../samples/istio/eastwest-gateway.yaml) samples use the MESH_NAME, CLUSTER_NAME, and NETWORK variables below.
The east-west gateway needs a LoadBalancer address. On bare-metal OpenShift, make sure MetalLB or an equivalent provider is set up.

### 6.1. Configure Istio on cluster1

~~~bash
export CLUSTER_NAME="$CLUSTER_A"
export NETWORK=network-a
kubectl --context "$SPOKE_A_CONTEXT" apply -f hack/demo/istiocni-namespace.yaml
kubectl --context "$SPOKE_A_CONTEXT" apply -f samples/istio/istiocni.yaml
envsubst < samples/istio/istio.yaml | \
  kubectl --context "$SPOKE_A_CONTEXT" apply -f -
envsubst < samples/istio/eastwest-gateway.yaml | \
  kubectl --context "$SPOKE_A_CONTEXT" apply -f -
~~~

### 6.2. Configure Istio on cluster2

~~~bash
export CLUSTER_NAME="$CLUSTER_B"
export NETWORK=network-b
kubectl --context "$SPOKE_B_CONTEXT" apply -f hack/demo/istiocni-namespace.yaml
kubectl --context "$SPOKE_B_CONTEXT" apply -f samples/istio/istiocni.yaml
envsubst < samples/istio/istio.yaml | \
  kubectl --context "$SPOKE_B_CONTEXT" apply -f -
envsubst < samples/istio/eastwest-gateway.yaml | \
  kubectl --context "$SPOKE_B_CONTEXT" apply -f -
~~~

### 6.3. Verify mesh connectivity

Wait for istiod and each east-west gateway Service to become available. The Gateway is programmed after the service receives a LoadBalancer address:

~~~bash
kubectl --context "$SPOKE_A_CONTEXT" wait \
  --for=create --for=condition=Available \
  deployment/istiod \
  -n istio-system --timeout=5m

kubectl --context "$SPOKE_B_CONTEXT" wait \
  --for=create --for=condition=Available \
  deployment/istiod \
  -n istio-system --timeout=5m
~~~

~~~bash
kubectl --context "$SPOKE_A_CONTEXT" wait \
  --for=create \
  --for=jsonpath='{.status.loadBalancer.ingress}' \
  service/eastwestgateway-istio \
  -n istio-system \
  --timeout=5m

kubectl --context "$SPOKE_B_CONTEXT" wait \
  --for=create \
  --for=jsonpath='{.status.loadBalancer.ingress}' \
  service/eastwestgateway-istio \
  -n istio-system \
  --timeout=5m
~~~

The two Istio control planes are now connected through the add-on's trust and endpoint-discovery setup.
Use istioctl to verify what each control plane sees:

~~~bash
istioctl remote-clusters --context "$SPOKE_A_CONTEXT"
istioctl remote-clusters --context "$SPOKE_B_CONTEXT"
~~~

## 7. Deploy Bookinfo and show cross-cluster traffic

Deploy one Bookinfo reviews version on each cluster. Keep the same service names so Istio treats the reviews workloads as one multi-cluster service.

### 7.1. Deploy Bookinfo v1 on cluster1

Set ISTIO_VERSION to the Istio version supported by the OSSM version installed by your catalog.
The demo defaults to Istio 1.30.4, which is the version supported by OSSM 3.4.2.
The Bookinfo manifest uses the matching Istio minor-release branch.
Apply the shared Services and ServiceAccounts to each cluster, then only the workloads needed there.

~~~bash
export ISTIO_VERSION=1.30.4
export BOOKINFO_REF="release-${ISTIO_VERSION%.*}"
export BOOKINFO_MANIFEST="https://raw.githubusercontent.com/openshift-service-mesh/istio/$BOOKINFO_REF/samples/bookinfo/platform/kube/bookinfo.yaml"

kubectl --context "$SPOKE_A_CONTEXT" apply \
  -f hack/demo/bookinfo-namespace.yaml

kubectl --context "$SPOKE_A_CONTEXT" apply \
  -n bookinfo \
  -f "$BOOKINFO_MANIFEST" \
  -l service
kubectl --context "$SPOKE_A_CONTEXT" apply \
  -n bookinfo \
  -f "$BOOKINFO_MANIFEST" \
  -l account
kubectl --context "$SPOKE_A_CONTEXT" apply \
  -n bookinfo \
  -f "$BOOKINFO_MANIFEST" \
  -l 'app in (details,ratings,reviews,productpage),version=v1'

kubectl --context "$SPOKE_A_CONTEXT" set env \
  deployment/reviews-v1 CLUSTER_NAME="$CLUSTER_A" -n bookinfo
kubectl --context "$SPOKE_A_CONTEXT" wait \
  --for=condition=Available \
  deployment/productpage-v1 deployment/details-v1 \
  deployment/reviews-v1 deployment/ratings-v1 \
  -n bookinfo --timeout=5m
kubectl --context "$SPOKE_A_CONTEXT" get deployment \
  -n bookinfo
~~~

### 7.2. Deploy Bookinfo v2 on cluster2

~~~bash
kubectl --context "$SPOKE_B_CONTEXT" apply \
  -f hack/demo/bookinfo-namespace.yaml
kubectl --context "$SPOKE_B_CONTEXT" apply \
  -n bookinfo \
  -f "$BOOKINFO_MANIFEST" \
  -l service
kubectl --context "$SPOKE_B_CONTEXT" apply \
  -n bookinfo \
  -f "$BOOKINFO_MANIFEST" \
  -l account
kubectl --context "$SPOKE_B_CONTEXT" apply \
  -n bookinfo \
  -f "$BOOKINFO_MANIFEST" \
  -l 'app=reviews,version=v2'
kubectl --context "$SPOKE_B_CONTEXT" set env \
  deployment/reviews-v2 CLUSTER_NAME="$CLUSTER_B" -n bookinfo
kubectl --context "$SPOKE_B_CONTEXT" wait \
  --for=condition=Available \
  deployment/reviews-v2 \
  -n bookinfo --timeout=5m
kubectl --context "$SPOKE_B_CONTEXT" get deployment \
  -n bookinfo
~~~

### 7.3. Check cross-cluster traffic

Start a small [curl client](../test/e2e/testdata/curl.yaml) in cluster2's injected Bookinfo namespace. We'll use it to call the shared reviews service and see which cluster answers:

~~~bash
kubectl --context "$SPOKE_B_CONTEXT" apply \
  -n bookinfo \
  -f test/e2e/testdata/curl.yaml
kubectl --context "$SPOKE_B_CONTEXT" wait \
  --for=condition=Available deployment/curl \
  -n bookinfo --timeout=5m
~~~

Call the reviews service eight times from that client on cluster2:

~~~bash
for i in {1..8}; do
  kubectl --context "$SPOKE_B_CONTEXT" exec deployment/curl \
    -n bookinfo -c curl -- curl -sS http://reviews:9080/reviews/0 |
    yq -r '.podname + " " + .clustername'
done
~~~

Expected output includes reviews-v1 from cluster1 and reviews-v2 from cluster2.
The pod and cluster values make the cross-cluster request visible without exposing the add-on's implementation resources.

## 8. Scale the mesh out to a third cluster

### 8.1. Add cluster3 to the mesh

Label the third cluster before adding it to the exclusive ClusterSet.
This label becomes the Istio network identity for the new control plane.

~~~bash
kubectl --context "$HUB_CONTEXT" label managedcluster "$CLUSTER_C" \
  topology.istio.io/network=network-c --overwrite
clusteradm --context "$HUB_CONTEXT" clusterset set "$CLUSTER_SET" \
  --clusters "$CLUSTER_A,$CLUSTER_B,$CLUSTER_C"
~~~

Watch the MultiClusterMesh status while the new cluster joins, then wait for it to report Ready again:

~~~bash
kubectl --context "$HUB_CONTEXT" get \
  "multiclustermesh/$MESH_NAME" \
  -n "$MESH_NAMESPACE"
kubectl --context "$HUB_CONTEXT" wait \
  --for=condition=Ready=True \
  "multiclustermesh/$MESH_NAME" \
  -n "$MESH_NAMESPACE" \
  --timeout=5m
kubectl --context "$HUB_CONTEXT" get \
  "multiclustermesh/$MESH_NAME" \
  -n "$MESH_NAMESPACE"
~~~

The add-on has bootstrapped the OSSM operator and supporting resources on cluster3.
Next, install Istio there too.

### 8.2. Configure Istio on cluster3

Use the same Istio setup as the first two clusters:

~~~bash
export CLUSTER_NAME="$CLUSTER_C"
export NETWORK=network-c
kubectl --context "$SPOKE_C_CONTEXT" apply -f hack/demo/istiocni-namespace.yaml
kubectl --context "$SPOKE_C_CONTEXT" apply -f samples/istio/istiocni.yaml
envsubst < samples/istio/istio.yaml | \
  kubectl --context "$SPOKE_C_CONTEXT" apply -f -
envsubst < samples/istio/eastwest-gateway.yaml | \
  kubectl --context "$SPOKE_C_CONTEXT" apply -f -
kubectl --context "$SPOKE_C_CONTEXT" wait \
  --for=create --for=condition=Available deployment/istiod \
  -n istio-system --timeout=5m
kubectl --context "$SPOKE_C_CONTEXT" wait \
  --for=create --for=jsonpath='{.status.loadBalancer.ingress}' \
  service/eastwestgateway-istio \
  -n istio-system --timeout=5m
~~~

Verify that all three control planes can see each other:

~~~bash
istioctl remote-clusters --context "$SPOKE_A_CONTEXT"
istioctl remote-clusters --context "$SPOKE_B_CONTEXT"
istioctl remote-clusters --context "$SPOKE_C_CONTEXT"
~~~

### 8.3. Deploy Bookinfo v3 and verify traffic

Deploy Bookinfo v3 on cluster3. Keep the same service names so the three reviews versions form one multi-cluster service:

~~~bash
kubectl --context "$SPOKE_C_CONTEXT" apply \
  -f hack/demo/bookinfo-namespace.yaml
kubectl --context "$SPOKE_C_CONTEXT" apply \
  -n bookinfo \
  -f "$BOOKINFO_MANIFEST" \
  -l service
kubectl --context "$SPOKE_C_CONTEXT" apply \
  -n bookinfo \
  -f "$BOOKINFO_MANIFEST" \
  -l account
kubectl --context "$SPOKE_C_CONTEXT" apply \
  -n bookinfo \
  -f "$BOOKINFO_MANIFEST" \
  -l 'app=reviews,version=v3'
kubectl --context "$SPOKE_C_CONTEXT" set env \
  deployment/reviews-v3 CLUSTER_NAME="$CLUSTER_C" -n bookinfo
kubectl --context "$SPOKE_C_CONTEXT" wait \
  --for=condition=Available deployment/reviews-v3 \
  -n bookinfo --timeout=5m
kubectl --context "$SPOKE_C_CONTEXT" get deployment \
  -n bookinfo
~~~

Call the reviews service 12 more times from the client on cluster2:

~~~bash
for i in {1..12}; do
  kubectl --context "$SPOKE_B_CONTEXT" exec deployment/curl \
    -n bookinfo -c curl -- curl -sS http://reviews:9080/reviews/0 |
    yq -r '.podname + " " + .clustername'
done
~~~

Expected output now includes reviews-v1, reviews-v2, and reviews-v3, showing traffic across all three mesh members.

To see the Bookinfo productpage in a browser, expose it through an OpenShift Route:

~~~bash
kubectl --context "$SPOKE_A_CONTEXT" create route edge productpage \
  --service=productpage --port=9080 -n bookinfo
kubectl --context "$SPOKE_A_CONTEXT" get route productpage \
  -n bookinfo -o jsonpath='https://{.spec.host}/productpage{"\n"}'
~~~

Open the printed URL and refresh a few times.
Reviews with no stars come from v1, black stars from v2, and red stars from v3.
The version that appears changes because Istio load-balances the reviews service across all three clusters.

## 9. Set up the OSSM Console

The OSSM Console plugin is a separate final step on the ACM hub.
Install the Kiali Operator from OperatorHub, or create the equivalent subscription explicitly:

~~~bash
kubectl --context "$HUB_CONTEXT" apply \
  -f hack/demo/kiali-ossm-subscription.yaml

kubectl --context "$HUB_CONTEXT" wait \
  --for=create --for=condition=Available \
  deployment/kiali-operator \
  -n openshift-operators \
  --timeout=10m
~~~

Create the OSSMConsole resource with Fleet Service Mesh enabled:

~~~bash
kubectl --context "$HUB_CONTEXT" apply \
  -f hack/demo/ossm-console.yaml

kubectl --context "$HUB_CONTEXT" wait \
  --for=create \
  consoleplugin/ossmconsole \
  --timeout=10m
kubectl --context "$HUB_CONTEXT" get ossmconsole -A
kubectl --context "$HUB_CONTEXT" get consoleplugin ossmconsole
~~~

Refresh the OpenShift Console on the ACM hub and navigate to the Fleet Service Mesh perspective:

1. Click the perspective switcher (top-left) and select **Fleet Service Mesh**.
2. Open the **Meshes** page. The managed mesh should appear with its ClusterSet, trust issuer, and member clusters.
3. Click the mesh name to see per-cluster operator status and control plane details.
4. Expand individual cluster entries to confirm the operator is installed and healthy on all three members.

Fleet Service Mesh is a developer preview.
It is an inventory and status view.
It does not replace Kiali and it does not create the Istio resources owned by the customer.

The hub console URL can be printed with:

~~~bash
kubectl --context "$HUB_CONTEXT" get route console \
  -n openshift-console \
  -o jsonpath='https://{.spec.host}{"\n"}'
~~~

## Cleanup

Delete the MultiClusterMesh and wait for add-on cleanup before deleting its namespace.
This also removes the control-plane namespace from each member spoke.

~~~bash
kubectl --context "$HUB_CONTEXT" delete \
  "multiclustermesh/$MESH_NAME" \
  -n "$MESH_NAMESPACE" --wait=true
kubectl --context "$HUB_CONTEXT" delete namespace "$MESH_NAMESPACE"
~~~

Remove the Bookinfo namespace from each spoke:

~~~bash
for CONTEXT in "$SPOKE_A_CONTEXT" "$SPOKE_B_CONTEXT" "$SPOKE_C_CONTEXT"; do
  kubectl --context "$CONTEXT" delete namespace bookinfo --ignore-not-found
done
~~~

Return the clusters to their original ClusterSet, remove the network labels set by the demo, and delete the demo ClusterSet.
The example below assumes the clusters belonged to `default` and had no network labels before the demo.
Restore any previous ClusterSet membership or network label values instead.

~~~bash
clusteradm --context "$HUB_CONTEXT" clusterset set default \
  --clusters "$CLUSTER_A,$CLUSTER_B,$CLUSTER_C"

for CLUSTER in "$CLUSTER_A" "$CLUSTER_B" "$CLUSTER_C"; do
  kubectl --context "$HUB_CONTEXT" label managedcluster "$CLUSTER" topology.istio.io/network-
done

kubectl --context "$HUB_CONTEXT" delete managedclusterset "$CLUSTER_SET"
~~~

These steps leave the add-on and any operators installed for the demo in place.

## References

- [User Guide](user-guide.md)
- [OpenShift cert-manager Operator installation](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift)
- [Fleet Service Mesh dev preview guide](https://github.com/kiali/openshift-servicemesh-plugin/blob/main/docs/fleet-mesh/DEV-PREVIEW-GUIDE.md)
- [Bookinfo application](https://istio.io/latest/docs/examples/bookinfo/)
