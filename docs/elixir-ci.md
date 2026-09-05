# Elixir CI (`elixir-ci.yml`)

Independent jobs, one per gate, so a ruleset can require each and one red gate
never hides another's verdict. No secrets are accepted, so a consumer can pin
it by tag without trusting this repo with anything.

| Job | Command | Off switch |
|---|---|---|
| `format` | `mix format --check-formatted` | — |
| `compile` | `mix compile --warnings-as-errors --force` | — |
| `deps` | `mix deps.unlock --check-unused`, `mix hex.audit`, `mix deps.audit` | `check-unused-deps`, `audit`, `audit-blocking` |
| `credo` | `mix credo --strict` | `credo`, `credo-args` |
| `sobelow` | `mix sobelow --exit` (per `apps/*` when `umbrella`) | `sobelow` |
| `xref` | `mix xref graph --format cycles --label compile-connected --fail-above 0` | `xref-fail-above: -1` |
| `test` | `mix test --warnings-as-errors [--cover]`, optional Postgres service | `postgres`, `coverage`, `test-args` |
| `dialyzer` | `mix dialyzer --plt` on PLT miss, then `mix dialyzer --format github` | `dialyzer` |

## Consumer prerequisites

- `.tool-versions` at the repo root with exact `erlang` and `elixir` lines
  (or pass `otp-version` / `elixir-version`). The version is read from one
  place and used for the toolchain, the deps cache key and the PLT key.
- Dev/test deps: `credo`, `dialyxir`, `sobelow`, `mix_audit`. In an umbrella
  leave `runtime: false` **off** `mix_audit` or `deps.audit` cannot load its
  yaml dependency.
- For dialyzer, `mix.exs` must point the PLT at `plt-path` (default
  `priv/plts`): `dialyzer: [plt_core_path: "priv/plts", plt_local_path: "priv/plts"]`.
- Credo/dialyzer/sobelow/xref run under `lint-mix-env` (default `dev`), the
  tests under `mix-env` (default `test`). Keep them stable: the PLT and the
  deps cache are keyed per env.

## Status-check contexts

A reusable workflow's jobs appear as `<caller job> / <job>`. With the caller
in `templates/callers/elixir-ci.yml` the contexts are `ci / format`,
`ci / test`, `ci / dialyzer`, and so on. Renaming the caller job or a job here
renames the context and orphans any ruleset that requires it, which blocks
every merge until the ruleset is edited. Treat job ids as public API.

## How the composite action is fetched

Reusable workflows cannot use `./.github/actions/...` (the checkout is the
caller's repo). Each job checks out **this** repo at `job.workflow_sha`, the
exact commit the caller pinned, into `./.tooling` and uses the action from
there. Nothing floats past the caller's pin.

## Postgres

`postgres: true` starts a service container and exports `DATABASE_URL`,
`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`. Apps that read other
names (HackTUI uses `HACKTUI_DB_*`) map them with `test-env`:

```yaml
test-env: |
  HACKTUI_DB_HOST=localhost
  HACKTUI_DB_USER=postgres
```

## Dependabot

Copy `templates/github/dependabot.mix.yml`. Hex has no advisory feed for
Dependabot, so `mix deps.audit` in the `deps` job is the CVE source.

**Repos with a commit-attestation gate** (HackTUI's `Reviewed-diff` trailer):
Dependabot commits carry no trailer and will fail that gate. Decide up front
whether the gate exempts GitHub-verified bot authors; do not enable Dependabot
first and discover it in the PR list.
