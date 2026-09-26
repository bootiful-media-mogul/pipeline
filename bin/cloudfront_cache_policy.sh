#!/usr/bin/env bash
#
# puts the `v` query parameter into a distribution's cache key.
#
# a ManagedFile's S3 key never changes, so a re-rendered episode lands at exactly the URL
# the old one is already cached under. getDownloadableUrlForManagedFile addresses it as
# `?v=<etag>` so that each version is a distinct URL -- but a query string only separates
# anything if the distribution is told to look at it. by default CloudFront's cache
# policies drop query strings entirely, and every version collides on one entry: that is
# how a deleted segment kept downloading as the old 65MB file for 17 hours.
#
# run this BEFORE deploying a build that sets `Cache-Control: public, max-age=31536000,
# immutable` (see Storage.CACHE_CONTROL). in the other order you pin the wrong object for
# a year instead of a day, and only an invalidation gets you out of it.
#
# there are two distributions -- the dev one in api/src/main/resources/application.properties
# and the production one in deploy.sh -- and both need this.
#
# usage: ./cloudfront_cache_policy.sh <distribution-id>

set -euo pipefail

DISTRIBUTION_ID="${1:?usage: $0 <distribution-id>}"
POLICY_NAME="mogul-managed-files-versioned"

echo "==> looking for an existing cache policy called '${POLICY_NAME}'"
POLICY_ID="$(aws cloudfront list-cache-policies --type custom \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='${POLICY_NAME}'].CachePolicy.Id | [0]" \
  --output text)"

if [ "${POLICY_ID}" = "None" ] || [ -z "${POLICY_ID}" ]; then
  echo "==> creating it"
  # `v` only. `download=true` is a hint to the browser, not something the origin varies
  # on, so including it would just split every object across two identical cache entries.
  POLICY_ID="$(aws cloudfront create-cache-policy --cache-policy-config '{
    "Name": "'"${POLICY_NAME}"'",
    "Comment": "managed files are addressed as ?v=<etag>; the version has to be in the cache key for that to mean anything",
    "DefaultTTL": 86400,
    "MaxTTL": 31536000,
    "MinTTL": 0,
    "ParametersInCacheKeyAndForwardedToOrigin": {
      "EnableAcceptEncodingGzip": true,
      "EnableAcceptEncodingBrotli": true,
      "HeadersConfig":     { "HeaderBehavior": "none" },
      "CookiesConfig":     { "CookieBehavior": "none" },
      "QueryStringsConfig": {
        "QueryStringBehavior": "whitelist",
        "QueryStrings": { "Quantity": 1, "Items": ["v"] }
      }
    }
  }' --query 'CachePolicy.Id' --output text)"
else
  echo "==> reusing ${POLICY_ID}"
fi

echo "==> attaching ${POLICY_ID} to the default behaviour of ${DISTRIBUTION_ID}"
aws cloudfront get-distribution-config --id "${DISTRIBUTION_ID}" > /tmp/cf-dist.json
ETAG="$(python3 -c 'import json,sys; print(json.load(open("/tmp/cf-dist.json"))["ETag"])')"
python3 - "${POLICY_ID}" <<'PY'
import json, sys
policy_id = sys.argv[1]
doc = json.load(open("/tmp/cf-dist.json"))
behaviour = doc["DistributionConfig"]["DefaultCacheBehavior"]
behaviour["CachePolicyId"] = policy_id
# a behaviour carries either a cache policy or the legacy ForwardedValues, never both.
behaviour.pop("ForwardedValues", None)
behaviour.pop("MinTTL", None)
behaviour.pop("DefaultTTL", None)
behaviour.pop("MaxTTL", None)
json.dump(doc["DistributionConfig"], open("/tmp/cf-config.json", "w"))
PY
aws cloudfront update-distribution --id "${DISTRIBUTION_ID}" \
  --if-match "${ETAG}" --distribution-config "file:///tmp/cf-config.json" > /dev/null

echo "==> clearing what the old policy already cached"
aws cloudfront create-invalidation --distribution-id "${DISTRIBUTION_ID}" --paths '/*' \
  --query 'Invalidation.Id' --output text

echo "==> done. deploying takes a few minutes to propagate; verify with:"
echo "    curl -sI '<domain>/<key>?v=anything' | grep -i 'x-cache\|content-length'"
