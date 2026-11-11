# vps-deploy

A GitHub Action that asks a VPS's deploy gate to redeploy one of an app's deployments.

It makes one SSH connection with the app's deploy key and sends one line, `deploy <target>`, plus the
compose file's SHA-256 for an app whose repo keeps its compose. The registry token and actor go on stdin,
never in argv. The server's host keys are pinned in this repo (`known_hosts`), so the job never trusts a
host key on first use. Everything else (which image, which migration, whether this key may touch
`<target>` at all) is decided on the server, which refuses anything but that one line.

## Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 30        # room for the gate to wait behind a running deploy
    permissions:
      contents: read
      packages: write          # the run's token is also what the server pulls the image with
    concurrency:
      group: deploy-${{ github.ref }}
      cancel-in-progress: false
    steps:
      # ... build and push the image ...
      - uses: tayl0r/vps-deploy@<commit SHA of the latest release> # vX.Y.Z
        with:
          key: ${{ secrets.VPS_DEPLOY_KEY }}
          user: ${{ secrets.VPS_DEPLOY_USER }}
          host: ${{ secrets.VPS_HOST }}
          target: myapp-dev
          # compose: deploy/myapp-dev/docker-compose.yml   # only for an app whose repo keeps its compose
```

Pin a full commit SHA, with the release tag in a comment, never a movable tag. Bump the pin only after
reading the diff since your current one: this action runs with your deploy key.

## Inputs

| Input | Required | Meaning |
|---|---|---|
| `key` | yes | The app's deploy key (an SSH private key, from a secret) |
| `user` | yes | The app's deploy account on the server (from a secret) |
| `host` | yes | The server's address (from a secret) |
| `target` | yes | The deployment to update: `<app>` (prod) or `<app>-dev` |
| `compose` | no | Path to the repo's compose for this deployment; its SHA-256 is sent so the server can refuse a deploy when its own copy differs. Required for an app whose repo keeps its compose |
| `token` | no | Registry token the server pulls with (default: the run's `github.token`) |
| `actor` | no | Registry user (default: `github.actor`) |

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | Deployed |
| 1 | The deploy failed on the server; its output above names the log kept there |
| 2 | The deploy gate refused the command: wrong target, or a missing compose checksum |
| 3 | Compose drift: the server's compose differs from the repo's. Its admin installs the repo's copy, then the deploy is re-run |
| 75 | Another deploy of the same deployment ran for more than 10 minutes |
| 255 | SSH failed: connection, host key or deploy key |

Each failure also prints one `::error` annotation saying which of these it was. A started deploy finishes
on the server even if the job is cancelled.

## The server side

The deploy gate, its accounts and its logs live in a private infrastructure repo. Deploy keys are issued
by the server's admin; nobody sets the secrets above by hand.
