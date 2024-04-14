#!/usr/bin/env bash

# this pipeline deploys everything, altogether. if the assets are already
# deployed then its idempotent and nothing should happen. right?

export ROOT_DIR="$(cd `dirname $0` && pwd )"
echo "The root directory is ${ROOT_DIR}."
export NAMESPACE_NAME=mogul

AUTHORIZATION_SERVICE_IP=${NAMESPACE_NAME}-authorization-service-ip

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
MESSAGE=hik8s
EOF
  kubectl delete secrets $SECRETS || echo "no secrets to delete."
  kubectl create secret generic $SECRETS --from-env-file $SECRETS_FN
}

write_secrets

create_ip ${AUTHORIZATION_SERVICE_IP}

kubectl apply -f $ROOT_DIR/k8s