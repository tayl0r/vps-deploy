# vps-deploy

The deploy job for apps that deploy to a VPS through its deploy gate: a reusable GitHub Actions workflow.

It makes one SSH connection with the app's deploy key and sends one line, `deploy <target>`, plus the
compose file's SHA-256 for an app whose repo keeps its compose. The registry token and actor go on stdin,
never in argv. The server's host keys are pinned in this repo (`known_hosts`), so the job never trusts a
host key on first use. Everything else (which image, which migration, whether this key may touch
`<target>` at all) is decided on the server, which refuses anything but that one line.

It is a whole job, not a step, on purpose. A job that calls a reusable workflow can't add steps to it,
so the deploy key never shares a job with the build: no dependency's install script and no other action
runs where the key is.

## Usage

Build and push the image in one job, then call this workflow as the next one:

```yaml
# One deploy at a time per branch, build included; a newer push waits rather than cutting one off.
concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      # ... check out, build and push the image ...

  deploy:
    needs: build
    permissions:
      contents: read
      packages: read
    uses: tayl0r/vps-deploy/.github/workflows/deploy.yml@<commit SHA of the latest release> # vX.Y.Z
    with:
      target: ${{ github.ref_name == 'prod' && 'myapp' || 'myapp-dev' }}
      # compose: deploy/myapp-dev/docker-compose.yml   # only for an app whose repo keeps its compose
    secrets:
      VPS_HOST: ${{ secrets.VPS_HOST }}
      VPS_DEPLOY_USER: ${{ secrets.VPS_DEPLOY_USER }}
      VPS_DEPLOY_KEY: ${{ secrets.VPS_DEPLOY_KEY }}
```

Work the target out from the branch in the calling job, never from an output of the build job: whatever
runs in the build could set that output.

Pin a full commit SHA, with the release tag in a comment, never a movable tag. Bump the pin only after
reading the diff since your current one: this workflow runs with your deploy key.

## Inputs and secrets

| Input | Required | Meaning |
|---|---|---|
| `target` | yes | The deployment to update: `<app>` (prod) or `<app>-dev` |
| `compose` | no | Path, from the repository root, to the repo's compose for this deployment; its SHA-256 is sent so the server can refuse a deploy when its own copy differs. Required for an app whose repo keeps its compose |

The three secrets, `VPS_HOST`, `VPS_DEPLOY_USER` and `VPS_DEPLOY_KEY`, are required. They live in the app
repo's `vps` environment, which only `main` and `prod` may use. The job sets that environment itself (a
calling job can't); the caller still passes each secret by name. The server pulls the image with the run's
own token.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | Deployed |
| 1 | The deploy didn't happen or failed. The message above says why: the job's own checks, the gate (for example, no compose checksum from an app that needs one), or the deploy itself, with the path of its log on the server |
| 2 | The deploy gate refused the command: `target` isn't one of this app's deployments |
| 3 | Compose drift: the server's compose differs from the repo's. Its admin installs the repo's copy, then the deploy is re-run |
| 75 | Another deploy of the same deployment ran for more than 10 minutes |
| 255 | SSH failed: connection, host key or deploy key. If the gate had already printed its `deploying` line, the deploy continues on the server without the job |

Each failure also prints one `::error` annotation saying which of these it was. A deploy whose image is
already pulled finishes on the server even if the job is cancelled; one cancelled earlier changes nothing.

## The server side

The deploy gate, its accounts and its logs live in a private infrastructure repo. Deploy keys are issued
by the server's admin; nobody sets the secrets above by hand.
