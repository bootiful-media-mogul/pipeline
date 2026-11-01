#!/usr/bin/env bash
# source this: exports the secrets bin/deploy.sh needs, read from mogul-secrets on the GKE
# production cluster, which is where the running system gets them today. prints nothing secret.
#
#   source bin/env-from-gke.sh

_mogul_kubeconfig="$(mktemp)"
if KUBECONFIG="$_mogul_kubeconfig" gcloud container clusters get-credentials joshlong \
    --region us-east4 --project joshlong >/dev/null 2>&1; then
  eval "$(KUBECONFIG="$_mogul_kubeconfig" kubectl -n mogul get secret mogul-secrets -o json |
    jq -r '.data | to_entries[] | "export \(.key)=\(.value | @base64d | @sh)"')"
  echo "loaded $(KUBECONFIG="$_mogul_kubeconfig" kubectl -n mogul get secret mogul-secrets -o json | jq '.data | length') variables from GKE"
else
  echo "could not reach the GKE cluster" >&2
fi
rm -f "$_mogul_kubeconfig"
unset _mogul_kubeconfig
