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
  cat <<EOF >${SECRETS_FN}
MOGUL_SERVICE_HOST=https://api.media-mogul.io
MOGUL_GATEWAY_HOST=https://studio.media-mogul.io
AUTHORIZATION_SERVICE_HOST=https://auth.media-mogul.io
MOGUL_CLIENT_HOST=https://ui.media-mogul.io
SPRING_SECURITY_OAUTH2_AUTHORIZATIONSERVER_ISSUER=https://auth.media-mogul.io
RMQ_HOST=${RMQ_HOST}
RMQ_USERNAME=${RMQ_USERNAME}
RMQ_PASSWORD=${RMQ_PASSWORD}
RMQ_VIRTUAL_HOST=${RMQ_VIRTUAL_HOST}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=${DB_HOST}
DB_SCHEMA=${DB_SCHEMA}
OPENAI_KEY=${OPENAI_KEY}
AWS_REGION=${AWS_REGION}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_ACCESS_KEY_SECRET=${AWS_ACCESS_KEY_SECRET}
PODCASTS_PROCESSOR_RMQ_REQUESTS=podcast-processor-requests
PODCASTS_PROCESSOR_RMQ_REPLIES=podcast-processor-replies
PODCAST_ASSETS_S3_BUCKET=podcast-assets-bucket-dev
PODCAST_ASSETS_S3_BUCKET_FOLDER=062019
PODCAST_INPUT_S3_BUCKET=podcast-input-bucket-dev
PODCAST_OUTPUT_S3_BUCKET=podcast-output-bucket-dev
AUTHORIZATION_SERVICE_USERS_JLONG_USERNAME=${AUTHORIZATION_SERVICE_USERS_JLONG_USERNAME}
AUTHORIZATION_SERVICE_USERS_JLONG_PASSWORD=${AUTHORIZATION_SERVICE_USERS_JLONG_PASSWORD}
AUTHORIZATION_SERVICE_CLIENTS_MOGUL_CLIENT_ID=${AUTHORIZATION_SERVICE_CLIENTS_MOGUL_CLIENT_ID}
AUTHORIZATION_SERVICE_CLIENTS_MOGUL_CLIENT_SECRET=${AUTHORIZATION_SERVICE_CLIENTS_MOGUL_CLIENT_SECRET}
SETTINGS_PASSWORD=${SETTINGS_PASSWORD}
SETTINGS_SALT=${SETTINGS_SALT}
EOF
# put DEBUG=true in secret above to enable a lot of logging.

  kubectl delete secrets -n $NAMESPACE_NAME $SECRETS || echo "no secrets to delete."
  kubectl create secret generic $SECRETS -n $NAMESPACE_NAME --from-env-file $SECRETS_FN
}

kubectl get ns $NAMESPACE_NAME || kubectl create namespace $NAMESPACE_NAME

write_secrets

cd $ROOT_DIR/k8s/carvel/

get_image(){
  kubectl get "$1" -o json  | jq -r  ".spec.template.spec.containers[0].image" || echo "no old version to compare against"
}

for f in mogul-podcast-audio-processor authorization-service mogul-service mogul-gateway mogul-client ; do

  echo "------------------"

  IP=${NAMESPACE_NAME}-${f}-ip
  echo "creating IP called ${IP} "
  create_ip $IP
  echo "created IP called ${IP} "
  Y=app-${f}-data.yml
  D=deployments/${f}-deployment
  OLD_IMAGE=`get_image $D `
  ytt -f $Y -f "$ROOT_DIR"/k8s/carvel/data-schema.yml -f "$ROOT_DIR"/k8s/carvel/deployment.yml |  kbld -f -  > out.yml
  cat out.yml | kubectl apply  -n $NAMESPACE_NAME -f -
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
