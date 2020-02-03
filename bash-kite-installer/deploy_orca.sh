#!/bin/bash

cd "${0%/*}" # use the script's workdir as base
# convert arguments to environment variables
source ./args_to_vars.sh "run_args.conf" $@

initVars() {

    # defaults
    TUFIN_KITE_NAMESPACE="${TUFIN_KITE_NAMESPACE:-tufin-system}"
    TUFIN_KITE_SECRETS_NAME="${TUFIN_KITE_SECRETS_NAME:-tufin-kite-secrets}"
    TUFIN_KITE_IMAGE="${TUFIN_KITE_IMAGE:-tufin/kite:production}"
    TUFIN_DNS_IMAGE="${TUFIN_DNS_IMAGE:-tufin/coredns:production}"
    TUFIN_MONITOR_IMAGE="${TUFIN_MONITOR_IMAGE:-tufin/monitor:production}"
    TUFIN_DRY_RUN="${TUFIN_DRY_RUN:-false}"
    TUFIN_INSTALL_DNS="${TUFIN_INSTALL_DNS:-true}"
    TUFIN_INSTALL_MONITOR="${TUFIN_INSTALL_MONITOR:-true}"
    TUFIN_INSTALL_SYSLOG="false"
    TUFIN_INSTALL_PUSHER="true"
    TUFIN_INSTALL_WATCHER="true"
    TUFIN_COREDNS_PORT="54"
    TUFIN_KUBEDNS_PORT="53"
    TUFIN_KUBEDNS_REVISION="${TUFIN_KUBEDNS_REVISION:-0}"
    TUFIN_SILENT_MODE="${TUFIN_SILENT_MODE:-false}"
    TUFINIO_CRT="${TUFIN_KITE_CRT}"
    TUFIN_KUBE_CLI="kubectl"

    TUFIN_ORCA_URL="${TUFIN_ORCA_URL:-https://orca.tufin.io}"
    TUFIN_GURU_URL="${TUFIN_GURU_URL:-guru.tufin.io}"
    TUFIN_REGISTRY_URL="${TUFIN_REGISTRY_URL:-registry.tufin.io}"
}

main() {

    # validate user input
    requiredVariables "TUFIN_DOMAIN" "TUFIN_PROJECT" "TUFIN_API_TOKEN"
    [[ $? != 0 ]] && return 1

    echo "Starting Orca deployment..."

    if [[ -d ".tmp" ]]; then
        rm -rf .tmp
    fi

    if [[ "$TUFIN_UNINSTALL_ORCA" == "true" ]]; then
        echo "Uninstalling Orca..."
    elif [[ "$TUFIN_DRY_RUN" == "true" ]]; then
        echo "Running Orca in dry-run mode (domain '${TUFIN_DOMAIN}' project '${TUFIN_PROJECT}')..."
    else
        echo "Installing Orca (domain '${TUFIN_DOMAIN}' project '${TUFIN_PROJECT}')..."
    fi

    mkdir .tmp
    mkdir .tmp/kite
    mkdir .tmp/dns

    promptCluster
    [[ $? != 0 ]] && return 0

    checkClusterAPIVersions
    [[ $? != 0 ]] && return 1

    echo "Checking previous versions..."
    if [[ "$TUFIN_UNINSTALL_ORCA" != "true" && $(checkPreviousVersions)$? != 0 ]]; then
        echo "It seems like Orca is already installed, Orca must be uninstalled before proceeding. Uninstall? [Y/n]"

        if [[ "$TUFIN_SILENT_MODE" == "false" ]]; then
            while [[ -z "$proceedUninstall" ]]; do
                read proceedUninstall
            done
        else
            proceedUninstall="Y"
        fi

        if [[ "$proceedUninstall" =~ [Yy] ]]; then
            TUFIN_UNINSTALL_ORCA="true"
        else
            echo "Installation stopped by user"
            return 0
        fi
    fi

    if [[ "$TUFIN_UNINSTALL_ORCA" == "true" ]]; then
        if [[ "$TUFIN_KUBEDNS_REVISION" -lt 0 ]]; then
            echo "ERROR: 'kube-dns' deployment revision number must be a number equal or greater than '0'"
            return 1
        fi

        generateGlobalConfigFile
        generateKiteConfigFiles

        if [[ "$TUFIN_DRY_RUN" == "false" ]]; then
            echo "Uninstalling Orca..."
            uninstallOrca
            rm -rf .tmp
        fi

        return 0
    fi

    # generate description files (ns, svc, secrets, deployment)
    generateGlobalConfigFile
    generateDNSConfigFiles
    generateKiteConfigFiles

    if [[ "$TUFIN_DRY_RUN" == "false" ]]; then
        deployInCluster
        local code=$?
        rm -rf .tmp
        [[ $code != 0 ]] && return 1

        echo "Orca deployment finished."
    else
        echo "Orca dry-run finished."
    fi

    return 0
}

