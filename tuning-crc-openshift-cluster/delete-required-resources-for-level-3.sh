#!/bin/bash
  
set -exuo pipefail

function delete_operator() {
        local delete_object=$1
        local namespace=$2
        local pod_selector=$3

        pod=$(${OC} get pod -l ${pod_selector} -o jsonpath="{.items[0].metadata.name}" -n ${namespace})

        ${OC} delete ${delete_object} -n ${namespace}
        # Wait until the operator pod is deleted before trying to delete the resources it manages
        ${OC} wait --for=delete pod/${pod} --timeout=120s -n ${namespace} || ${OC} delete pod/${pod} --grace-period=0 --force -n ${namespace} || true
}

${OC}  patch clusterversion version --type json -p "$(cat  ./tuning-crc-openshift-cluster/enable-cvo-override-level-3.yaml)"