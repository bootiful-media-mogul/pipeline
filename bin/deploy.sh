#!/usr/bin/env bash

export ROOT_DIR="$(cd `dirname $0` && pwd )"
echo "The root directory is ${ROOT_DIR}."
export NAMESPACE_NAME=mogul

AUTHORIZATION_SERVICE_IP=${NAMESPACE_NAME}-authorization-service-ip
MOGUL_CLIENT_IP=${NAMESPACE_NAME}-mogul-client-ip
MOGUL_SERVICE_IP=${NAMESPACE_NAME}-mogul-service-ip

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
MESSAGE=ohai
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
PODCAST_ASSETS_S3_BUCKET=podcast-assets-bucket-dev
PODCAST_ASSETS_S3_BUCKET_FOLDER=062019
PODCAST_INPUT_S3_BUCKET=podcast-input-bucket-dev
PODCAST_OUTPUT_S3_BUCKET=podcast-output-bucket-dev
IDP_ISSUER_URI=http://localhost:9090
SETTINGS_PASSWORD=${SETTINGS_PASSWORD}
SETTINGS_SALT=${SETTINGS_SALT}
EOF

  kubectl delete secrets -n $NAMESPACE_NAME $SECRETS || echo "no secrets to delete."
  kubectl create secret generic $SECRETS -n $NAMESPACE_NAME --from-env-file $SECRETS_FN
}

kubectl get ns $NAMESPACE_NAME || kubectl create namespace $NAMESPACE_NAME

#write_secrets

#create_ip ${MOGUL_CLIENT_IP}
#create_ip ${AUTHORIZATION_SERVICE_IP}
#create_ip ${MOGUL_SERVICE_IP}

ytt -f  $ROOT_DIR/k8s/kpp/mogul-service-data.yml  -f   $ROOT_DIR/k8s/kpp/data-schema.yml -f   $ROOT_DIR/k8s/kpp/deployment.yml | kubectl apply -f -

#kubectl apply  -n $NAMESPACE_NAME -f $ROOT_DIR/k8s