# CLAUDE.md — Persistent project instructions

## Project context
Technical assessment for **Deuna!**, a high-volume fintech platform on AWS with
a microservices architecture. The platform processes monetary transactions
(payments, transfers, withdrawals, top-ups) and non-monetary transactions
(onboarding, profile updates, balance inquiries). Existing infrastructure
includes ECS, Aurora PostgreSQL, S3, Lambda, API Gateway, SQS and an external
observability platform that ingests CloudWatch Logs.

## Assessment objectives
The assessment has four tasks:
1. ECS microservices scaling monitoring — *design completed (Phase 2)* → `docs/01-ecs-scaling-monitoring.md`.
2. Transaction-level cost allocation — *design completed (Phase 2)* → `docs/02-transaction-cost-allocation.md`.
3. **Infrastructure as Code with Terraform — implemented (Phase 1)** → `docs/03-terraform-architecture.md`.
4. Production incident management — *runbook completed (Phase 3)* → `docs/04-production-incident.md`.

**Current phase: Phase 3 completed — all four tasks covered.** Phase 1 implemented
Task 3 + the dev environment; Phase 2 delivered design docs for Tasks 1 and 2;
Phase 3 delivered the Task 4 incident runbook. Tasks 1, 2 and 4 are design/runbook
documentation — do not claim deployed/implemented systems. Do not start the final
delivery or PDF generation phase unless explicitly requested.

## Repository architecture
```
terraform/
  bootstrap/              # Remote state bucket + state KMS key (local state)
  modules/
    kms/                  # Workload customer-managed key + policy
    s3/                   # Secure financial-data bucket
    aurora/               # Aurora PostgreSQL cluster (uses existing VPC/subnets)
    secrets-manager/      # Resource policy for the RDS-managed secret
  environments/
    dev/                  # Dev root (single small instance)
    prod/                 # Prod root (writer + reader, stricter protection)
docs/                     # Architecture doc + Mermaid diagrams
Dockerfile, docker-compose.yml, Makefile   # Dev & validation environment
.github/workflows/        # CI validation (no deploy)
```

## Technical decisions
- Native AWS capabilities preferred over custom code: RDS-managed master user
  password (no Lambda rotation, no `random_password`), S3 Bucket Keys, native
  S3 state locking (`use_lockfile`), Enhanced Monitoring, Database Insights.
- One workload KMS key shared by S3, Aurora, the managed secret and CloudWatch
  Logs (assessment requirement); trade-offs documented in the architecture doc.
- No DynamoDB state locking (deprecated for new implementations).

## Docker development workflow
Only host dependencies: Docker (with Compose), Git, Make.
```
make setup   # build the tooling image + show versions
make check   # fmt-check + init(-backend=false) + validate + tflint + checkov
make shell   # interactive container
```
All tooling runs inside the pinned container; nothing is installed on the host.

## Coding conventions
- Code, identifiers, filenames and comments in **English**.
- Documentation and README in **Spanish** (technical terms/resource names stay
  in English where appropriate).
- Typed variables, input validation where useful, meaningful outputs.
- No unnecessary third-party Terraform modules or abstractions.

## Security requirements
Least privilege, defense in depth, encryption at rest and in transit, private
network access, separation of duties, environment isolation, secure credential
management, auditability, protection against accidental destruction, cost-aware
controls. Mandatory security controls stay enabled in both dev and prod.

## Execution restrictions (permanent rules)
- Do not deploy AWS resources without explicit authorization. Never run
  `terraform apply`. Never request AWS credentials.
- Do not expose credentials. Do not create plaintext secret-version resources.
- Do not invent AWS capabilities, Terraform attributes or validation results.
- Avoid unnecessary testing and unrelated refactoring.
- Prefer native AWS capabilities.
- Keep documentation synchronized with implementation.
- Read existing project files before making changes.
- Do not repeat completed work.
- Maintain `WORKLOG.md` after each implementation phase.
- Do not push to a remote Git repository.

## Agile methodology
Work in focused increments: implement, run one focused validation pass, fix
genuine issues, revalidate only affected components, then report. Document
assumptions instead of inventing facts.
