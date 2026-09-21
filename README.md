# aws-reusable-workflows

Reusable (`workflow_call`) GitHub Actions workflows shared across Kyle's
sites and paired projects. AWS access is OIDC-only
(`aws-actions/configure-aws-credentials`), never long-lived keys. Non-AWS
targets (fly.io) get the smallest scoped token that works, held in a GitHub
environment — see [`docs/fly-and-cloudflare.md`](docs/fly-and-cloudflare.md).

Pin by release tag (`@v1.1.0`) for workflows that take no secrets; pin by full
commit SHA for any workflow you hand a deploy token to.

## Preview environments

`preview-deploy.yml` + `preview-cleanup.yml` give every PR a **real preview
environment** — its own frontend URL *and* its own backend Lambda — on top of
the one-time
[`preview-substrate`](https://github.com/kyleswiger/aws-deployment-tooling/tree/main/terraform-modules/preview-substrate)
Terraform module. Per-PR deploys are only S3 objects and a Lambda function
(free while idle), so previews cost ~$0/month fixed and deploy in seconds to a
couple of minutes.

- Frontend: built with the PR's own API URL baked in, synced to
  `s3://<preview-bucket>/previews/pr-<N>/`, served at
  `https://pr-<N>.<preview-domain>` via the substrate's wildcard CloudFront
  distribution.
- Backend: Lambda `<name-prefix>-preview-pr-<N>` (zip or container image) with
  a public Function URL. `PREVIEW_ORIGIN` is injected into its environment so
  the app can allow the preview origin in CORS. Point its environment at a dev
  data tier and dev auth mode — never prod.
- E2E: optionally runs Playwright against the live preview URL after deploy.
- Cleanup: PR close deletes the Lambda, S3 prefix, and preview image tag; the
  substrate's S3 lifecycle rule is the backstop.

### Caller example — deploy

```yaml
# .github/workflows/preview.yml
name: PR Preview
on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  id-token: write
  contents: read
  pull-requests: write

concurrency:
  group: preview-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  preview:
    uses: kyleswiger/aws-reusable-workflows/.github/workflows/preview-deploy.yml@main
    secrets:
      AWS_GITHUB_ACTIONS_ROLE_ARN: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
    with:
      preview-domain: preview.example.com
      preview-bucket: myapp-previews-abc123
      distribution-id: E2ABCDEF123456
      name-prefix: myapp
      preview-exec-role-arn: arn:aws:iam::123456789012:role/myapp-preview-lambda-exec
      backend: zip
      backend-build-command: bash backend/scripts/build_lambda.sh
      backend-zip-path: backend/build/lambda.zip
      lambda-handler: app.handler.handler
      lambda-environment: |
        {"ENVIRONMENT": "preview", "AUTH_DEV_MODE": "true", "TABLE_NAME": "myapp-dev"}
      ui-dir: frontend
      playwright-spec: e2e/smoke.spec.ts
```

Container backends: set `backend: container`, `ecr-repository`,
`container-dockerfile`, `container-context` instead of the zip inputs (the CI
role needs ECR push on that repository — the substrate's `ci_policy_statements`
covers S3/CloudFront/Lambda/PassRole only).

Frontend-only sites: `backend: none` plus optional `static-api-url`.

### Caller example — cleanup

```yaml
# .github/workflows/preview-cleanup.yml
name: PR Preview Cleanup
on:
  pull_request:
    types: [closed]

permissions:
  id-token: write
  contents: read

jobs:
  cleanup:
    uses: kyleswiger/aws-reusable-workflows/.github/workflows/preview-cleanup.yml@main
    secrets:
      AWS_GITHUB_ACTIONS_ROLE_ARN: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
    with:
      preview-bucket: myapp-previews-abc123
      distribution-id: E2ABCDEF123456
      name-prefix: myapp
```

## Elixir / BEAM, fly.io and ECS

Language- and target-agnostic building blocks, added for Elixir projects that
deploy to fly.io or ECS Fargate. Details in [`docs/elixir-ci.md`](docs/elixir-ci.md),
[`docs/fly-and-cloudflare.md`](docs/fly-and-cloudflare.md) and
[`docs/ecs-fargate.md`](docs/ecs-fargate.md); copy-in callers under
[`templates/callers/`](templates/callers/).

| Workflow / action | Purpose | Secrets |
|---|---|---|
| `elixir-ci.yml` | format, compile -Werror, deps checks + audits, credo, sobelow, xref cycles, test (optional Postgres), dialyzer — one job each, so each can be a required check. | none |
| `oci-build-push.yml` | Build an image once → GHCR (or ECR via OIDC), BuildKit cache, SLSA provenance. Outputs the immutable `image-ref` for deploy jobs. | none for GHCR |
| `fly-deploy.yml` | `fly deploy --image` (or remote build) under a required GitHub `environment`; health probe; prints the running image for rollback. **Pin by full SHA.** | `FLY_API_TOKEN` (app-scoped deploy token, per environment) |
| `ecs-deploy.yml` | Register a new task-definition revision with only the image changed and `update-service` on an existing Fargate service (Terraform owns the shape); optional pre-deploy migration task; circuit-breaker-aware rollout wait; prints the rollback command. Requires a GitHub `environment`. | `AWS_GITHUB_ACTIONS_ROLE_ARN` (OIDC, per environment) |
| `otp-release.yml` | `mix release` per named release on a `v*` tag, boot check in a clean container, CycloneDX SBOM, provenance, attach to a **draft** GitHub Release. | none |
| `actions/setup-beam-cached` | erlef/setup-beam from `.tool-versions` + deps/_build cache + optional PLT restore. Used by the workflows above; usable from a consumer's own jobs. | — |

Templates: `templates/docker/phoenix.Dockerfile`, `templates/fly/fly.phoenix.toml`,
`templates/github/dependabot.mix.yml`. `scripts/ruleset-add-required-check.sh`
appends required checks to an **existing** ruleset by name instead of
replacing it (use this, not `apply-branch-ruleset.sh`, on a repo that already
has its own ruleset).

## Other workflows

| Workflow | Purpose |
|---|---|
| `deploy-dev-api.yml` | Rebuild + `update-function-code` a shared dev backend Lambda (for sites that keep a persistent dev stack). |
