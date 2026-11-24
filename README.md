# Deuna! AWS Cloud Challenge — Fase 1 (Tarea 3: IaC con Terraform)

Implementación de Infraestructura como Código para la plataforma fintech
**Deuna!**: una clave KMS gestionada por el cliente, un bucket S3 seguro, un
clúster Aurora PostgreSQL y el secreto `pgadmin` con rotación nativa; más el
entorno de desarrollo/validación en Docker y la configuración de estado remoto.

> **Importante:** este repositorio **no despliega** recursos en AWS. Todos los
> comandos descritos realizan **validación local** (formato, `validate`, lint y
> escaneo de seguridad). No se ejecuta `terraform apply`. Los identificadores de
> cuenta, red y roles son **placeholders**.

## Visión general del assessment
El assessment de Deuna! tiene cuatro tareas: (1) monitorización de escalado de
microservicios ECS, (2) asignación de costes por transacción, (3) IaC con
Terraform y (4) gestión de incidentes.

- **Fase 1** implementó la **Tarea 3** (IaC con Terraform) y el entorno de
  desarrollo/validación.
- **Fase 2** entrega el **diseño** de la **Tarea 1** y la **Tarea 2** (documentación
  de arquitectura, no aplicaciones desplegadas).

### Documentación por tarea
| Tarea | Estado | Documento |
|---|---|---|
| Tarea 1 — Monitorización de escalado ECS | Diseño (Fase 2) | [docs/01-ecs-scaling-monitoring.md](docs/01-ecs-scaling-monitoring.md) |
| Tarea 2 — Coste por transacción | Diseño (Fase 2) | [docs/02-transaction-cost-allocation.md](docs/02-transaction-cost-allocation.md) |
| Tarea 3 — IaC Terraform | Implementada (Fase 1) | [docs/03-terraform-architecture.md](docs/03-terraform-architecture.md) |
| Tarea 4 — Gestión de incidentes | Pendiente | — |

Diagramas en [docs/diagrams/](docs/diagrams/); ejemplos (SQL/JSON) en
[docs/examples/](docs/examples/). Las Tareas 1 y 2 describen **diseños
propuestos**; no se desplegó infraestructura en la Fase 2.

## Alcance del proyecto
Se aprovisiona (como código, sin desplegar):

- **KMS**: CMK simétrica con rotación y política de mínimo privilegio.
- **S3**: bucket cifrado SSE-KMS + Bucket Keys, versionado, lifecycle, privado.
- **Aurora PostgreSQL**: red privada, cifrado con CMK, backups, monitorización.
- **Secrets Manager**: credenciales `pgadmin` gestionadas y rotadas por RDS.
- **Estado remoto**: bucket S3 + KMS dedicada con bloqueo nativo de S3.

Fuera de alcance: VPC, NAT Gateway, ECS, bastión o infraestructura de aplicación.

## Resumen de arquitectura
Detalle completo en [`docs/03-terraform-architecture.md`](docs/03-terraform-architecture.md)
y diagramas Mermaid en [`docs/diagrams/`](docs/diagrams/).

- Una **única CMK de carga de trabajo** cifra S3, el almacenamiento de Aurora,
  el secreto gestionado y los logs (requisito del assessment).
- Aurora consume **VPC y subredes privadas existentes**; sin acceso público.
- Credenciales maestras gestionadas por RDS + Secrets Manager (sin
  `random_password`, sin Lambda de rotación, sin valores en el estado).

## Estructura del repositorio
```
.
├── Dockerfile / docker-compose.yml / Makefile   # Entorno de tooling
├── .tflint.hcl / .checkov.yaml                   # Config de escaneo
├── .github/workflows/terraform-validation.yml    # CI (sin despliegue)
├── terraform/
│   ├── bootstrap/                # Estado remoto (bucket + KMS, estado local)
│   ├── modules/{kms,s3,aurora,secrets-manager}/
│   └── environments/{dev,prod}/  # Roots por entorno
└── docs/                         # Arquitectura + diagramas
```

## Prerrequisitos
Solo se necesita en el host:

- **Docker** (con Docker Compose).
- **Git**.
- **Make**.

Todo el tooling (Terraform, TFLint, Checkov, AWS CLI v2, jq) vive dentro de la
imagen Docker; no se instala nada más en el host. La imagen compila de forma
nativa para **Apple Silicon (arm64)** y **Linux AMD64**.

