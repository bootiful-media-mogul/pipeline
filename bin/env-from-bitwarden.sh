#!/usr/bin/env bash
# source this: exports the secrets bin/deploy.sh needs, from the bitwarden secure note
# mogul-production-secrets (folder mogul), one field per variable. prints nothing secret.
#
#   bw-unlock && source bin/env-from-bitwarden.sh

# return when sourced, exit when run.
# shellcheck disable=SC2317

if ! bw unlock --check >/dev/null 2>&1 </dev/null; then
  echo "bitwarden is locked: run bw-unlock first" >&2
  return 1 2>/dev/null || exit 1
fi

# `eval "$(cmd)"` throws away cmd's exit status, so assign, check, then eval.
if ! _mogul_env="$(bw list items --search mogul-production-secrets </dev/null | jq -er '
    [.[] | select(.name == "mogul-production-secrets")]
    | if length == 1 then .[0] else error("expected exactly one item named mogul-production-secrets") end
    | .fields[] | "export \(.name)=\(.value | @sh)"')"; then
  echo "could not read mogul-production-secrets from bitwarden" >&2
  unset _mogul_env
  return 1 2>/dev/null || exit 1
fi
eval "$_mogul_env"
echo "loaded $(printf '%s\n' "$_mogul_env" | grep -c '^export ') variables from bitwarden"
unset _mogul_env
