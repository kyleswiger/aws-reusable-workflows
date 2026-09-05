# fly.io deploys behind Cloudflare

## Pipeline shape

```
PR ──elixir-ci──▶ merge to main ──oci-build-push──▶ ghcr.io/<repo>@sha256:…
                                        │
                        fly-deploy (staging) ── environment: staging
                                        │
                        fly-deploy (prod)    ── environment: production, required reviewer
```

The image is built **once** in Actions and the same digest goes to staging
then prod. Fly has no `releases rollback`; rollback is a re-run of the caller
with `image:` set to a previous ref (printed in every deploy's step summary)
and `strategy: immediate`.

## Tokens

Fly does not accept GitHub OIDC, so a stored token is unavoidable. Make it the
smallest one that works:

```bash
fly tokens create deploy -a my-app-staging -x 2160h   # 90 days, this app only
fly tokens create deploy -a my-app-prod    -x 2160h
fly tokens list                                        # audit; revoke the laptop's `fly auth` session
```

Store each as `FLY_API_TOKEN` in the matching **GitHub environment**, not as a
repo secret. `fly-deploy.yml` requires an `environment` input and runs under
it, so a staging token cannot reach a prod deploy, and the production
environment can require a reviewer before the job starts.

`fly-deploy.yml` receives that token. **Pin it by full commit SHA** (or vendor
a copy); a tag pin trusts every future push to this repo with your deploy
token. Dependabot's `github-actions` ecosystem keeps a SHA pin current.

## fly.toml

Start from `templates/fly/fly.phoenix.toml`, one file per environment.
Points that matter:

- `release_command = "/app/bin/migrate"` runs against the **new** image before
  any machine is replaced. Migrations must be compatible with the still-running
  release.
- `strategy = "bluegreen"` plus an `[[http_service.checks]]` block gives
  zero-downtime deploys; it needs no attached volumes.
- `min_machines_running = 1` in prod so LiveView never cold-starts.
- Secrets (`SECRET_KEY_BASE`, `DATABASE_URL`) go in `fly secrets set`, never in
  `fly.toml`. `fly secrets import --stage` sets several without a redeploy.

## Cloudflare in front

- SSL/TLS mode **Full (strict)**. Flexible causes redirect loops with
  `force_https`.
- `fly certs add example.com` prints a `_fly-ownership` TXT record; add it so
  Fly can validate through the proxy. `fly certs check example.com` to debug.
- A shared IPv4 (`fly ips allocate-v4 --shared`) is free and fine behind
  Cloudflare, which always sends SNI. Dedicated IPv4 is $2/mo and only needed
  for raw TCP/UDP.
- The client IP is in `CF-Connecting-IP`; `Fly-Client-IP` is a Cloudflare edge.
  Use the [`remote_ip`](https://hex.pm/packages/remote_ip) plug with
  `headers: ["cf-connecting-ip"]` and `proxies: ~w(cloudflare)` **before**
  anything that reads `conn.remote_ip` (rate limits, session fingerprints,
  LiveView `peer_data`). Trust it only if Cloudflare is the only path in.
- Cloudflare Free/Pro close idle WebSockets after 100 s; Phoenix's 30 s
  heartbeat is fine, do not raise it past ~90 s.

## Terraform

Terraform the Cloudflare side (provider v5: `cloudflare_dns_record`,
`cloudflare_zone_setting`), not Fly — `fly-apps/terraform-provider-fly` is
archived and Fly's own guidance is `fly.toml` in git plus `flyctl` in CI.

```hcl
resource "cloudflare_dns_record" "app" {
  zone_id = var.zone_id
  name    = "@"
  type    = "CNAME"
  content = "my-app-prod.fly.dev"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "fly_ownership" {
  zone_id = var.zone_id
  name    = "_fly-ownership"
  type    = "TXT"
  content = var.fly_ownership_token   # from `fly certs add`
  ttl     = 300
}

resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.zone_id
  setting_id = "ssl"
  value      = "strict"
}
```

## Cost (hobby Phoenix + Postgres)

| Item | $/mo |
|---|---|
| shared-cpu-1x 512 MB, one machine, `min_machines_running = 1` | 3.32 |
| unmanaged Fly Postgres, single node | ~2.2 (no Fly support) |
| Managed Postgres Basic | 38 |
| Cloudflare Free, GHCR public | 0 |

Sources: Fly docs on [GitHub Actions CD](https://fly.io/docs/launch/continuous-deployment-with-github-actions/),
[tokens](https://fly.io/docs/security/tokens/), [rollback](https://fly.io/docs/blueprints/rollback-guide/),
[seamless deployments](https://fly.io/docs/blueprints/seamless-deployments/),
[Cloudflare](https://fly.io/docs/networking/understanding-cloudflare/),
[infra without Terraform](https://fly.io/docs/blueprints/infra-automation-without-terraform/),
[pricing](https://fly.io/docs/about/pricing/).