## Desarrollo con Docker
El servicio `terraform` de Compose se usa para comandos efímeros
(`docker compose run --rm ...`), orquestados por el `Makefile`. No se mantiene un
contenedor permanente, no se exponen puertos, no se montan credenciales y no se
usa modo privilegiado.

## Quick start
```bash
make setup
make check
```
`make setup` construye la imagen y muestra las versiones. `make check` ejecuta la
validación completa (formato, init sin backend, validate, TFLint, Checkov).
**Ninguno de estos comandos despliega recursos en AWS.**

Para una shell interactiva:
```bash
make shell
```

## Comandos de Make
| Comando | Propósito |
|---|---|
| `make help` | Muestra los comandos disponibles |
| `make setup` | Construye la imagen e inicializa el tooling |
| `make versions` | Muestra las versiones instaladas |
| `make shell` | Abre un contenedor de desarrollo interactivo |
| `make fmt` | Formatea los archivos Terraform |
| `make fmt-check` | Verifica el formato sin modificar |
| `make init` | Inicializa los roots sin backend remoto |
| `make validate` | Valida las configuraciones Terraform |
| `make lint` | Ejecuta TFLint |
| `make security` | Ejecuta el escaneo de seguridad Checkov |
| `make check` | Ejecuta todo el flujo de validación esencial |

## Inicialización de Terraform (validación local)
```bash
make init       # terraform init -backend=false en bootstrap, dev y prod
make validate   # init(-backend=false) + validate en los tres roots
```
`-backend=false` permite validar **sin** backend remoto ni credenciales AWS.

## Bootstrap del estado remoto
Procedimiento para una cuenta AWS **autorizada** (fuera del alcance de esta fase;
no ejecutar aquí):

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # editar valores reales
terraform init                                  # estado LOCAL (aún no hay backend)
terraform apply                                 # crea bucket + KMS de estado
```
Con los outputs (`state_bucket_name`, `state_kms_key_arn`) se configuran los
backends de entorno. Detalle y recuperación de estado en la doc de arquitectura
(§13).

## Configuración de entornos
```bash
cd terraform/environments/dev        # o prod
cp terraform.tfvars.example terraform.tfvars    # editar placeholders
cp backend.hcl.example backend.hcl              # valores del bootstrap
```
Diferencias dev/prod (instancias, clase, retención, monitorización, protección)
en [`docs/03-terraform-architecture.md`](docs/03-terraform-architecture.md) §15.

## Despliegue autorizado (no en esta fase)
El despliegue real requiere autorización explícita y credenciales que **no** se
solicitan aquí. Flujo recomendado para una fase futura:

```bash
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan      # revisión del plan
terraform apply tfplan          # solo con autorización explícita
```
Para el pipeline real se recomienda: integración **OIDC** de GitHub Actions con
AWS, credenciales de corta duración, roles de despliegue por entorno, revisión
del `plan`, entornos protegidos y **aprobación manual de producción**. Estas
capacidades **no** se implementan en esta fase.

## Consideraciones de seguridad
Mínimo privilegio, defensa en profundidad, cifrado en reposo y en tránsito,
acceso de red privado, separación de funciones, aislamiento de entornos, gestión
segura de credenciales, trazabilidad y protección contra destrucción accidental.
Servicios como CloudTrail, AWS Config, GuardDuty o Security Hub se **documentan**
como recomendaciones condicionadas, sin activarse para no incurrir en coste no
solicitado. Pasar los escáneres **no** implica cumplimiento de PCI DSS, ISO
27001, SOC 2 ni regulación financiera.

## Validación
```bash
make check
```
Los resultados reales de la última ejecución de validación se registran en
[`WORKLOG.md`](WORKLOG.md).

## Suposiciones y limitaciones conocidas
- Región `us-east-1` y todos los IDs son **placeholders/ejemplos**.
- No hay `terraform plan` real contra AWS; validaciones de runtime
  (disponibilidad de versión de motor, resolución de ARNs, comportamiento exacto
  de rotación y de la política del secreto) requieren una cuenta autorizada.
- Retenciones de backups/logs/versiones son suposiciones operativas propuestas,
  no requisitos verificados de Deuna!.
- Detalle en [`docs/03-terraform-architecture.md`](docs/03-terraform-architecture.md)
  §17–§19.
