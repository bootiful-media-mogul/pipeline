# cf-pipeline

Deploys Mogul's four applications (`gateway`, `client`, `api`, `processors`) to Cloud Foundry, as the same container images the GKE pipeline (`pipeline/`) deploys.
The foundation itself is built by `cf/`; Mogul's foundation, and what is still open before Mogul moves, are in `workspace/docs/cf.md`.

## Deploying

```bash
cd ~/code/mogul/cf && eval "$(./up.sh shell)"
cd ~/code/mogul/cf-pipeline
source bin/env-from-gke.sh     # or: bw-unlock && source ~/code/mogul/workspace/bin/env.sh
bin/deploy.sh                  # every app, or name some: bin/deploy.sh gateway client
```

`bin/deploy.sh` pins each app's `:latest` to its current digest (as kbld does for GKE), and runs `cf push --strategy rolling` for each app named, into the org and space `vars/default.yml` names (`mogul` / `production`), creating them the first time.
It hides the manifest diff `cf push` prints, because that diff includes the environment.

## Files

| File | Holds |
|---|---|
| `manifest.yml` | all four apps; every value that differs by foundation or is secret is a `((var))` |
| `vars/default.yml` | names and hosts for the default foundation (`cf/.env`); no secrets |
| `bin/deploy.sh` | resolves digests, writes the secrets to a temporary vars file, pushes |
| `bin/env-from-gke.sh` | exports the secrets from `mogul-secrets` on the GKE production cluster |

## Mapping from the GKE pipeline

| GKE (`pipeline/bin/k8s/carvel`) | Cloud Foundry (`manifest.yml`) |
|---|---|
| `envFrom: mogul-secrets` | `env`, shared by gateway, api and processors through a YAML anchor; the client gets only `MOGUL_SERVICE_HOST`, which nginx hands the SPA as `/config.js` |
| `resources.limits.memory` | `memory` |
| `ephemeral-storage` | `disk_quota` |
| `readinessProbe` on `/actuator/health/readiness` | `health-check-type: http` on the same endpoint |
| `expose: false` (processors) | `no-route: true`, `health-check-type: process` |
| `terminationGracePeriodSeconds: 300` | the foundation's `CF_GRACEFUL_SHUTDOWN_SECONDS`, which applies to every app |
| Ingress, ManagedCertificate, static IP | a route under `apps.mogul.pub`, covered by the foundation's wildcard certificate |
| KEDA `ScaledObject` (processors) | nothing yet: one fixed instance |

## Secrets

The secrets come from the environment, and are only ever written to a temporary file that is deleted when `bin/deploy.sh` exits.
`workspace/bin/env.java` doesn't export all of them yet (`REDIS_*`, `SETTINGS_PASSWORD` and `SETTINGS_SALT` are missing), which is why `bin/env-from-gke.sh` exists: `mogul-secrets` on GKE is the one complete copy today.

The images are private.
`cf push` gives the cell a pull credential: username `_json_key`, password a JSON key of the service account `mogul-cf-image-puller@joshlong.iam.gserviceaccount.com`, which can only read `mogul-artifact-registry`.
`bin/deploy.sh` takes it from `CF_DOCKER_PASSWORD`, or else from the file `MOGUL_CF_IMAGE_PULLER_KEY_FILE` (default `~/mogul-cf-image-puller-key.json`).

## Things to know

- **These apps share production's backing services.** api and processors on Cloud Foundry are more replicas of production: they use the production database, RabbitMQ and JobRunr tables, and processors takes real jobs.
  So `bin/deploy.sh` pushing an image with a new Flyway migration migrates the production database, exactly as a GKE deploy would.
- **Login needs an Auth0 callback.** Auth0 only accepts the callback URLs it lists, so add `https://studio.apps.mogul.pub/login/oauth2/code/auth0` to the application's allowed callback URLs (and `https://studio.apps.mogul.pub` to logout URLs and web origins) before logging in through the gateway on Cloud Foundry.
- **The gateway reaches api and client through their public routes**, as it does on GKE (`MOGUL_SERVICE_HOST`, `MOGUL_CLIENT_HOST` in `vars/default.yml`).
