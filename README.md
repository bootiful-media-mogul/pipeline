# pipeline

Deploys Mogul's four applications (`gateway`, `client`, `api`, `processors`) to Cloud Foundry from the container images built by their own repositories. The old GKE deployment is in `k8s-pipeline/`.
The foundation itself is built by `cf/`; Mogul's foundation, and what is still open before Mogul moves, are in `workspace/docs/cf.md`.

## Deploying

```bash
cd ~/code/mogul/cf && eval "$(./up.sh --env typical.env shell)"
cd ~/code/mogul/pipeline
bw-unlock                      # for the image pull key
source bin/env-from-gke.sh     # production's secrets
bin/deploy.sh                  # every app, or name some: bin/deploy.sh gateway client
```

Mogul's foundation is the typical one (`cf/typical.env`, `api.cf.applicationconcierge.com`); `--vars vars/<foundation>.yml` names another.

The GitHub Actions workflow deploys all four apps on a push to this repository's `main` branch, a manual run, or an `update-event` repository dispatch. The client build sends that dispatch directly; the api, gateway and processors builds send it through `github-actions-setup-container-build-env`. Concurrent deploys queue so a later build cannot overlap a deployment already in progress. GitHub Actions uses `vars/typical.yml` and does not need access to the GKE cluster.

`bin/deploy.sh` pins each app's `:latest` to its current digest (as kbld does for GKE), and runs `cf push --strategy rolling` for each app named, into the org and space the vars file names (`mogul` / `production`), creating them the first time.
It hides the manifest diff `cf push` prints, because that diff includes the environment.

## Files

| File | Holds |
|---|---|
| `manifest.yml` | all four apps; every value that differs by foundation or is secret is a `((var))` |
| `vars/typical.yml` | names and hosts for the typical foundation (`cf/typical.env`), where `mogul.tools` is a private domain of the `mogul` org; no secrets |
| `bin/deploy.sh` | resolves digests, writes the secrets to a temporary vars file, pushes |
| `bin/env-from-gke.sh` | exports the secrets from `mogul-secrets` on the GKE production cluster |

## Mapping from the GKE pipeline

| GKE (`k8s-pipeline/bin/k8s/carvel`) | Cloud Foundry (`manifest.yml`) |
|---|---|
| `envFrom: mogul-secrets` | `env`, shared by gateway, api and processors through a YAML anchor; the client gets only `MOGUL_SERVICE_HOST`, which nginx hands the SPA as `/config.js` |
| `resources.limits.memory` | `memory` |
| `ephemeral-storage` | `disk_quota` |
| `readinessProbe` on `/actuator/health/readiness` | `health-check-type: http` on the same endpoint |
| `expose: false` (processors) | `no-route: true`, `health-check-type: process` |
| `terminationGracePeriodSeconds: 300` | the foundation's `CF_GRACEFUL_SHUTDOWN_SECONDS`, which applies to every app |
| Ingress, ManagedCertificate, static IP | a route under `mogul.tools`, a private domain whose wildcard certificate the foundation issues (`cf/README.md`, "Custom domains") |
| KEDA `ScaledObject` (processors) | nothing yet: one fixed instance |

## Secrets

The secrets come from the environment, and are only ever written to a temporary file that is deleted when `bin/deploy.sh` exits.
They have to be production's, and `mogul-secrets` on GKE is the one complete copy today, so `bin/env-from-gke.sh` reads them from there.
Don't use `workspace/bin/env.sh` for this: it is the local development environment, and points the database and RabbitMQ at localhost.

For GitHub Actions, set the following Actions secrets on `bootiful-media-mogul/pipeline` (or make org secrets available to that repository): `GCLOUD_SA_KEY` for read access to the Artifact Registry image digests, `CF_USERNAME` and `CF_PASSWORD` for the Cloud Foundry API, and `CF_DOCKER_PASSWORD` for the read-only image pull service account's JSON key. Set all production app secrets named in the `env` section of `.github/workflows/deploy-to-production.yaml` too. The workflow maps those secrets to the variables required by `bin/deploy.sh`; a missing value fails deployment before any app is pushed.
WordPress OAuth client credentials come from each Mogul's `wordpress` settings page. The gateway reads `clientId` and `clientSecret` through the settings API; no `WP_CLIENT_ID` or `WP_CLIENT_SECRET` Actions secret is needed.

The images are private.
`cf push` gives the cell a pull credential: username `_json_key`, password a JSON key of the service account `mogul-cf-image-puller@joshlong.iam.gserviceaccount.com`, which can only read `mogul-artifact-registry`.
The key is in Bitwarden, in the item `mogul-cf-image-puller-key` (as its notes or its password), and `bin/deploy.sh` reads it from there with `bw`, so the vault has to be unlocked; `CF_DOCKER_PASSWORD`, if set, takes precedence.
If the key is ever lost, make a new one (`gcloud iam service-accounts keys create`), save it to the same item, and delete the old key.

## Things to know

- **These apps share production's backing services.** api and processors on Cloud Foundry are more replicas of production: they use the production database, RabbitMQ and JobRunr tables, and processors takes real jobs.
  So `bin/deploy.sh` pushing an image with a new Flyway migration migrates the production database, exactly as a GKE deploy would.
- **Login needs an Auth0 callback.** Auth0 only accepts the callback URLs it lists. `https://studio.mogul.tools/login/oauth2/code/auth0` (and `https://studio.mogul.tools/oauth2/code/wordpress` in the WordPress.com app) are registered already, because production on GKE uses the same names; a gateway on any other host needs its own added first.
- **The gateway reaches api and client through their public routes**, as it does on GKE (`MOGUL_SERVICE_HOST`, `MOGUL_CLIENT_HOST` in `vars/typical.yml`).
