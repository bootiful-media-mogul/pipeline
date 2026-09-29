#!/usr/bin/env bash

set -e
set -o pipefail

export ROOT_DIR="$(cd `dirname $0` && pwd )"
echo "The root directory is ${ROOT_DIR}."
export NAMESPACE_NAME=mogul

# the apps, in one place: the deploy loop and the KEDA check both walk this list, and they
# have to agree about it.
export APPS="api gateway client processors"

# KEDA, pinned. 2.21.0 exists but arrived with three breaking changes and a CVE that only
# reaches TriggerAuthentications using bound service account tokens or Vault -- ours reads a
# secret, so none of it applies to us and there is no reason to run a release this young on
# the cluster that scales production. bump this deliberately, not by drifting.
export KEDA_VERSION=2.20.2


create_ip(){
  ipn=$1
  if [ -z "$ipn" ]; then
    echo "you didn't specify the name of the IP address to create "
  else
    gcloud compute addresses list --format json | jq '.[].name' -r | grep $ipn || gcloud compute addresses create $ipn --global
  fi
}


write_secrets(){
  export SECRETS=${NAMESPACE_NAME}-secrets
  SECRETS_FN=$HOME/${SECRETS}
  mkdir -p "`dirname $SECRETS_FN`"


  # no longer required but keeping for posterity.
  cat <<EOF >${SECRETS_FN}
MOGUL_SERVICE_HOST=https://api.mogul.tools
MOGUL_GATEWAY_HOST=https://studio.mogul.tools
AUTHORIZATION_SERVICE_HOST=https://auth.mogul.tools
MOGUL_CLIENT_HOST=https://ui.mogul.tools
WP_CLIENT_ID=${WP_CLIENT_ID}
WP_CLIENT_SECRET=${WP_CLIENT_SECRET}
RMQ_HOST=${RMQ_HOST}
RMQ_USERNAME=${RMQ_USERNAME}
RMQ_PASSWORD=${RMQ_PASSWORD}
RMQ_VIRTUAL_HOST=${RMQ_VIRTUAL_HOST}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=${DB_HOST}
DB_SCHEMA=${DB_SCHEMA}
OPENAI_KEY=${OPENAI_KEY}
ABLY_KEY=${ABLY_KEY}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
AWS_REGION=${AWS_REGION}
ELASTICSEARCH_API_HOST=${ELASTICSEARCH_API_HOST}
ELASTICSEARCH_API_KEY=${ELASTICSEARCH_API_KEY}
ELASTICSEARCH_OTEL_HOST=${ELASTICSEARCH_OTEL_HOST}
ELASTICSEARCH_OTEL_HEADER=${ELASTICSEARCH_OTEL_HEADER}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_ACCESS_KEY_SECRET=${AWS_ACCESS_KEY_SECRET}
SETTINGS_PASSWORD=${SETTINGS_PASSWORD}
SETTINGS_SALT=${SETTINGS_SALT}
AUTH0_CLIENT_ID=${AUTH0_CLIENT_ID}
AUTH0_CLIENT_SECRET=${AUTH0_CLIENT_SECRET}
AUTH0_DOMAIN=${AUTH0_DOMAIN}
MOGUL_MANAGED_FILES_S3_BUCKET=mogul-managedfiles
MOGUL_AWS_CLOUDFRONT_DOMAIN=https://d3qy1h6z3g7kc1.cloudfront.net
EOF
# DEBUG=true
  kubectl delete secrets -n $NAMESPACE_NAME $SECRETS || echo "no secrets to delete."
  kubectl create secret generic $SECRETS -n $NAMESPACE_NAME --from-env-file $SECRETS_FN

  ##
  ## need to give a service account .json file to run
  ## the google cloud sql proxy auth container
  ##
  export SQL_SECRETS=${NAMESPACE_NAME}-sql-secrets
  export SQL_SECRETS_FN=${HOME}/${SQL_SECRETS}
  mkdir -p "`dirname $SQL_SECRETS_FN`"
  rm -f $SQL_SECRETS_FN
  echo $GCLOUD_SQL_SA_KEY  | base64 -d > $SQL_SECRETS_FN
  cat $SQL_SECRETS_FN
  # ok but how do i get the file to this place?
  kubectl get secrets/${SQL_SECRETS} ||  \
    kubectl create secret generic $SQL_SECRETS -n $NAMESPACE_NAME --from-file=service_account.json=$SQL_SECRETS_FN
}

kubectl get ns $NAMESPACE_NAME || kubectl create namespace $NAMESPACE_NAME

write_secrets

cd $ROOT_DIR/k8s/carvel/

# does anything we are about to deploy actually want KEDA? rather than keep a second list of
# which apps autoscale, ask the manifests -- turning on `scaling.enabled` for any app is then
# the only thing anyone has to remember. ytt alone is enough for this; kbld only resolves
# images and would want the network.
needs_keda(){
  for a in $APPS ; do
    if ytt -f app-${a}-data.yml -f data-schema.yml -f deployment.yml | grep -q 'kind: ScaledObject' ; then
      return 0
    fi
  done
  return 1
}