requiredVariables() {

    while (( $# >= 1 )); do

        [[ -z "${!1}" ]] && echo "ERROR: '${1#*TUFIN_}' must be provided!" && return 1
        shift 1
    done

    return 0
}

checkClusterAPIVersions() {

    echo "Checking cluster's API versions..."
    local apiVersions="$(kubectl api-versions)"
    TUFIN_API_RBAC="false"
    TUFIN_API_ISTIO="false"
    TUFIN_API_NETWORK_POLICY="false"
    TUFIN_IS_UCP="false"
    TUFIN_IS_OPENSHIFT="false"

    if [[ "$(echo "$apiVersions" | grep -c "rbac.authorization.k8s.io")" != "0" ]]; then
        echo "'RBAC' API detected"
        TUFIN_API_RBAC="true"
    fi

    if [[ "$(echo "$apiVersions" | grep -c "networking.istio.io")" != "0" ]]; then
        echo "'ISTIO' API detected"
        TUFIN_API_ISTIO="true"
    fi

    if [[ "$(echo "$apiVersions" | grep -c "networking.k8s.io")" != "0" ]]; then
        echo "'NETWORK POLICY' API detected"
        TUFIN_API_NETWORK_POLICY="true"
    fi

    if [[ $(oc whoami >/dev/null 2>&1)$? == 0 ]]; then
        echo "OpenShift cluster detected"
        TUFIN_IS_OPENSHIFT="true"
        TUFIN_INSTALL_MONITOR="true"
        TUFIN_INSTALL_SYSLOG="true"

    read -r OC_MAJ OC_MIN OC_PATCH <<<$(oc get clusterversions -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null | sed -E -n -e 's/([0-9]+)\.([0-9]+)\.(.*)/\1 \2 \3/p')
	[[ -z ${OC_MAJ} ]] && read -r OC_MAJ OC_MIN OC_PATCH <<<$(oc version | grep openshift | sed -E -n -e 's/openshift v([0-9]+)\.([0-9]+)\.(.*)/\1 \2 \3/p')
        [[ -z ${OC_MAJ} ]] || [[ -z {OC_MIN} ]] && echo "could not detect openshift version" && return 1

        if ! [[ "${OC_MAJ}" -eq "3" ]] && ! [[ "${OC_MAJ}" -eq "4" ]]; then
            echo "Openshift version ${OC_MAJ}.${OC_MIN}.${OC_PATCH} not supported"
            return 1
        fi

        TUFIN_KUBE_CLI="oc"
        echo "OpenShift version supported: ${OC_MAJ}.${OC_MIN}.${OC_PATCH}"

    fi

    if [[ "${TUFIN_IS_OPENSHIFT}" == "false" ]]; then
        echo "Detecting DNS deployment"
        DNS_DEPLOYMENT=$(kubectl get deploy -n kube-system -l k8s-app=kube-dns -o=custom-columns=NAME:.metadata.name | tail -n1 2>/dev/null)
        [[ -z ${DNS_DEPLOYMENT} ]] && echo "could not detect DNS deployment for K8s cluster. Can not install Orca" && return 1
    fi

    # determine if in docker-ee to choose ports
    waitForResourceValue kube-system deploy "${DNS_DEPLOYMENT}" ".spec.template.spec.containers[?(@.name=='ucp-dnsmasq-nanny')].name" "ucp-dnsmasq-nanny" 1 &> /dev/null
    if [[ $? == 0 ]]; then
        echo "'UCP' detected"
        TUFIN_IS_UCP="true"
        TUFIN_COREDNS_PORT="53"
        TUFIN_KUBEDNS_PORT="54"
    fi

    if [[ "${TUFIN_IS_OPENSHIFT}" == "true" ]]; then
        KUBE_PLATFORM="OpenShift"
    elif [[ "${TUFIN_IS_UCP}" == "true" ]]; then
        KUBE_PLATFORM="DockerEE"
    else
        KUBE_PLATFORM="Unknown"
    fi
}

promptCluster() {

    local clusterContext=""
    clusterContext="$(kubectl config current-context)"

    if [[ $? != 0 ]]; then
        echo "ERROR: kubectl is not using any context. Please make sure you're connected to your cluster!"
        return 1
    fi

    echo "ATTENTION: Working with the cluster '${clusterContext}'. Continue? [Y/n]"

    if [[ "$TUFIN_SILENT_MODE" != "true" ]]; then
        while [[ -z "$proceed" ]]; do
            read proceed
        done

        if [[ "$proceed" =~ [^Yy] ]]; then
            echo "Installation stopped by user"
            return 1
        fi
    fi
}

checkPreviousVersions() {

    local ret=0

    [[ $(getResourceState ns ${TUFIN_KITE_NAMESPACE})$? == 0 ]] && ret=1
    [[ $(getResourceState secrets ${TUFIN_KITE_SECRETS_NAME})$? == 0 ]] && ret=1
    [[ $(getResourceState serviceaccount kite)$? == 0 ]] && ret=1
    [[ $(getResourceState deploy kite)$? == 0 ]] && ret=1
    if [[ "$TUFIN_API_RBAC" == "true" ]]; then
        [[ $(getResourceState clusterrolebinding kite)$? == 0 ]] && ret=1
        [[ $(getResourceState clusterrole kite-role)$? == 0 ]] && ret=1
    fi
    return $ret
}

addOrReplaceArrayItemAndFormat() {

    local arr_str="$1"
    local add_item="$2"
    local replace_item="$3"
    local ret=()

    local new_arr=("$(echo "$arr_str" | sed -e "s%\[%%" -e "s%\]%%" -e "s%${replace_item}%%g")")
    for arg in ${new_arr[@]}; do
        ret+=("\"${arg}\"")
    done

    ret+=("\"${add_item}\"")
    ret="$(echo "${ret[@]}")"
    echo "[${ret// /, }]"
}

generateGlobalConfigFile() {

    sed -e "s@#KITE_DOMAIN#@${TUFIN_DOMAIN}@g" \
    -e "s@#KITE_PROJECT#@${TUFIN_PROJECT}@g" \
    -e "s@#TUFIN_REGISTRY_URL#@${TUFIN_REGISTRY_URL}@g" \
    -e "s@#TUFIN_ORCA_URL#@${TUFIN_ORCA_URL}@g" \
    -e "s@#TUFIN_GURU_URL#@${TUFIN_GURU_URL}:443@g" \
    -e "s@#TUFIN_KITE_NAMESPACE#@${TUFIN_KITE_NAMESPACE}@g" \
    -e "s@#TUFIN_INSTALL_ISTIO#@${TUFIN_API_ISTIO}@g" \
    -e "s@#TUFIN_INSTALL_DNS#@${TUFIN_INSTALL_DNS}@g" \
    -e "s@#TUFIN_INSTALL_PUSHER#@${TUFIN_INSTALL_PUSHER}@g" \
    -e "s@#TUFIN_INSTALL_WATCHER#@${TUFIN_INSTALL_WATCHER}@g" \
    -e "s@#TUFIN_INSTALL_MONITOR#@${TUFIN_INSTALL_MONITOR}@g" \
    -e "s@#TUFIN_INSTALL_SYSLOG#@${TUFIN_INSTALL_SYSLOG}@g" \
    -e "s@#TUFIN_KUBE_NETWORK_POLICY#@${TUFIN_API_NETWORK_POLICY}@g" \
    -e "s@#KUBE_PLATFORM#@${KUBE_PLATFORM}@g" \
    deployment/orca.config.template.yaml > .tmp/orca.config.yaml
}

generateKiteConfigFiles() {

    TUFINIO_CRT="${TUFINIO_CRT:-$(fetchTufinCert 2> /dev/null)}"
    local KITE_DOCKER_REPO_USERNAME=$(echo -n "${TUFIN_DOMAIN}_${TUFIN_PROJECT}" | base64)

    # inject to namespace
    sed -e "s@#TUFIN_KITE_NAMESPACE#@${TUFIN_KITE_NAMESPACE}@g" \
    deployment/kite/kite.namespace.template.yaml > .tmp/kite/kite.namespace.yaml

    # inject to roles
    sed -e "s@#TUFIN_KITE_NAMESPACE#@${TUFIN_KITE_NAMESPACE}@g" \
    deployment/kite/kite.roles.template.yaml > .tmp/kite/kite.roles.yaml

    #inject to secrets
    sed -e "s@#TUFINIO_CRT#@${TUFINIO_CRT}@g" \
    -e "s@#DOCKER_REPO_USERNAME#@${KITE_DOCKER_REPO_USERNAME}@g" \
    -e "s@#TUFIN_KITE_SECRETS_NAME#@${TUFIN_KITE_SECRETS_NAME}@g" \
    -e "s@#GURU_API_KEY#@$(echo -n ${TUFIN_API_TOKEN} | base64)@g" \
    -e "s@#TUFIN_KITE_NAMESPACE#@${TUFIN_KITE_NAMESPACE}@g" \
    deployment/kite/kite.secret.template.yaml > .tmp/kite/kite.secret.yaml

    # inject to kite templates
    sed -e "s@#TUFIN_KITE_SECRETS_NAME#@${TUFIN_KITE_SECRETS_NAME}@g" \
    -e "s@#KITE_IMAGE#@${TUFIN_KITE_IMAGE}@g" \
    -e "s@#TUFIN_KITE_NAMESPACE#@${TUFIN_KITE_NAMESPACE}@g" \
    deployment/kite/kite.template.yaml > .tmp/kite/kite.yaml
}

generateDNSConfigFiles() {

    if [[ "$TUFIN_IS_UCP" == "true" ]]; then
        local sidecar_args="$(kubectl get deploy "${DNS_DEPLOYMENT}" -n kube-system -o jsonpath="{.spec.template.spec.containers[?(@.name=='ucp-kubedns-sidecar')].args}")"
        local dnsmasq_args="$(kubectl get deploy "${DNS_DEPLOYMENT}" -n kube-system -o jsonpath="{.spec.template.spec.containers[?(@.name=='ucp-dnsmasq-nanny')].args}")"

        sidecar_args="$(addOrReplaceArrayItemAndFormat "$sidecar_args" "--probe=dnsmasq,127.0.0.1:54,kubernetes.default.svc.cluster.local,5,A" "--probe=dnsmasq[^ ]*")"
        dnsmasq_args="$(addOrReplaceArrayItemAndFormat "$dnsmasq_args" "--port=54" "--port=[0-9]*")"

        local dnsmasq_udp_port_xpath=$(kubectl -n kube-system get deploy "${DNS_DEPLOYMENT}" -o json | jq -c 'path(.spec.template.spec.containers[] | select(.name=="ucp-dnsmasq-nanny").ports[] | select(.name=="dns").containerPort)')
        local dnsmasq_args_xpath=$(kubectl -n kube-system get deploy "${DNS_DEPLOYMENT}" -o json | jq -c 'path(.spec.template.spec.containers[] | select(.name=="ucp-dnsmasq-nanny").args)')
        local sidecar_args_xpath=$(kubectl -n kube-system get deploy "${DNS_DEPLOYMENT}" -o json | jq -c 'path(.spec.template.spec.containers[] | select(.name=="ucp-kubedns-sidecar").args)')

        sed -e "s@#TUFIN_DNSMASQ_PORTS_XPATH#@$(convertArrayToXPATH "$dnsmasq_udp_port_xpath")@g" \
        -e "s@#TUFIN_DNSMASQ_ARGS_XPATH#@$(convertArrayToXPATH "$dnsmasq_args_xpath")@g" \
        -e "s@#TUFIN_KUBEDNS_ARGS_XPATH#@$(convertArrayToXPATH "$sidecar_args_xpath")@g" \
        -e "s@#TUFIN_DNSMASQ_NANNY_ARGS#@$(echo -n "$dnsmasq_args")@g" \
        -e "s@#TUFIN_KUBEDNS_SIDECAR_ARGS#@$(echo -n "$sidecar_args")@g" \
        deployment/dns/ucp-dnsmasq-nanny.deploy_patch.template.json > .tmp/dns/ucp-dnsmasq-nanny.deploy_patch.json
    fi


    # inject to deployment
    sed -e "s@#TUFIN_COREDNS_PORT#@${TUFIN_COREDNS_PORT}@g" \
    -e "s@#TUFIN_COREDNS_IMAGE#@${TUFIN_DNS_IMAGE}@g" \
    deployment/dns/dns.deploy_patch.template.yaml > .tmp/dns/dns.deploy_patch.yaml

    # inject to configmap
    sed -e "s@#TUFIN_KITE_NAMESPACE#@${TUFIN_KITE_NAMESPACE}@g" \
    -e "s@#TUFIN_GURU_URL#@${TUFIN_GURU_URL}@g" \
    -e "s@#TUFIN_COREDNS_PORT#@${TUFIN_COREDNS_PORT}@g" \
    -e "s@#TUFIN_KUBEDNS_PORT#@${TUFIN_KUBEDNS_PORT}@g" \
    deployment/dns/coredns.config.template.yaml > .tmp/dns/coredns.config.yaml
}

convertArrayToXPATH() {

    local path="$1"

    path="${path//,/\/}"
    path="${path/[/\/}"
    path="${path/]/}"
    path="${path//\"/}"

    echo -n "$path"
}

deployInCluster() {

    echo "Verifying namespace '$TUFIN_KITE_NAMESPACE'..." && \
    [[ $(getResourceState ns ${TUFIN_KITE_NAMESPACE})$? != 0 ]] && \
    echo "Creating namespace '$TUFIN_KITE_NAMESPACE'..." && \
    createK8SResource .tmp/kite/kite.namespace.yaml

    echo "Validating namespace '$TUFIN_KITE_NAMESPACE' creation..."
    waitForResourceValue "${TUFIN_KITE_NAMESPACE}" ns "${TUFIN_KITE_NAMESPACE}" .status.phase Active

    if [[ "$?" != 0 ]]; then
        return 1
    fi

    echo "Verifying secrets '$TUFIN_KITE_SECRETS_NAME'..."
    [[ $(getResourceState secrets ${TUFIN_KITE_SECRETS_NAME})$? != 0 ]] && \
    echo "Creating secrets '$TUFIN_KITE_SECRETS_NAME'..." && \
    createK8SResource .tmp/kite/kite.secret.yaml

    if [[ "$?" != 0 ]]; then
        echo "ERROR: secrets creation '$TUFIN_KITE_SECRETS_NAME' failed."
        return 1
    fi

    echo "Verifying configmap 'orca-config'..."
    [[ $(getResourceState configmap orca-config)$? != 0 ]] && \
    echo "Creating configmap 'orca-config'..." && \
    createK8SResource .tmp/orca.config.yaml

    if [[ "$?" != 0 ]]; then
        echo "ERROR: configmap creation 'orca-config' failed."
        return 1
    fi

    if [[ "$TUFIN_API_RBAC" == "true" ]]; then
        echo "RBAC detected - creating 'kite' roles..."
        createK8SResource .tmp/kite/kite.roles.yaml

        if [[ "$?" != 0 ]]; then
            echo "ERROR: RBAC 'kite' roles creation failed."
            return 1
        fi
    fi
    if [[ "${TUFIN_IS_OPENSHIFT}" == "true" ]]; then
        echo "Creating SecurityContextConstraints for kite"
        oc adm policy add-scc-to-user hostaccess -z kite -n ${TUFIN_KITE_NAMESPACE}
        oc adm policy add-scc-to-user hostnetwork -z kite -n ${TUFIN_KITE_NAMESPACE}
        oc adm policy add-scc-to-user node-exporter -z kite -n ${TUFIN_KITE_NAMESPACE}
        oc adm policy add-scc-to-user privileged system:serviceaccount:${TUFIN_KITE_NAMESPACE}:kite
    fi

    echo "Creating Orca Policy CRD..."
    createK8SResource deployment/crd/crd.policy.yaml

    echo "Verifying agent deployment 'kite'..."
    [[ $(getResourceState deploy kite)$? != 0 ]] && \
    echo "Creating agent deployment 'kite'..." && \
    createK8SResource .tmp/kite/kite.yaml

    echo "Validating agent deployment 'kite' creation..."
    waitForResourceValue "${TUFIN_KITE_NAMESPACE}" deploy kite .status.readyReplicas 1

    if [[ "$?" != 0 ]]; then
        return 1
    fi


    sed -e "s@#TUFIN_KITE_NAMESPACE#@${TUFIN_KITE_NAMESPACE}@g" -e "s@#MONITOR_IMAGE#@${TUFIN_MONITOR_IMAGE}@g" \
     deployment/monitor/monitor.template.yaml > .tmp/monitor.yaml

    if [[ "${TUFIN_IS_OPENSHIFT}" == "true" ]]
    then
        echo "Creating policies"
        oc adm policy add-cluster-role-to-user cluster-admin -z monitor -n ${TUFIN_KITE_NAMESPACE}
        oc adm policy add-scc-to-user privileged -z monitor -n ${TUFIN_KITE_NAMESPACE}
        oc adm policy add-scc-to-user anyuid -z default -n ${TUFIN_KITE_NAMESPACE}

        echo "Installing tufin monitor"
        oc annotate namespace ${TUFIN_KITE_NAMESPACE} openshift.io/node-selector=""
        if [[ $? != 0 ]]; then
          echo "Error annotating namespace '${TUFIN_KITE_NAMESPACE}'"
          return 1
        fi

        [[ $(oc apply -f .tmp/agent.yaml >/dev/null 2>&1)$? != 0 ]] && echo "Error deploying tufin monitor" && return 1
    else
        if [[ ${TUFIN_INSTALL_MONITOR} == "true" ]]
        then
            echo "Installing tufin monitor"
            [[ $(kubectl apply -f .tmp/monitor.yaml >/dev/null 2>&1)$? != 0 ]] && echo "Error deploying tufin monitor" && return 1
        fi

        echo "${DNS_DEPLOYMENT} detected as default DNS deployment"
        echo "Saving current deployment '${DNS_DEPLOYMENT}' to local file '${DNS_DEPLOYMENT}-dns.old.yaml'..."
        kubectl get deploy ${DNS_DEPLOYMENT} -n kube-system -o yaml > ${DNS_DEPLOYMENT}.old.yaml

        if [[ "$TUFIN_API_RBAC" == "true" ]]; then
          echo "Creating '${DNS_DEPLOYMENT}' roles..."
          createK8SResource deployment/dns/roles.yaml

          if [[ "$?" != 0 ]]; then
            echo "ERROR: RBAC '${DNS_DEPLOYMENT}' roles creation failed."
            return 1
          fi
        fi

        echo "Creating 'coredns' configmap..."
        createK8SResource .tmp/dns/coredns.config.yaml
        if [[ "$?" != 0 ]]; then
            echo "ERROR: configmap creation 'coredns' failed."
            return 1
        fi

        if [[ "$TUFIN_IS_UCP" == "false" ]]; then
            echo "Patching service 'kube-dns'..."
            patchK8SResource svc kube-dns "$(cat deployment/dns/dns.service_patch.yaml)"
            echo "Validating service 'kube-dns' patched..."
            waitForResourceValue kube-system svc kube-dns ".spec.ports[?(@.name=='dns')].targetPort" "54"
            [[ "$?" != 0 ]] && return 1
        else
            echo "Patching 'UCP' containers in '${DNS_DEPLOYMENT}' deployment..."
            patchK8SResource deploy "${DNS_DEPLOYMENT}" "$(cat .tmp/dns/ucp-dnsmasq-nanny.deploy_patch.json)" kube-system json
            echo "Validating deployment '${DNS_DEPLOYMENT}' patched..."
            waitForResourceValue kube-system deploy "${DNS_DEPLOYMENT}" ".spec.template.spec.containers[?(@.name=='ucp-dnsmasq-nanny')].ports[?(@.name=='dns')].containerPort" "54"
            [[ "$?" != 0 ]] && return 1
        fi

        echo "Patching container 'coredns' in deployment '${DNS_DEPLOYMENT}'..."
        patchK8SResource deployment ${DNS_DEPLOYMENT} "$(cat .tmp/dns/dns.deploy_patch.yaml)"
        echo "Validating container 'coredns' in deployment '${DNS_DEPLOYMENT}' patched..."
        waitForResourceValue kube-system deploy ${DNS_DEPLOYMENT} ".spec.template.spec.containers[?(@.name=='tufindns')].image" "$TUFIN_DNS_IMAGE"
        if [[ "$?" != 0 ]]; then
            return 1
        fi
    fi
}

waitForResourceValue() {

    local ns="$1"
    local type="$2"
    local resource="$3"
    local jsonpath="$4"
    local waitForValue="$5"
    local retry="${6:-30}"
    local value=""

    local attempt=0

    while [[ $attempt -lt $retry ]]; do
        value="$(kubectl get "$type" "$resource" -n "$ns" -o jsonpath="{${jsonpath}}")"

        if [[ "$value" == "$waitForValue" ]]; then
            return 0
        fi

        ((attempt++))
        sleep 1
    done

    echo "ERROR: The value of the field '${jsonpath}' in '${type}/${resource}' in namespace '${ns}' is '$value' instead of '$waitForValue'."
    return 1
}

getResourceState() {

    local type="$1"
    local name="$2"
    local ns="${3:-$TUFIN_KITE_NAMESPACE}"

    kubectl get ${type} ${name} -n ${ns} &> /dev/null

    return $?
}

fetchTufinCert() {

    echo | openssl s_client -connect "${TUFIN_GURU_URL}:443" | awk '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/' | base64 | tr -d '\n'
}

uninstallOrca() {

    if [[ "${TUFIN_IS_OPENSHIFT}" == "true" ]]; then
        echo "Removing tufin monitor..."
        [[ $(oc adm policy remove-cluster-role-from-user cluster-admin -z monitor -n ${TUFIN_KITE_NAMESPACE} >/dev/null 2>&1)$? != 0 ]] && echo "Error removing policy cluster-admin"
        [[ $(oc adm policy remove-scc-from-user privileged -z monitor -n ${TUFIN_KITE_NAMESPACE} >/dev/null 2>&1)$? != 0 ]] && echo "Error remove-scc-from-user privileged"
        [[ $(oc adm policy remove-scc-from-user anyuid -z default -n ${TUFIN_KITE_NAMESPACE} >/dev/null 2>&1)$? != 0 ]] && echo "Error remove-scc-from-user anyuid"

        echo "Removing kite agent..."
        [[ $(oc adm policy remove-scc-from-user hostaccess -z kite -n ${TUFIN_KITE_NAMESPACE} >/dev/null 2>&1)$? != 0 ]] && echo "Error remove-scc-from-user kite hostaccess"
        [[ $(oc adm policy remove-scc-from-user hostnetwork -z kite -n ${TUFIN_KITE_NAMESPACE} >/dev/null 2>&1)$? != 0 ]] && echo "Error remove-scc-from-user kite hostnetwork"
        [[ $(oc adm policy remove-scc-from-user node-exporter -z kite -n ${TUFIN_KITE_NAMESPACE} >/dev/null 2>&1)$? != 0 ]] && echo "Error remove-scc-from-user kite node-exporter"
    else
        echo "Removing 'monitor' cluster role and clusterrolebinding..."
        removeK8SResource clusterrole monitor
        removeK8SResource clusterrolebinding monitor
    fi

    # remove kite
    if [[ "$TUFIN_API_RBAC" == "true" ]]; then
        echo "Removing 'kite' roles..."
        [[ $(getResourceState clusterrolebinding kite)$? == 0 ]] && removeK8SResourceFromFile .tmp/kite/kite.roles.yaml
    fi

    if [[ $(getResourceState deploy kite)$? == 0 ]]; then
        echo "Removing 'kite' deployment..."
        removeK8SResource deploy kite
    fi

    if [[ $(getResourceState secrets ${TUFIN_KITE_SECRETS_NAME})$? == 0 ]]; then
        echo "Removing '$TUFIN_KITE_SECRETS_NAME' secrets..."
        removeK8SResource secret ${TUFIN_KITE_SECRETS_NAME}
    fi

    if [[ $(getResourceState configmap orca-config)$? == 0 ]]; then
        echo "Removing 'orca-config' configmap..."
        removeK8SResource configmap orca-config
    fi

    if [[ $(getResourceState ns ${TUFIN_KITE_NAMESPACE})$? == 0 ]]; then
        echo "Removing '$TUFIN_KITE_NAMESPACE' namespace..."
        removeK8SResource ns "${TUFIN_KITE_NAMESPACE}"
    fi

    if [[ $(getResourceState deploy ${DNS_DEPLOYMENT} kube-system)$? == 0 ]]; then
        if [[ "$TUFIN_API_RBAC" == "true" ]]; then
            echo "Removing '${DNS_DEPLOYMENT}' roles..."
            removeK8SResourceFromFile deployment/dns/roles.yaml
        fi

        echo "Removing 'coredns' configmap..."
        removeK8SResource configmap tufindns kube-system

        echo "WARNING: '${DNS_DEPLOYMENT}' will be rolled back to revision number '${TUFIN_KUBEDNS_REVISION}'. Continue? [Y/n]"

        if [[ "$TUFIN_SILENT_MODE" == "false" ]]; then
            while [[ -z "$proceedRollback" ]]; do
                read proceedRollback
            done
        else
            proceedRollback="Y"
        fi

        if [[ "$proceedRollback" =~ [^Yy] ]]; then
            echo "'${DNS_DEPLOYMENT}' deployment wasn't rolled back"
        else
            echo "Rolling back '${DNS_DEPLOYMENT}' to revision number '${TUFIN_KUBEDNS_REVISION}'..."
            rollbackK8SResource deploy ${DNS_DEPLOYMENT} kube-system "$TUFIN_KUBEDNS_REVISION"
        fi

        if [[ "$TUFIN_IS_UCP" == "false" ]]; then
            echo "Rolling back 'kube-dns' service..."
            patchK8SResource svc kube-dns "$(cat deployment/dns/dns.service_patch.yaml | sed 's/54/53/')"
        fi
    fi

    echo "Removing Orca Policy CRD..."
    removeK8SResourceFromFile deployment/crd/crd.policy.yaml

    if [[ $TUFIN_API_NETWORK_POLICY == "true" ]]; then
        echo "WARNING: Remove all Network Policies which were created by Orca? [Y/n]"
        if [[ "$TUFIN_SILENT_MODE" == "false" ]]; then
            while [[ -z "$removeNetPols" ]]; do
                read removeNetPols
            done
        else
            removeNetPols="Y"
        fi

        if [[ "$removeNetPols" =~ [^Yy] ]]; then
            echo "Network Policies will be kept in the cluster"
        else
            echo "Removing all Network Policies which were created by Orca..."
            removeAllOwnedResources
        fi
    fi

    echo "Uninstall finished"
}

removeAllOwnedResources() {

    local namespaces="$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')"
    local ownerLabel="tufin-owner=tufin"
    namespaces=${namespaces/default}

    for ns in ${namespaces}; do
        $TUFIN_KUBE_CLI delete netpol -l "$ownerLabel" -n "$ns" &> /dev/null
    done

    $TUFIN_KUBE_CLI delete netpol -l "$ownerLabel" &> /dev/null
}

createK8SResource() {

    $TUFIN_KUBE_CLI create -f "$1" --record &> /dev/null
}

patchK8SResource() {
    local type="$1"
    local name="$2"
    local file="$3"
    local ns="${4:-kube-system}"
    local patch_type="${5}"
    local patch_args=""

    if [[ ! -z "$patch_type" ]]; then
        patch_args="--type=${patch_type}"
    fi

    kubectl patch "$type" "$name" -n "$ns" "$patch_args" --record --patch "$file" &> /dev/null

    return $?
}

removeK8SResource() {

    local type="$1"
    local name="$2"
    local ns="${3:-$TUFIN_KITE_NAMESPACE}"

    kubectl delete "$type" "$name" -n "$ns" &> /dev/null

    return $?
}

removeK8SResourceFromFile() {

    $TUFIN_KUBE_CLI delete -f "$1"

    return $?
}

rollbackK8SResource() {
    local type="$1"
    local name="$2"
    local ns="${3:-$TUFIN_KITE_NAMESPACE}"
    local rev="${4:-0}"

    kubectl rollout undo "$type" "$name" -n "$ns" --to-revision "$rev" &> /dev/null

    return $?
}


generateInstallData() {

    cat <<EOF
{
  "status_code": ${1:-666},
  "log": "$(cat orca.log | tr '"' "'" | tr '\n' ';' | sed 's/;/$newline$/g')"
}
EOF
}

generateKubernetesData() {

    cat <<EOF
{
  "versions": [
    {"key": "kubectl", "value": "$("${TUFIN_KUBE_CLI}" version -o json | jq -r .clientVersion.gitVersion)"},
    {"key": "kubernetes", "value": "$(${TUFIN_KUBE_CLI} version -o json | jq -r .serverVersion.gitVersion)"}
  ]
}
EOF
}

sendInstallerData() {

    local code=$1
    local URL="${TUFIN_ORCA_URL}/linkspan/${TUFIN_DOMAIN}/${TUFIN_PROJECT}/installations"

    curl -s -i -X POST \
    -H "Authorization: Bearer ${TUFIN_API_TOKEN}" \
    -H "Content-Type:application/json" \
    -d "$(generateInstallData $code)" \
    "${URL}"
}

sendKubernetesData() {

    local URL="${TUFIN_ORCA_URL}/linkspan/${TUFIN_DOMAIN}/${TUFIN_PROJECT}/versions"

    curl -s -i -X POST \
    -H "Authorization: Bearer ${TUFIN_API_TOKEN}" \
    -H "Content-Type:application/json" \
    -d "$(generateKubernetesData)" \
    "${URL}"
}

printLogo() {

    echo "
  _____       __            ___
 |_   _|   _ / _ _ _ __    / _ \ _ __ ___ __ _
   | || | | | |_| | '_ \  | | | | '__/ __/ _  |
   | || |_| |  _| | | | | | |_| | | | (_| (_| |
   |_| \__,_|_| |_|_| |_|  \___/|_|  \___\__,_|
"
}

initVars

exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>orca.log 2>&1

main | tee /dev/fd/3

sendInstallerData $?
sendKubernetesData
