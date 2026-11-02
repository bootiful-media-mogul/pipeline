#!/usr/bin/env bash
# pushes mogul's apps to cloud foundry. see README.md.
#
#   bin/deploy.sh [--vars vars/<foundation>.yml] [app...]
#
# with no apps, it pushes all of them. cf has to be logged in already (in the cf repository:
# eval "$(./up.sh --env typical.env shell)"); it targets the org and space the vars file names, creating them
# the first time.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VARS_FILE="$ROOT_DIR/vars/typical.yml"
APPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --vars) VARS_FILE="$2"; shift 2 ;;
    *) APPS+=("$1"); shift ;;
  esac
done
# every app in the manifest, in order
ALL_APPS=($(awk '/^  - name:/ {print $3}' "$ROOT_DIR/manifest.yml"))
[ ${#APPS[@]} -gt 0 ] || APPS=("${ALL_APPS[@]}")

# the same secrets every pod on GKE gets from mogul-secrets. they come from the environment
# (bin/env-from-gke.sh) and only ever reach a temporary vars file. not workspace/bin/env.sh:
# that is the local development environment, with localhost for the database and rabbitmq.
SECRETS="ABLY_KEY AUTH0_CLIENT_ID AUTH0_CLIENT_SECRET AUTH0_DOMAIN AWS_ACCESS_KEY_ID
  AWS_ACCESS_KEY_SECRET AWS_REGION DB_HOST DB_PASSWORD DB_SCHEMA DB_USERNAME
  ELASTICSEARCH_API_HOST ELASTICSEARCH_API_KEY ELASTICSEARCH_OTEL_HEADER ELASTICSEARCH_OTEL_HOST
  OPENAI_KEY REDIS_HOST REDIS_PASSWORD REDIS_PORT RMQ_HOST RMQ_PASSWORD RMQ_USERNAME
  RMQ_VIRTUAL_HOST SETTINGS_PASSWORD SETTINGS_SALT"

missing=""
for s in $SECRETS; do
  [ -n "${!s:-}" ] || missing="$missing $s"
done
if [ -n "$missing" ]; then
  echo "these are not set:$missing" >&2
  echo "load them first: source bin/env-from-gke.sh" >&2
  exit 1
fi

# the images are private. cf hands the cell a pull credential: username _json_key, and a json
# key of the read-only service account mogul-cf-image-puller, kept in the bitwarden item
# mogul-cf-image-puller-key.
if [ -z "${CF_DOCKER_PASSWORD:-}" ]; then
  bw unlock --check >/dev/null 2>&1 </dev/null || { echo "bitwarden is locked: run bw-unlock first" >&2; exit 1; }
  CF_DOCKER_PASSWORD="$(bw get item mogul-cf-image-puller-key </dev/null | jq -r '.notes // .login.password // empty')"
  export CF_DOCKER_PASSWORD
fi
jq -e '.type == "service_account"' <<<"$CF_DOCKER_PASSWORD" >/dev/null 2>&1 ||
  { echo "CF_DOCKER_PASSWORD is not a service account's json key" >&2; exit 1; }

var(){ awk -v k="$1:" '$1 == k {print $2}' "$VARS_FILE"; }
REGISTRY="$(var registry)"
ORG="$(var org)"
SPACE="$(var space)"

cf oauth-token >/dev/null || { echo "cf is not logged in" >&2; exit 1; }
cf org "$ORG" >/dev/null 2>&1 || cf create-org "$ORG"
cf space "$ORG" >/dev/null 2>&1 || cf create-org "$SPACE"
cf space "$SPACE" -o "$ORG" >/dev/null 2>&1 || cf create-space "$SPACE" -o "$ORG"
cf target -o "$ORG" -s "$SPACE"

SECRETS_FILE="$(mktemp)"
trap 'rm -f "$SECRETS_FILE"' EXIT
chmod 600 "$SECRETS_FILE"
for s in $SECRETS; do
  # json strings are yaml strings, and jq quotes anything a secret might contain
  printf '%s: %s\n' "$s" "$(jq -n --arg v "${!s}" '$v')" >>"$SECRETS_FILE"
done

# pin what :latest is right now, the way kbld does for GKE, so a restart months from now runs
# the image that was deployed and not whatever was pushed since. cf interpolates the whole
# manifest even to push one app, so every app needs its digest.
for app in "${ALL_APPS[@]}"; do
  DIGEST="$(gcloud artifacts docker images describe "$REGISTRY/$app:latest" \
    --format='value(image_summary.digest)')"
  echo "$app-digest: $DIGEST" >>"$SECRETS_FILE"
done

for app in "${APPS[@]}"; do
  echo "------------------ $app $(awk -v k="$app-digest:" '$1 == k {print $2}' "$SECRETS_FILE")"
  cf push "$app" -f "$ROOT_DIR/manifest.yml" --vars-file "$VARS_FILE" --vars-file "$SECRETS_FILE" \
    --strategy rolling |
    # cf push prints the manifest it applies, environment and all. keep secrets off the screen.
    sed -u '/^Updating with these attributes/,/^Manifest applied/d'
done