# a ScaledObject is not an optional extra: kubectl rejects a kind it has never heard of, and
# with `set -e` that ends the deploy having already updated the Deployment. so make sure KEDA
# is there, and is *ready*, before the loop applies anything.
install_keda(){

  if kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1 ; then
    # already installed, and we deliberately do not touch it: an unattended pipeline that
    # upgrades the autoscaler on every deploy is its own kind of outage. report what is
    # running instead, and say so if it has drifted from the pin.
    RUNNING_KEDA=$( kubectl get deploy keda-operator -n keda \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || echo "" )
    echo "KEDA is already installed (running: ${RUNNING_KEDA:-unknown}, pinned: ${KEDA_VERSION})."
    if [ -n "$RUNNING_KEDA" ] && [ "$RUNNING_KEDA" != "$KEDA_VERSION" ] ; then
      echo "NOTE: the cluster is running KEDA ${RUNNING_KEDA} but this pipeline pins ${KEDA_VERSION}."
      echo "      nothing here will change it. upgrade on purpose when you want to."
    fi
  else
    echo "KEDA is not installed. installing v${KEDA_VERSION}."
    # server-side: the CRDs in this manifest are far too big to round-trip through the
    # last-applied-configuration annotation, which is a 262144-byte limit and a confusing
    # failure when you hit it.
    kubectl apply --server-side -f \
      "https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"
  fi

  # CRDs that exist are not the same as a webhook that is listening. without these waits the
  # first deploy after an install races the operator and the ScaledObject apply just fails.
  kubectl wait --for=condition=established --timeout=120s \
    crd/scaledobjects.keda.sh crd/triggerauthentications.keda.sh
  for d in $( kubectl get deploy -n keda -o name ) ; do
    kubectl rollout status -n keda "$d" --timeout=300s
  done

  # only one APIService can own external metrics, and on GKE the Stackdriver adapter wants the
  # same slot. if it has it, every part of this will look healthy and the HPA will still never
  # read a value -- so say so loudly. not fatal: a degraded autoscaler is no reason to block
  # shipping the apps.
  # test the namespace, not the service name: this manifest calls it keda-metrics-apiserver
  # and the helm chart calls it keda-operator-metrics-apiserver, and either is fine.
  METRICS_NS=$( kubectl get apiservice v1beta1.external.metrics.k8s.io \
    -o jsonpath='{.spec.service.namespace}' 2>/dev/null || echo "" )
  METRICS_OWNER=$( kubectl get apiservice v1beta1.external.metrics.k8s.io \
    -o jsonpath='{.spec.service.namespace}/{.spec.service.name}' 2>/dev/null || echo "" )
  if [ "$METRICS_NS" != "keda" ] ; then
    echo "WARNING: v1beta1.external.metrics.k8s.io is served by '${METRICS_OWNER:-nothing}',"
    echo "         not by KEDA. ScaledObjects will look Ready and the HPA will read no metric."
  else
    echo "external metrics are served by KEDA (${METRICS_OWNER})."
  fi
}

if needs_keda ; then
  install_keda
else
  echo "no app asks for a ScaledObject; skipping KEDA."
fi

get_image(){
  kubectl get "$1" -o json  | jq -r  ".spec.template.spec.containers[0].image" || echo "no old version to compare against"
}

# an app is exposed unless its data file says otherwise. headless back-office workers
# (processors) render to a bare Deployment: no Service, no Ingress, and so no static IP
# and no managed certificate to reserve for them.
is_exposed(){
  ! grep -qE '^[[:space:]]*expose:[[:space:]]*false' "app-${1}-data.yml"
}

# MAIN APPS
# and there are a bunch of apps we needs to deploy and they all share a similar setup
for f in $APPS ; do
  echo "------------------"
  if is_exposed "$f" ; then
    IP=${NAMESPACE_NAME}-${f}-ip
    echo "creating IP called ${IP} "
    create_ip $IP
    echo "created IP called ${IP} "
  else
    echo "${f} is headless; skipping the static IP."
  fi
  Y=app-${f}-data.yml
  D=deployments/${f}-deployment
  OLD_IMAGE=`get_image $D `
  OUT_YML=out.yml
  ytt -f $Y -f "$ROOT_DIR"/k8s/carvel/data-schema.yml -f "$ROOT_DIR"/k8s/carvel/deployment.yml |  kbld -f -  > ${OUT_YML}
  cat ${OUT_YML}
  cat ${OUT_YML} | kubectl apply  -n $NAMESPACE_NAME -f -
  NEW_IMAGE=`get_image $D`
  echo "comparing container images for the first container!"
  echo $OLD_IMAGE
  echo $NEW_IMAGE
  if [ "$OLD_IMAGE" = "$NEW_IMAGE" ]; then
    echo "no need to restart $D"
  else
   echo "restarting $D"
   kubectl rollout restart $D
  fi

done


cd "$ROOT_DIR"
