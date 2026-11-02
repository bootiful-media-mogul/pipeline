#!/usr/bin/env bash
# copies production's secrets, mogul-secrets on the GKE cluster joshlong, into the bitwarden
# secure note mogul-production-secrets (folder mogul), one hidden field per variable, then reads
# the note back and checks it against the cluster. creates the note, or replaces its fields.
# prints nothing secret. only works while the GKE cluster exists: it's the copy before it goes.
#
#   bw-unlock && bin/secrets-to-bitwarden.sh

set -euo pipefail

ITEM=mogul-production-secrets
FOLDER=mogul

bw unlock --check >/dev/null 2>&1 </dev/null || { echo "bitwarden is locked: run bw-unlock first" >&2; exit 1; }
bw sync >/dev/null

kubeconfig="$(mktemp)"
trap 'rm -f "$kubeconfig"' EXIT
KUBECONFIG="$kubeconfig" gcloud container clusters get-credentials joshlong \
  --region us-east4 --project joshlong >/dev/null 2>&1 || { echo "could not reach the GKE cluster" >&2; exit 1; }
# {name: value}, decoded
secrets="$(KUBECONFIG="$kubeconfig" kubectl -n mogul get secret mogul-secrets -o json |
  jq -c '.data | map_values(@base64d)')"
fields="$(jq -c 'to_entries | sort_by(.key) | map({name: .key, value: .value, type: 1})' <<<"$secrets")"

folder="$(bw list folders | jq -r --arg n "$FOLDER" '[.[] | select(.name == $n)] | if length == 1 then .[0].id else empty end')"
[ -n "$folder" ] || { echo "bitwarden: expected exactly one folder named $FOLDER" >&2; exit 1; }
id="$(bw list items --folderid "$folder" | jq -r --arg n "$ITEM" '[.[] | select(.name == $n)] |
  if length > 1 then error("more than one item named " + $n) else .[0].id // empty end')"

if [ -n "$id" ]; then
  bw get item "$id" | jq --argjson f "$fields" '.fields = $f' | bw encode | bw edit item "$id" >/dev/null
  echo "updated $ITEM"
else
  jq -n --arg name "$ITEM" --arg folder "$folder" --argjson f "$fields" \
    '{type: 2, secureNote: {type: 0}, name: $name, folderId: $folder,
      notes: "production secrets, one field per variable. source bin/env-from-bitwarden.sh in the pipeline repository.",
      fields: $f}' | bw encode | bw create item >/dev/null
  echo "created $ITEM"
fi

# read it back rather than trusting the write.
bw sync >/dev/null
stored="$(bw list items --folderid "$folder" | jq -c --arg n "$ITEM" \
  'first(.[] | select(.name == $n)) | [.fields[] | {(.name): .value}] | add')"
[ "$(jq -cS . <<<"$stored")" = "$(jq -cS . <<<"$secrets")" ] || { echo "MISMATCH: $ITEM differs from mogul-secrets" >&2; exit 1; }
echo "$ITEM: all $(jq length <<<"$secrets") variables read back and match mogul-secrets"
