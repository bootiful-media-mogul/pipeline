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
EOF
  kubectl delete secrets -n $NAMESPACE_NAME $SECRETS || echo "no secrets to delete."
  kubectl create secret generic $SECRETS -n $NAMESPACE_NAME --from-env-file $SECRETS_FN
}

kubectl get ns $NAMESPACE_NAME || kubectl create namespace $NAMESPACE_NAME

write_secrets

create_ip ${MOGUL_CLIENT_IP}
create_ip ${AUTHORIZATION_SERVICE_IP}
create_ip ${MOGUL_SERVICE_IP}

kubectl apply  -n $NAMESPACE_NAME -f $ROOT_DIR/k8s