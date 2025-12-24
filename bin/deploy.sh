#!/usr/bin/env bash

set -e
set -o pipefail

export ROOT_DIR="$(cd `dirname $0` && pwd )"
echo "The root directory is ${ROOT_DIR}."
export NAMESPACE_NAME=mogul


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
MOGUL_SERVICE_HOST=https://api.media-mogul.io
MOGUL_GATEWAY_HOST=https://studio.media-mogul.io
AUTHORIZATION_SERVICE_HOST=https://auth.media-mogul.io
MOGUL_CLIENT_HOST=https://ui.media-mogul.io
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
AWS_REGION=${AWS_REGION}
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

get_image(){
  kubectl get "$1" -o json  | jq -r  ".spec.template.spec.containers[0].image" || echo "no old version to compare against"
}

# MAIN APPS
# and there are a bunch of apps we needs to deploy and they all share a similar setup
for f in mogul-service mogul-gateway mogul-client ; do
  
  echo "------------------"

  IP=${NAMESPACE_NAME}-${f}-ip
  echo "creating IP called ${IP} "
  create_ip $IP
  echo "created IP called ${IP} "
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
