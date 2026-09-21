# ECS Fargate deploys

## Pipeline shape

```
PR ──elixir-ci──▶ merge to main ──oci-build-push──▶ <acct>.dkr.ecr.us-east-1.amazonaws.com/myapp@sha256:…
                                        │
                        ecs-deploy (staging) ── environment: staging
                                        │
                        ecs-deploy (prod)    ── environment: production, required reviewer
```

The image is built **once** in Actions and pushed to ECR over OIDC; the same
digest goes to staging then prod. Both jobs use `AWS_GITHUB_ACTIONS_ROLE_ARN`
as an environment secret, so the role is scoped to the environment the job
runs under.

## Why ECS

- App Runner has been closed to new AWS customers since 2026-04-30.
- Lambda Function URLs cannot carry WebSockets, so a LiveView app has no
  Lambda path without API Gateway WebSocket plumbing that Phoenix does not
  speak.
- ECS Fargate runs a plain OCI image behind an ALB with WebSockets, sticky
  sessions and long-lived connections working as they do anywhere else.

## Ownership model

| Owns | What |
|---|---|
| Terraform (`ecs-fargate-service` module in aws-deployment-tooling) | cluster, service, ALB/target group, security groups, IAM roles, log group, and the task definition's **shape**: cpu/memory, ports, env, `secrets` from SSM, `logConfiguration`, ECS Exec |
| CI (`ecs-deploy.yml`) | the **image** only |

`ecs-deploy.yml` reads the service's current task definition, registers a
new revision with `containerDefinitions[container-name].image` replaced and
every read-only key (`taskDefinitionArn`, `revision`, `status`, …) dropped,
then `update-service --task-definition <new>`. Terraform must
`ignore_changes = [task_definition]` on the service, or the next apply
re-points it at Terraform's revision (the module does this). A change to the
shape is a Terraform apply, which registers its own revision; the next CI
deploy inherits it because it always starts from whatever the service runs.

## Rollback

Every run's step summary prints the previous revision and the command:

```bash
aws ecs update-service --cluster myapp --service myapp \
  --task-definition arn:aws:ecs:us-east-1:123456789012:task-definition/myapp:41
```

Old revisions stay registered, so rollback is a re-point, never a rebuild.
With the module's deployment circuit breaker on, a rollout whose tasks keep
failing health checks is rolled back by ECS itself; the workflow sees
`rolloutState == FAILED` (or the PRIMARY deployment no longer at the new
revision) and fails with the same hint. `wait-timeout-minutes` (default 15)
bounds the poll — the workflow polls `describe-services` itself because
`aws ecs wait services-stable` gives up after a fixed 10 minutes.

## Pre-deploy migration task

`pre-deploy-command: /app/bin/migrate` runs a one-off task from the **new**
revision before the service is touched — the ECS equivalent of Fly's
`release_command`. It uses the service's own subnets and security groups
(read from `describe-services`), the same launch type or capacity-provider
strategy, and a `containerOverrides[].command` override, so the migration
sees exactly the env and secrets the app will. The workflow waits for the
task to stop, tails the last 50 lines of its awslogs stream
(`<awslogs-stream-prefix>/<container>/<task id>`) and aborts the deploy if
the container exit code is not 0. Migrations must be compatible with the
still-running release, same as on Fly.

## ECS Exec

The module enables `enable_execute_command`; the CI role does not need it.
From a laptop with SSM Session Manager plugin installed:

```bash
task=$(aws ecs list-tasks --cluster myapp --service-name myapp --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster myapp --task "$task" --container app \
  --interactive --command "/app/bin/myapp remote"
```

`bin/myapp remote` is an IEx shell on the running node; `/bin/sh` works too.

## Network and cost posture

Tasks run in **public subnets with a public IP and no NAT gateway**. A NAT
gateway is $32/mo + data before a single task runs, which is more than the
task; a public IPv4 on the task is $3.65/mo. The task's security group only
admits the ALB's, so "public subnet" does not mean reachable — the ENI just
has a route to ECR, SSM and CloudWatch without NAT or VPC endpoints.

| Item | $/mo |
|---|---|
| Fargate ARM, 0.25 vCPU / 0.5 GB, one task | 7.2 (2.2 on Fargate Spot) |
| ALB | 16.4 + LCU |
| Public IPv4 × 3 (task + 2 ALB AZs) | 10.95 |
| CloudWatch logs, ECR storage | ~1 |
| **Floor** | **≈ 30–35** |

RDS is extra; the module assumes a `DATABASE_URL` in SSM pointing at
whatever you run. If the floor matters more than WebSockets, the fly.io path
in [`fly-and-cloudflare.md`](fly-and-cloudflare.md) is ~$6/mo.

## Caller

See [`templates/callers/ecs-deploy.yml`](../templates/callers/ecs-deploy.yml).
The CI role needs `ecr:*` push on the repository, `ecs:Describe*`,
`ecs:RegisterTaskDefinition`, `ecs:UpdateService`, `ecs:RunTask`,
`iam:PassRole` on the task and execution roles, and `logs:GetLogEvents` on
the log group.
