#!/bin/bash

set -exuo pipefail

function preflight_failure() {
        local msg=$1
        echo "$msg"
        if [ -z "${SNC_NON_FATAL_PREFLIGHT_CHECKS-}" ]; then
                exit 1
        fi
}

function run_preflight_checks() {
        echo "Checking libvirt and DNS configuration"

        LIBVIRT_URI=qemu+tcp://localhost/system

        # check if libvirtd is listening on a TCP socket
        if ! virsh -c ${LIBVIRT_URI} uri >/dev/null; then
                preflight_failure  "libvirtd is not listening for plain-text TCP connections, see https://github.com/openshift/installer/tree/master/docs/dev/libvirt#configure-libvirt-to-accept-tcp-connections"
        fi

	if ! virsh -c ${LIBVIRT_URI} net-info default &> /dev/null; then
		echo "Default libvirt network is not available. Exiting now!"
		exit 1
	fi
	echo "default network is available"

	#Check if default libvirt network is Active
	if [[ $(virsh -c ${LIBVIRT_URI}  net-info default | awk '{print $2}' | sed '3q;d') == "no" ]]; then
		echo "Default network is not active. Exiting now!"
		exit 1
	fi

	#Just warn if architecture is not supported
	case $ARCH in
		x86_64|ppc64le|s390x)
			echo "The host arch is ${ARCH}.";;
		*)
 			echo "The host arch is ${ARCH}. This is not supported by SNC!";;
	esac

        # check for availability of a hypervisor using kvm
        if ! virsh -c ${LIBVIRT_URI} capabilities | ${XMLLINT} --xpath "/capabilities/guest/arch[@name='${ARCH}']/domain[@type='kvm']" - &>/dev/null; then
                preflight_failure "Your ${ARCH} platform does not provide a hardware-accelerated hypervisor, it's strongly recommended to enable it before running SNC. Check virt-host-validate for more detailed diagnostics"
                return
        fi

        # check that api.crc.testing either can't be resolved, or resolves to 192.168.126.1[01]
        local ping_status
        ping_status="$(ping -c1 api.crc.testing | head -1 || true >/dev/null)"
        if echo ${ping_status} | grep "PING api.crc.testing (" && ! echo ${ping_status} | grep "192.168.126.1[01])"; then
                preflight_failure "DNS setup seems wrong, api.crc.testing resolved to an IP which is neither 192.168.126.10 nor 192.168.126.11, please check your NetworkManager configuration and /etc/hosts content"
                return
        fi

        # check if firewalld is configured to allow traffic from 192.168.126.0/24 to 192.168.122.1
        # this check is very basic and expects the configuration to match
        # https://github.com/openshift/installer/tree/master/docs/dev/libvirt#firewalld
        # Disabled for now as on stock RHEL8 installs, additional permissions are needed for
        # firewall-cmd --list-services, so this test fails for unrelated reasons
        #
        #local zone
        #if firewall-cmd -h >/dev/null; then
        #        # With older libvirt, the 'libvirt' zone will not exist
        #        if firewall-cmd --get-zones |grep '\<libvirt\>'; then
        #                zone=libvirt
        #        else
        #                zone=dmz
        #        fi
        #        if ! firewall-cmd --zone=${zone} --list-services | grep '\<libvirt\>'; then
        #                preflight_failure "firewalld is available, but it is not configured to allow 'libvirt' traffic in either the 'libvirt' or 'dmz' zone, please check https://github.com/openshift/installer/tree/master/docs/dev/libvirt#firewalld"
        #                return
        #        fi
        #fi

        echo "libvirt and DNS configuration successfully checked"
}

function replace_pull_secret() {
        # Hide the output of 'cat $OPENSHIFT_PULL_SECRET_PATH' so that it doesn't
        # get leaked in CI logs
        set +x
        local filename=$1
        ${YQ} write --inplace $filename --style literal pullSecret "$(< $OPENSHIFT_PULL_SECRET_PATH)"
        set -x
}

function apply_bootstrap_etcd_hack() {
        # This is needed for now due to etcd changes in 4.4:
        # https://github.com/openshift/cluster-etcd-operator/pull/279
        while ! ${OC} get etcds cluster >/dev/null 2>&1; do
            sleep 3
        done
        echo "API server is up, applying etcd hack"
        ${OC} patch etcd cluster -p='{"spec": {"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true}}}' --type=merge
}

function apply_auth_hack() {
        # This is needed for now due to recent change in auth:
        # https://github.com/openshift/cluster-authentication-operator/pull/318
        while ! ${OC} get authentications.operator.openshift.io cluster >/dev/null 2>&1; do
            sleep 3
        done
        echo "Auth operator is now available, applying auth hack"
        ${OC} patch authentications.operator.openshift.io cluster -p='{"spec": {"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableOAuthServer": true}}}' --type=merge
}

