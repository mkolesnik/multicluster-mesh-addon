#!/usr/bin/env bash
# Runs the customer-facing multi-cluster mesh demo.
#
# The default platform is OpenShift.
# Use PLATFORM=kind for the local Sail environment prepared by `make demo-dev-env`.

set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

PLATFORM="${PLATFORM:-openshift}"
DEMO_KUBECONFIG="${DEMO_KUBECONFIG:-}"
DEMO_DRY_RUN="${DEMO_DRY_RUN:-}"
read -r -a SPOKE_CLUSTERS <<< "${SPOKE_CLUSTERS}"
((${#SPOKE_CLUSTERS[@]} == 3)) || fail "SPOKE_CLUSTERS must contain three cluster names"

MESH_NAMESPACE=mesh-system
CLUSTER_SET=mesh-cluster-set
CM_NAME=ACM
OPERATOR_NAME=OSSM
ISTIO_VERSION="${ISTIO_VERSION:-1.30.4}"
BOOKINFO_REF="${BOOKINFO_REF:-release-${ISTIO_VERSION%.*}}"
DEMO_TIMEOUT=5m
DEMO_COMMAND_PAUSE=${DEMO_COMMAND_PAUSE:-3}
TYPEWRITER_DELAY=${TYPEWRITER_DELAY:-0.03}
HELM="${HELM:-helm}"
CLUSTERADM="${CLUSTERADM:-clusteradm}"
ISTIOCTL="${ISTIOCTL:-istioctl}"

export BAT_STYLE=plain
export BAT_PAGING=never
export BAT_THEME="Catppuccin Frappe"

# Use `bat` instead of `cat` to print YAMLs, to get syntax highlights.
cat() {
    yq -C . "$1" | bat
}
export -f cat

# Expecting a KUBECONFIG style variable with path/to/hub.config:path/to/spoke1.config:...
[[ -n "${DEMO_KUBECONFIG}" ]] || fail "DEMO_KUBECONFIG must contain hub and three spoke kubeconfig paths"
IFS=: read -r -a kubeconfig_paths <<< "${DEMO_KUBECONFIG}"

((${#kubeconfig_paths[@]} == 4)) || fail "DEMO_KUBECONFIG must contain four colon-separated paths"
for index in "${!kubeconfig_paths[@]}"; do
    kubeconfig="${kubeconfig_paths[${index}]}"
    [[ -f "${kubeconfig}" ]] || fail "DEMO_KUBECONFIG file not found: ${kubeconfig}"
    [[ -r "${kubeconfig}" ]] || fail "DEMO_KUBECONFIG file is not readable: ${kubeconfig}"
done

# The kubeconfig expected order is hub, then the spokes in matching order to SPOKE_CLUSTERS.
declare -A KUBECONFIGS=([hub]="${kubeconfig_paths[0]}")
for index in "${!SPOKE_CLUSTERS[@]}"; do
    KUBECONFIGS["${SPOKE_CLUSTERS[${index}]}"]="${kubeconfig_paths[$((index + 1))]}"
done

case "${PLATFORM}" in
    openshift)
        KUBECTL=oc
        MESH_NAME=openshift-mesh
        MESH_SAMPLE=samples/openshift.yaml
        ;;
    kind)
        KUBECTL=kubectl
        CM_NAME=OCM
        OPERATOR_NAME=Sail
        MESH_NAME=basic-mesh
        MESH_SAMPLE=samples/basic.yaml
        ;;
    *)
        fail "PLATFORM must be openshift or kind"
        ;;
esac

for tool in "${KUBECTL}" clear envsubst bat yq "${HELM}" "${CLUSTERADM}" "${ISTIOCTL}"; do
    command -v "${tool}" >/dev/null 2>&1 || fail "required command not found: ${tool}"
done

if [[ -n "${DEMO_DRY_RUN}" ]]; then
    TYPEWRITER_DELAY=0
    DEMO_COMMAND_PAUSE=0
fi

typewriter() {
    local text="$*"
    local index

    printf '\033[33m$\033[0m '
    sleep 0.2

    for ((index = 0; index < ${#text}; index++)); do
        printf '%s' "${text:index:1}"
        sleep "${TYPEWRITER_DELAY}"
    done
}

demo_comment_fmt() {
    typewriter $'\033[2;39m# '"$1"$'\033[0m'
}

demo_comment() {
    local line
    local -a lines=()

    # Use arguments for inline comments and stdin for heredoc comments.
    if (($# > 0)); then
        mapfile -t lines <<< "$*"
    else
        mapfile -t lines
    fi

    for line in "${lines[@]}"; do
        demo_comment_fmt "${line}"$'\n'
    done
}

demo_title() {
    demo_comment <<EOF
$1
${1//?/=}
EOF
}

demo_logo() {
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        TYPEWRITER_DELAY=0.005 demo_comment $'\033[1;36m'"${line}"
    done
}

demo_run() {
    local command="$*"
    typewriter $'\033[93m'"${command}"$'\033[0m\n'

    [[ -z "${DEMO_DRY_RUN}" ]] || return 0
    if bash -o pipefail -c "${command}"; then
        sleep "${DEMO_COMMAND_PAUSE}"
    else
        return "$?"
    fi
}

demo_wait() {
    [[ -z "${DEMO_DRY_RUN}" ]] || return 0
    TYPEWRITER_DELAY=0 demo_comment_fmt "<Press any key to continue>"

    # Any pressed character will release and continue
    read -r -n 1 -s
    printf '\n'
    demo_comment ""
}

run_kubectl() {
    # $1 is the cluster key; the remaining arguments are passed to $KUBECTL.
    demo_run "${KUBECTL}" --kubeconfig "${KUBECONFIGS[$1]}" "${@:2}"
}

run_kubectl_apply() {
    # $1 is the cluster, $2 is the manifest, and later arguments are apply options.
    run_kubectl "$1" apply "${@:3}" -f "$2"
    demo_run cat "$2"
}

run_kubectl_apply_envsubst() {
    # $1 is the cluster, $2 is the manifest, and later arguments are env var assignments.
    demo_run "${@:3} envsubst < $2 | ${KUBECTL} --kubeconfig ${KUBECONFIGS[$1]} apply -f -"
    demo_run "${@:3} envsubst < $2 | yq -C . | bat"
}

run_clusteradm() {
    demo_run "${CLUSTERADM}" --kubeconfig "${KUBECONFIGS[hub]}" "$@"
}

run_helm() {
    demo_run "${HELM}" --kubeconfig "${KUBECONFIGS[hub]}" "$@"
}

configure_istio_spoke() {
    if [[ "${PLATFORM}" == "openshift" ]]; then
        demo_comment "Create the istio-cni namespace and install Istio CNI on $1."
        run_kubectl_apply "$1" hack/demo/istiocni-namespace.yaml
        run_kubectl_apply "$1" samples/istio/istiocni.yaml
        demo_wait
    fi
    demo_comment "Create the Istio control plane on $1 with the matching multi-cluster settings."
    run_kubectl_apply_envsubst "$1" samples/istio/istio.yaml "MESH_NAME=${MESH_NAME} CLUSTER_NAME=$1 NETWORK=$2"
    demo_wait
    demo_comment "Create the east-west Gateway for forwarding traffic between the networks."
    run_kubectl_apply_envsubst "$1" samples/istio/eastwest-gateway.yaml "NETWORK=$2"
}

wait_for_istio_spoke() {
    demo_comment "Wait for istiod to become available on $1."
    run_kubectl "$1" wait --for=create --for=condition=Available deployment/istiod \
        -n istio-system --timeout="${DEMO_TIMEOUT}"
    demo_comment "Wait for the east-west Gateway to receive a LoadBalancer address."
    run_kubectl "$1" wait --for=create \
        --for=jsonpath='{.status.loadBalancer.ingress}' service/eastwestgateway-istio \
        -n istio-system --timeout="${DEMO_TIMEOUT}"
}

run_istioctl_remote_clusters() {
    demo_run "${ISTIOCTL}" remote-clusters --kubeconfig "${KUBECONFIGS[$1]}"
}

deploy_bookinfo_version() {
    local cluster="$1"
    local version="$2"
    local bookinfo_base
    local bookinfo_manifest
    local workload_selector
    local -a ready_workloads

    if [[ "${PLATFORM}" == "openshift" ]]; then
        bookinfo_base="https://raw.githubusercontent.com/openshift-service-mesh/istio/${BOOKINFO_REF}"
    else
        bookinfo_base="https://raw.githubusercontent.com/istio/istio/${BOOKINFO_REF}"
    fi
    bookinfo_manifest="${bookinfo_base}/samples/bookinfo/platform/kube/bookinfo.yaml"

    case "${version}" in
        v1)
            workload_selector="'app in (details,ratings,reviews,productpage),version=v1'"
            ready_workloads=(deployment/productpage-v1 deployment/details-v1 deployment/reviews-v1 deployment/ratings-v1)
            ;;
        v2)
            workload_selector="'app=reviews,version=v2'"
            ready_workloads=(deployment/reviews-v2)
            ;;
        v3)
            workload_selector="'app=reviews,version=v3'"
            ready_workloads=(deployment/reviews-v3)
            ;;
        *)
            fail "unsupported Bookinfo version: ${version}"
            ;;
    esac

    demo_comment "Create the Istio-injected Bookinfo namespace on ${cluster}."
    run_kubectl_apply "${cluster}" hack/demo/bookinfo-namespace.yaml
    demo_comment "Apply the Bookinfo Services and ServiceAccounts on ${cluster}."
    run_kubectl "${cluster}" apply -n bookinfo -f "${bookinfo_manifest}" -l service
    run_kubectl "${cluster}" apply -n bookinfo -f "${bookinfo_manifest}" -l account
    demo_comment "Deploy the Bookinfo workloads needed on ${cluster}."
    run_kubectl "${cluster}" apply -n bookinfo -f "${bookinfo_manifest}" -l "${workload_selector}"
    demo_comment "Mark reviews-${version} with ${cluster}'s name so each response shows where it came from."
    run_kubectl "${cluster}" set env "deployment/reviews-${version}" "CLUSTER_NAME=${cluster}" -n bookinfo
    demo_comment "Wait for the Bookinfo workloads to finish deploying on ${cluster}."
    run_kubectl "${cluster}" wait --for=condition=Available "${ready_workloads[@]}" \
        -n bookinfo --timeout="${DEMO_TIMEOUT}"
}

show_bookinfo_traffic() {
    local request
    local traffic_loop

    request="${KUBECTL} --kubeconfig ${KUBECONFIGS["${SPOKE_CLUSTERS[1]}"]} exec deployment/curl -n bookinfo -c curl -- curl -sS http://reviews:9080/reviews/0"
    traffic_loop="for i in {1..$1}; do ${request} | yq -r '.podname + \" \" + .clustername'; done"
    demo_comment <<EOF
Call the shared reviews service a few times.
Each line shows the pod and cluster that answered.
EOF
    demo_run "${traffic_loop}"
}

open_url() {
    [[ -z "${DEMO_DRY_RUN}" ]] || return 0
    local url="$1"
    local opener=""

    if command -v xdg-open >/dev/null 2>&1; then
        opener=xdg-open
    elif command -v open >/dev/null 2>&1; then
        opener=open
    fi

    if [[ -z "${opener}" ]]; then
        demo_comment "No opener program found, open ${url} manually."
    elif ! "${opener}" "${url}" 2>/dev/null; then
        demo_comment "Could not open URL: ${url}"
    fi
}

show_bookinfo_productpage() {
    local productpage_url

    if [[ "${PLATFORM}" == "openshift" ]]; then
        local route_host="<route-host>"
        demo_comment "Expose the Bookinfo productpage through an OpenShift Route on ${SPOKE_CLUSTERS[0]}."
        run_kubectl "${SPOKE_CLUSTERS[0]}" create route edge productpage \
            --service=productpage --port=9080 -n bookinfo 2>/dev/null || true
        if [[ -z "${DEMO_DRY_RUN}" ]]; then
            route_host=$("${KUBECTL}" --kubeconfig "${KUBECONFIGS["${SPOKE_CLUSTERS[0]}"]}" get route productpage -n bookinfo -o jsonpath='{.spec.host}' 2>/dev/null) || true
            if [[ -z "${route_host}" ]]; then
                demo_comment "Could not retrieve the Route host. Check the Route manually using: \`${KUBECTL} get route productpage -n bookinfo\`"
                return
            fi
        fi

        productpage_url="https://${route_host}/productpage"
    else
        demo_comment "Port-forward the Bookinfo productpage from ${SPOKE_CLUSTERS[0]} so you can view it in a browser."
        demo_run "${KUBECTL} --kubeconfig ${KUBECONFIGS["${SPOKE_CLUSTERS[0]}"]} port-forward svc/productpage 9080:9080 -n bookinfo &"
        productpage_url="http://localhost:9080/productpage"
    fi

    demo_comment <<EOF
Productpage URL: ${productpage_url}
Refresh a few times to see reviews with no stars (v1), black stars (v2), or red stars (v3).
EOF
    open_url "${productpage_url}"
}

clear
demo_logo <<EOF

███╗   ███╗███████╗███████╗██╗  ██╗    █████╗ ██████╗ ██████╗  █████╗ ███╗   ██╗
████╗ ████║██╔════╝██╔════╝██║  ██║   ██╔══██╗██╔══██╗██╔══██╗██╔══██╗████╗  ██║
██╔████╔██║█████╗  ███████╗███████║   ███████║██║  ██║██║  ██║██║  ██║██╔██╗ ██║
██║╚██╔╝██║██╔══╝  ╚════██║██╔══██║   ██╔══██║██║  ██║██║  ██║██║  ██║██║╚██╗██║
██║ ╚═╝ ██║███████╗███████║██║  ██║   ██║  ██║██████╔╝██████╔╝╚█████╔╝██║ ╚████║
╚═╝     ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝   ╚═╝  ╚═╝╚═════╝ ╚═════╝  ╚════╝ ╚═╝  ╚═══╝

                          Multicluster Mesh Addon - DP1
                              ── ${CM_NAME} x ${OPERATOR_NAME} Demo ──

EOF
demo_comment <<EOF
Welcome to the multi-cluster service mesh add-on demo.
The add-on helps set up a multi-cluster service mesh across an ${CM_NAME} cluster set.
It bootstraps the ${OPERATOR_NAME} operator, establishes trust, and enables endpoint discovery.

We'll start with two clusters, then add a third to show how to scale out.
The add-on will bootstrap the necessary ${OPERATOR_NAME} components automatically.
We'll also deploy Istio as the user, who is currently responsible for this part of the deployment.

We'll use the Bookinfo sample app to show traffic distributing across the clusters.
EOF
[ "$PLATFORM" == "openshift" ] && demo_comment "The demo will also install and launch the OSSM console plugin."
demo_comment <<EOF

The demo pauses at key points so you can read the results before continuing.
EOF
demo_wait

demo_title "Step 1: Preparing ${CM_NAME}"
demo_comment <<EOF
${CM_NAME} is already installed, and is the core platform which we'll be utilizing.
The addon uses ${CM_NAME} to accomplish all the necessary bootstrapping.

Check that all three clusters appear in the hub's inventory and are available.
EOF
run_kubectl hub get managedclusters
if [[ "${PLATFORM}" == "openshift" ]]; then
    demo_comment "Enable the \`ManifestWorkReplicaSet\` feature gate so the add-on can distribute resources through ${CM_NAME}."
    mwrs_patch='{"spec":{"workConfiguration":{"featureGates":[{"feature":"ManifestWorkReplicaSet","mode":"Enable"}]}}}'
    run_kubectl hub patch clustermanager cluster-manager --type=merge -p "'${mwrs_patch}'"
fi
demo_comment "Check whether the spokes already have the Gateway API resources used by the east-west gateway."
for cluster in "${SPOKE_CLUSTERS[@]}"; do
    demo_comment "Check if the Gateway API CRDs are available on ${cluster}."
    if ! DEMO_COMMAND_PAUSE=0 run_kubectl "${cluster}" get crd \
        gateways.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io -o name; then
        demo_comment "Install the Gateway API CRDs on ${cluster}."
        DEMO_COMMAND_PAUSE=0 run_kubectl "${cluster}" apply --server-side \
            -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
    fi
done
demo_wait

demo_title "Step 2: Installing the mesh add-on"
demo_comment <<EOF
The add-on is not available in an ${CM_NAME} or OLM catalog yet.
Install its controller directly from the project's Helm repository.

Add the add-on's Helm repository.
EOF
run_helm repo add --force-update multicluster-mesh-addon \
    https://stolostron.github.io/multicluster-mesh-addon
run_helm repo update
demo_comment "Install the add-on from the Helm chart."
addon_args=(upgrade --install multicluster-mesh-addon multicluster-mesh-addon/multicluster-mesh-addon \
    --namespace multicluster-mesh-system --create-namespace --wait --timeout 5m)
if [[ "${PLATFORM}" == "kind" ]]; then
    addon_args+=(--set platform=kind --set image.pullPolicy=IfNotPresent)
fi
run_helm "${addon_args[@]}"
demo_wait

demo_title "Step 3: Preparing certificates"
demo_comment <<EOF
The add-on uses cert-manager to distribute a shared trust bundle rooted in a provided CA.
For the demo, we'll create a small self-signed trust chain and use that.
In production, use the issuer and trust policy required by your organization.

EOF
if [[ "${PLATFORM}" == "openshift" ]]; then
    demo_comment "Check if cert-manager is deployed on the hub."
    if run_kubectl hub get deployment cert-manager -n cert-manager &>/dev/null; then
        demo_comment "cert-manager is already deployed on the hub, skipping the installation."
    else
        demo_comment "Install the Red Hat cert-manager Operator from the redhat-operators catalog."
        run_kubectl_apply hub hack/demo/cert-manager-operator.yaml
    fi
    demo_comment "Wait for cert-manager to become available on the hub."
    run_kubectl hub wait --for=create --for=condition=Available deployment/cert-manager deployment/cert-manager-cainjector \
        deployment/cert-manager-webhook -n cert-manager --timeout=5m
fi
demo_comment "Create the mesh namespace and apply the self-signed root trust chain."
run_kubectl_apply hub hack/demo/mesh-namespace.yaml
run_kubectl_apply hub samples/cert-manager-issuer.yaml -n "${MESH_NAMESPACE}"
demo_comment "Wait for the bootstrap issuer, root certificate, and CA-backed issuer to become ready."
run_kubectl hub wait --for=condition=Ready issuer/mesh-selfsigned-issuer certificate/mesh-root-ca \
    issuer/mesh-root-ca -n "${MESH_NAMESPACE}" --timeout=5m
demo_wait

demo_title "Step 4: Preparing the exclusive ClusterSet"
demo_comment <<EOF
Each MultiClusterMesh targets an exclusive ManagedClusterSet.
The add-on deploys its components to every cluster in that set.
Create the exclusive ClusterSet and add the first two clusters.
EOF
run_clusteradm create clusterset "${CLUSTER_SET}"
run_clusteradm clusterset set "${CLUSTER_SET}" --clusters "${SPOKE_CLUSTERS[0]},${SPOKE_CLUSTERS[1]}"
demo_comment <<EOF
The add-on currently supports the multi-network multi-primary topology, so that's what we'll deploy.
Label the first two clusters with their Istio network identities.
EOF
run_kubectl hub label managedcluster "${SPOKE_CLUSTERS[0]}" topology.istio.io/network=network-a --overwrite
run_kubectl hub label managedcluster "${SPOKE_CLUSTERS[1]}" topology.istio.io/network=network-b --overwrite
demo_wait

demo_title "Step 5: Creating the MultiClusterMesh"
demo_comment <<EOF
Create a MultiClusterMesh resource on the hub.
The add-on watches this resource and bootstraps the ${OPERATOR_NAME} operator and the necessary resources on the selected clusters.
EOF
run_kubectl_apply hub "${MESH_SAMPLE}" -n "${MESH_NAMESPACE}"
demo_comment <<EOF
Let's check in on the mesh while the selected clusters are being prepared.
We should see that the operator is being installed on each cluster.
OEF
demo_run "${KUBECTL} --kubeconfig ${KUBECONFIGS[hub]} get multiclustermesh/${MESH_NAME} -n ${MESH_NAMESPACE} -o yaml | yq -C .status | bat"
demo_comment <<EOF
Wait for the add-on to report that the mesh is ready.
That confirms the ${OPERATOR_NAME} operator is ready on the selected clusters.
EOF
demo_wait
run_kubectl hub wait --for=condition=Ready=True "multiclustermesh/${MESH_NAME}" \
    -n "${MESH_NAMESPACE}" --timeout="${DEMO_TIMEOUT}"
run_kubectl hub get "multiclustermesh/${MESH_NAME}" -n "${MESH_NAMESPACE}"
demo_wait

demo_title "Step 6: Deploying Istio and checking connectivity"
demo_comment <<EOF
The add-on has finished preparing the clusters.
Now we'll install the Istio components on each one, just like the user would.

EOF
if [[ "${PLATFORM}" == "openshift" ]]; then
    demo_comment "The east-west gateway needs a LoadBalancer address. On bare-metal clusters, make sure MetalLB or an equivalent provider is set up."
fi
demo_title "Step 6.1: Deploying Istio on ${SPOKE_CLUSTERS[0]}"
configure_istio_spoke "${SPOKE_CLUSTERS[0]}" network-a
demo_wait

demo_title "Step 6.2: Deploying Istio on ${SPOKE_CLUSTERS[1]}"
configure_istio_spoke "${SPOKE_CLUSTERS[1]}" network-b
demo_wait

demo_title "Step 6.3: Waiting for Istio to come up"
demo_comment <<EOF
Istio is deploying on both clusters.
Let's give it a couple of moments to come up.
EOF
wait_for_istio_spoke "${SPOKE_CLUSTERS[0]}"
wait_for_istio_spoke "${SPOKE_CLUSTERS[1]}"
demo_comment <<EOF

Both control planes are up.
Let's check that the clusters can see each other before deploying Bookinfo.
EOF
run_istioctl_remote_clusters "${SPOKE_CLUSTERS[0]}"
run_istioctl_remote_clusters "${SPOKE_CLUSTERS[1]}"
demo_wait

demo_title "Step 7: Deploying Bookinfo and testing connectivity"
demo_comment <<EOF
Both clusters can see each other in the mesh.
Now let's check that traffic can cross between them using Bookinfo.

EOF
demo_title "Step 7.1: Deploy Bookinfo v1 on ${SPOKE_CLUSTERS[0]}"
demo_comment <<EOF
Deploy the first reviews version on ${SPOKE_CLUSTERS[0]}.
This cluster runs the full Bookinfo app with reviews running v1 of the app.
The other clusters will run only the reviews service.
EOF
deploy_bookinfo_version "${SPOKE_CLUSTERS[0]}" v1
demo_wait

demo_title "Step 7.2: Deploy Bookinfo v2 on ${SPOKE_CLUSTERS[1]}"
demo_comment <<EOF
Deploy a different reviews version on ${SPOKE_CLUSTERS[1]}.
Istio will make both versions available through the shared service.
EOF
deploy_bookinfo_version "${SPOKE_CLUSTERS[1]}" v2
demo_wait

demo_title "Step 7.3: Check cross-cluster traffic"
demo_comment <<EOF
Start a small curl pod in ${SPOKE_CLUSTERS[1]} and send a few requests to reviews.
We should see responses from both clusters.
EOF
run_kubectl_apply "${SPOKE_CLUSTERS[1]}" test/e2e/testdata/curl.yaml -n bookinfo
run_kubectl "${SPOKE_CLUSTERS[1]}" wait --for=condition=Available deployment/curl -n bookinfo --timeout="${DEMO_TIMEOUT}"
demo_wait
show_bookinfo_traffic 8
demo_wait

demo_title "Step 8: Scaling out to another cluster"
demo_comment <<EOF
Now that we've seen requests cross between the first two clusters, let's add a third one.
We'll add ${SPOKE_CLUSTERS[2]} to the ClusterSet and install Istio there.

EOF

demo_title "Step 8.1: Add ${SPOKE_CLUSTERS[2]} to the mesh"
demo_comment <<EOF
The add-on will bootstrap ${SPOKE_CLUSTERS[2]} automatically once it joins the exclusive ClusterSet.
First, let's give it its Istio network identity.
EOF
run_kubectl hub label managedcluster "${SPOKE_CLUSTERS[2]}" topology.istio.io/network=network-c --overwrite
demo_comment "Next, add the cluster to the exclusive ClusterSet."
run_clusteradm clusterset set "${CLUSTER_SET}" \
    --clusters "${SPOKE_CLUSTERS[0]},${SPOKE_CLUSTERS[1]},${SPOKE_CLUSTERS[2]}"
demo_wait
demo_comment "Check the MultiClusterMesh status while ${SPOKE_CLUSTERS[2]} joins the mesh."
demo_run "${KUBECTL} --kubeconfig ${KUBECONFIGS[hub]} get multiclustermesh/${MESH_NAME} -n ${MESH_NAMESPACE} -o yaml | yq -C .status | bat"
demo_wait
demo_comment "Let's wait for the add-on to finish bootstrapping ${SPOKE_CLUSTERS[2]}."
run_kubectl hub wait --for=condition=Ready=True "multiclustermesh/${MESH_NAME}" \
    -n "${MESH_NAMESPACE}" --timeout="${DEMO_TIMEOUT}"
run_kubectl hub get "multiclustermesh/${MESH_NAME}" -n "${MESH_NAMESPACE}"
demo_wait

demo_title "Step 8.2: Configure Istio on ${SPOKE_CLUSTERS[2]}"
demo_comment "Now that the cluster is bootstrapped we'll install Istio, just like the user would."
configure_istio_spoke "${SPOKE_CLUSTERS[2]}" network-c
wait_for_istio_spoke "${SPOKE_CLUSTERS[2]}"
demo_comment "Check that ${SPOKE_CLUSTERS[2]} can see the rest of the mesh."
run_istioctl_remote_clusters "${SPOKE_CLUSTERS[2]}"
demo_wait

demo_title "Step 8.3: Deploy Bookinfo v3 and verify traffic"
demo_comment <<EOF
Istio is up and running on ${SPOKE_CLUSTERS[2]} and connected to the rest of the mesh.
We'll deploy another version of Bookinfo on it, and see that traffic gets sent to all 3 clusters.

Deploy the third reviews version on the new cluster.
EOF
deploy_bookinfo_version "${SPOKE_CLUSTERS[2]}" v3
demo_wait
demo_comment "Using the same curl client, we should now also see reviews v3 from ${SPOKE_CLUSTERS[2]}."
show_bookinfo_traffic 12
demo_comment "We'll check out the Bookinfo product page to see traffic being distributed across the mesh."
show_bookinfo_productpage
demo_wait

if [[ "${PLATFORM}" == "openshift" ]]; then
    demo_title "Step 9: Setting up the OSSM Console"
    demo_comment <<EOF
Let's add the OSSM Console plugin to the ACM hub so we can explore the mesh in the console.

First, install the OSSM Console operator.
EOF
    run_kubectl_apply hub hack/demo/kiali-ossm-subscription.yaml
    demo_comment "Wait for the console operator to install."
    run_kubectl hub wait --for=create --for=condition=Available deployment/kiali-operator \
        -n openshift-operators --timeout=10m
    demo_comment "Create the OSSMConsole resource that enables the Fleet Service Mesh perspective."
    run_kubectl_apply hub hack/demo/ossm-console.yaml
    demo_comment "Wait for the console plugin to be created."
    run_kubectl hub wait --for=create consoleplugin/ossmconsole --timeout=10m
    run_kubectl hub get ossmconsole -A
    run_kubectl hub get consoleplugin ossmconsole
    demo_comment <<EOF
Open the console and navigate to the Fleet Service Mesh perspective.
On the Meshes page, select ${MESH_NAME} to see the cluster status and control plane details.
EOF

    console_url="https://<console-route-host>"
    if [[ -z "${DEMO_DRY_RUN}" ]]; then
        console_url="$("${KUBECTL}" --kubeconfig "${KUBECONFIGS[hub]}" \
            get route console -n openshift-console -o 'jsonpath=https://{.spec.host}')"
    fi
    demo_comment "Console URL: ${console_url}"
    open_url "${console_url}"
fi

demo_comment <<EOF
That's it for the demo.
Feel free to keep exploring the mesh.

EOF
if [[ "${PLATFORM}" == "kind" ]]; then
    demo_comment "When you're ready to clean up, run: make demo-dev-clean"
else
    demo_comment <<EOF
When you're ready to clean up:
- Delete multiclustermesh/${MESH_NAME} from ${MESH_NAMESPACE} on the hub and wait for cleanup.
- Delete the ${MESH_NAMESPACE} namespace on the hub and the bookinfo namespace on each spoke.
- Restore the clusters' original ClusterSet membership and network labels, then delete ${CLUSTER_SET}.
The add-on and operators will stay installed.
EOF
fi