function create_json_description {
    openshiftInstallerVersion=$(${OPENSHIFT_INSTALL} version)
    sncGitHash=$(git describe --abbrev=4 HEAD 2>/dev/null || git rev-parse --short=4 HEAD)
    echo {} | ${JQ} '.version = "1.1"' \
            | ${JQ} '.type = "snc"' \
            | ${JQ} ".buildInfo.buildTime = \"$(date -u --iso-8601=seconds)\"" \
            | ${JQ} ".buildInfo.openshiftInstallerVersion = \"${openshiftInstallerVersion}\"" \
            | ${JQ} ".buildInfo.sncVersion = \"git${sncGitHash}\"" \
            | ${JQ} ".clusterInfo.openshiftVersion = \"${OPENSHIFT_RELEASE_VERSION}\"" \
            | ${JQ} ".clusterInfo.clusterName = \"${CRC_VM_NAME}\"" \
            | ${JQ} ".clusterInfo.baseDomain = \"${BASE_DOMAIN}\"" \
            | ${JQ} ".clusterInfo.appsDomain = \"apps-${CRC_VM_NAME}.${BASE_DOMAIN}\"" >${INSTALL_DIR}/crc-bundle-info.json
}

function generate_pv() {
  local pvdir="${1}"
  local name="${2}"
cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${name}
  labels:
    volume: ${name}
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
    - ReadWriteMany
    - ReadOnlyMany
  hostPath:
    path: ${pvdir}
  persistentVolumeReclaimPolicy: Recycle
EOF
}

function setup_pv_dirs() {
    local dir="${1}"
    local count="${2}"

    ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo bash -x -s' <<EOF
    for pvsubdir in \$(seq -f "pv%04g" 1 ${count}); do
        mkdir -p "${dir}/\${pvsubdir}"
    done
    if ! chcon -R -t svirt_sandbox_file_t "${dir}" &> /dev/null; then
        echo "Failed to set SELinux context on ${dir}"
    fi
    chmod -R 770 ${dir}
EOF
}

function create_pvs() {
    local pvdir="${1}"
    local count="${2}"

    setup_pv_dirs "${pvdir}" "${count}"

    for pvname in $(seq -f "pv%04g" 1 ${count}); do
        if ! ${OC} get pv "${pvname}" &> /dev/null; then
            generate_pv "${pvdir}/${pvname}" "${pvname}" | ${OC} create -f -
        else
            echo "persistentvolume ${pvname} already exists"
        fi
    done

    # Apply registry pvc to bound with pv0001
    ${OC} apply -f registry_pvc.yaml

    # Add registry storage to pvc
    ${OC} patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "add", "path": "/spec/storage/pvc", "value": {"claim": "crc-image-registry-storage"}}]' --type=json
    # Remove emptyDir as storage for registry
    ${OC} patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "remove", "path": "/spec/storage/emptyDir"}]' --type=json
}

# This follows https://blog.openshift.com/enabling-openshift-4-clusters-to-stop-and-resume-cluster-vms/
# in order to trigger regeneration of the initial 24h certs the installer created on the cluster
function renew_certificates() {
    local vm_prefix=$(get_vm_prefix ${CRC_VM_NAME})
    shutdown_vm ${vm_prefix}

    # Enable the network time sync and set the clock back to present on host
    sudo date -s '1 day'
    sudo timedatectl set-ntp on

    start_vm ${vm_prefix}

    # After cluster starts kube-apiserver-client-kubelet signer need to be approved
    timeout 300 bash -c -- "until ${OC} get csr | grep Pending; do echo 'Waiting for first CSR request.'; sleep 2; done"
    ${OC} get csr -ojsonpath='{.items[*].metadata.name}' | xargs ${OC} adm certificate approve

    # Retry 5 times to make sure kubelet certs are rotated correctly.
    i=0
    while [ $i -lt 5 ]; do
        if ! (${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo openssl x509 -checkend 2160000 -noout -in /var/lib/kubelet/pki/kubelet-client-current.pem && \
           ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo openssl x509 -checkend 2160000 -noout -in /etc/kubernetes/static-pod-resources/kube-apiserver-certs/configmaps/aggregator-client-ca/ca-bundle.crt); then
	    # Wait until bootstrap csr request is generated with 5 min timeout
	    echo "Retry loop $i, wait for 60sec before starting next loop"
            sleep 60
	else
            break
        fi
	i=$[$i+1]
    done
    if ! (${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo openssl x509 -checkend 2160000 -noout -in /var/lib/kubelet/pki/kubelet-client-current.pem && \
        ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo openssl x509 -checkend 2160000 -noout -in /etc/kubernetes/static-pod-resources/kube-apiserver-certs/configmaps/aggregator-client-ca/ca-bundle.crt); then

        echo "Certs are not yet rotated to have 30 days validity"
	exit 1
    fi
}

# deletes an operator and wait until the resources it manages are gone.
function delete_operator() {
        local delete_object=$1
        local namespace=$2
        local pod_selector=$3

	retry ${OC} get pods
        pod=$(${OC} get pod -l ${pod_selector} -o jsonpath="{.items[0].metadata.name}" -n ${namespace})

        retry ${OC} delete ${delete_object} -n ${namespace}
        # Wait until the operator pod is deleted before trying to delete the resources it manages
        ${OC} wait --for=delete pod/${pod} --timeout=120s -n ${namespace} || ${OC} delete pod/${pod} --grace-period=0 --force -n ${namespace} || true
}
