# Arquitectura Terraform — Tarea 3 (Deuna! AWS Cloud Challenge)

> Documento técnico de la Fase 1. Describe la Infraestructura como Código (IaC)
> implementada para la Tarea 3. **No se ha desplegado ningún recurso en AWS.**

## 1. Resumen de la arquitectura

La solución aprovisiona, de forma reproducible y modular, los componentes de
datos de una plataforma fintech:

- Una **clave KMS gestionada por el cliente (CMK)** simétrica para cifrado en
  reposo de toda la carga de trabajo.
- Un **bucket S3 seguro** para datos financieros.
- Un **clúster Aurora PostgreSQL** en red privada, cifrado y monitorizado.
- Un **secreto de Secrets Manager** con las credenciales de `pgadmin`,
  gestionado y rotado de forma nativa por RDS.

Se consume una **VPC y subredes privadas existentes** (entradas del módulo); no
se crea red, NAT Gateway, bastión ni infraestructura de aplicación. El estado
remoto se gestiona en un bucket S3 dedicado con bloqueo nativo de S3.

Diagrama: [`diagrams/01-workload-architecture.mmd`](diagrams/01-workload-architecture.mmd).

## 2. Responsabilidades de los módulos

| Módulo | Responsabilidad | No hace |
|---|---|---|
| `kms` | CMK simétrica, rotación, alias y política de clave de mínimo privilegio | No cifra recursos por sí mismo |
| `s3` | Bucket cifrado SSE-KMS, versionado, lifecycle, política de bucket | No crea claves KMS |
| `aurora` | Clúster Aurora, subnet group, security group, parámetros, logs, monitoring | No crea VPC/subredes/bastión |
| `secrets-manager` | Política de recurso restringida sobre el secreto gestionado por RDS | No crea el secreto ni rotación custom |

Los *roots* `environments/dev` y `environments/prod` componen los módulos y
aportan la configuración específica del entorno.

## 3. Relaciones entre recursos

```
kms.key_arn ──► s3 (SSE-KMS)
            ├─► aurora (storage_encrypted, Performance Insights, log group)
            ├─► aurora (master_user_secret_kms_key_id) ──► secreto RDS
            └─► CloudWatch Logs (log group del clúster)

aurora.master_user_secret_arn ──► secrets-manager (política de recurso)
```

El orden de dependencias evita ciclos: la CMK se crea primero; Aurora y S3 la
consumen; el secreto lo crea RDS al crear el clúster; el módulo
`secrets-manager` aplica la política sobre ese secreto ya existente.

## 4. Fronteras de seguridad

Diagrama: [`diagrams/03-security-boundaries.mmd`](diagrams/03-security-boundaries.mmd).

- **Separación de funciones**: administradores de clave (gestión) vs.
  consumidores (operaciones criptográficas) vs. DBAs (lectura del secreto).
- **Red privada**: Aurora sin IP pública, sin acceso público, ingress 5432 solo
  desde security groups aprobados.
- **Cifrado en tránsito**: `rds.force_ssl=1` en Aurora y denegación de TLS < 1.2
  y de transporte inseguro en las políticas de bucket.
- **Cifrado en reposo**: CMK en S3, almacenamiento Aurora, secreto y logs.
- **Aislamiento de entornos**: configuraciones y estado remoto independientes.

## 5. Diseño de la política de clave KMS

La política (en `modules/kms/main.tf`) sigue mínimo privilegio con estas
sentencias:

1. **EnableIAMPermissions** — otorga `kms:*` al *root* de la cuenta. Es el
   mecanismo recomendado por AWS contra el bloqueo (*lockout*): delega el
   control de acceso en las políticas de IAM y mantiene la clave administrable y
   recuperable. No es un permiso excesivo sino la salvaguarda de administración
   y recuperación controlada.
2. **KeyAdministration** — acciones administrativas (crear, describir,
   habilitar, programar/cancelar borrado, etiquetar…) **sin** `Encrypt`/`Decrypt`.
   Hace cumplir la separación entre administración y uso.
3. **KeyUsage** — operaciones criptográficas para los roles consumidores,
   restringidas con `kms:ViaService` (solo `rds`, `s3`, `secretsmanager` de la
   región) y `kms:CallerAccount` (solo esta cuenta).
4. **AllowServiceGrants** — `kms:CreateGrant/ListGrants/RevokeGrant` solo cuando
   `kms:GrantIsForAWSResource = true`. Así RDS y Secrets Manager obtienen acceso
   mediante *grants* gestionados por AWS, sin otorgar creación de *grants*
   arbitrarios.
5. **AllowCloudWatchLogs** — permite al *service principal* de CloudWatch Logs
   cifrar el grupo de logs, acotado por el contexto de cifrado
   (`kms:EncryptionContext:aws:logs:arn`).

**Límites administrativos vs. de uso**: los administradores no pueden cifrar ni
descifrar; los consumidores no pueden administrar la clave. Los *grants* de AWS
se restringen a recursos AWS (`GrantIsForAWSResource`).

### Implicaciones de compartir una CMK entre servicios
El *assessment* exige **una** CMK de carga de trabajo para todos los servicios.
Esto simplifica la gestión y reduce coste, pero:
- Amplía el radio de impacto: rotar, deshabilitar o programar el borrado de la
  clave afecta a S3, Aurora, el secreto y los logs a la vez.
- Dificulta el aislamiento criptográfico por servicio y la segregación de
  auditoría de uso por dominio.

En un entorno financiero real serían preferibles **claves independientes por
servicio** (una para RDS, otra para S3, otra para Secrets Manager) para limitar
el radio de impacto, permitir políticas y rotaciones diferenciadas y una
trazabilidad de uso más granular. Aquí se documenta la decisión y se mantiene la
clave única por requisito explícito.

## 6. Protección y lifecycle de S3

- **Cifrado**: SSE-KMS con la CMK + **S3 Bucket Keys** (reduce llamadas y coste
  de KMS). La configuración de cifrado por defecto del bucket aplica cuando la
  petición no indica cabecera de cifrado.
- **Política de bucket**:
  - `DenyInsecureTransport` (sin TLS) y `DenyOutdatedTLS` (`s3:TlsVersion < 1.2`).
  - `DenyIncorrectEncryptionAlgorithm`: rechaza subidas que pidan explícitamente
    un algoritmo distinto de `aws:kms`.
  - `DenyUnauthorizedKmsKey`: rechaza subidas que pidan explícitamente otra clave
    KMS. El par `StringNotEquals` + `Null=false` **solo** deniega cuando la
    cabecera está presente y es incorrecta, permitiendo las peticiones que se
    apoyan en el cifrado por defecto del bucket.
- **Autorización basada en identidad vs. recurso**: el acceso se concede
  mediante políticas de identidad IAM de mínimo privilegio; la política de
  recurso solo aplica barreras de denegación (transporte/cifrado) y no abre
  accesos. Acceso público bloqueado en las cuatro opciones; ACLs deshabilitadas
  (`BucketOwnerEnforced`).
- **Lifecycle y coste**: transición a `STANDARD_IA` y `GLACIER`, expiración y
  transición de versiones no actuales, y limpieza de *multipart uploads*
  incompletos. `force_destroy=false` protege los datos.

### Monitorización de accesos
Los eventos de acceso de datos (`GetObject`/`PutObject`) pueden auditarse con
**CloudTrail data events** para S3; los eventos de gestión y el uso de KMS con
CloudTrail estándar. No se habilita aquí para no activar servicios de pago no
solicitados (ver §16 de la consigna). 

### Cuándo usar S3 Object Lock
Object Lock (WORM) es apropiado ante requisitos legales/regulatorios de
retención inmutable (p. ej. normativa financiera de conservación). **No se
habilita** porque exige decidirse en la creación del bucket, impone retención
inmutable y no hay un requisito de negocio/compliance explícito de Deuna!. Se
documenta como recomendación condicionada.

## 7. Red de Aurora

- VPC y subredes privadas **existentes** como entradas (`vpc_id`,
  `private_subnet_ids`).
- `aws_db_subnet_group` sobre al menos dos AZ.
- Security group dedicado con ingress 5432 **solo** desde los security groups
  aprobados (sin CIDR abiertos). Sin IP pública ni `publicly_accessible`.

**Prerrequisitos de red** (deben existir previamente): una VPC, subredes
privadas en ≥2 AZ con enrutamiento a los endpoints de servicio necesarios (KMS,
Secrets Manager, logs, monitoring) vía NAT o *VPC endpoints*, y los security
groups de aplicación/administración que se referencian.

## 8. Alta disponibilidad de Aurora

- **Producción**: 1 *writer* + ≥1 *reader*; Aurora distribuye instancias entre
  AZ automáticamente; `promotion_tier` define la prioridad de *failover*
  (instancia 1 = *writer* preferido). `deletion_protection=true`.
- **Desarrollo**: 1 instancia por defecto, clase más económica.

> Una configuración de **una sola instancia** (dev) **no** ofrece la misma
> disponibilidad de cómputo que un clúster multi-instancia (prod): ante fallo de
> la instancia o de su AZ no hay *failover* inmediato a una réplica. El
> almacenamiento de Aurora sí es multi-AZ, pero el cómputo no es redundante.

## 9. Estrategia de backup y recuperación

- Backups automáticos habilitados; retención configurable (dev 7 días, prod 14).
- Ventanas de backup y mantenimiento configurables.
- **Point-in-time recovery** soportado mediante los backups automáticos.
- Producción: `skip_final_snapshot=false`, con `final_snapshot_identifier` que
  incluye un sufijo aleatorio (`random_id`) para evitar colisiones de nombre.

> La retención de backups es una **suposición operativa propuesta**, no un
> requisito verificado de Deuna!.

## 10. Monitorización de base de datos

- **Enhanced Monitoring** habilitado con rol IAM dedicado de mínimo privilegio
  (política gestionada `AmazonRDSEnhancedMonitoringRole`, *trust* a
  `monitoring.rds.amazonaws.com`); intervalo configurable (dev 60s, prod 15s).
- **Logs PostgreSQL** exportados a CloudWatch Logs; el grupo de logs se crea
  explícitamente con retención gestionada y cifrado con la CMK.
- **CloudWatch Database Insights** en modo configurable:
  - **standard** (por defecto, consciente de coste): Performance Insights con
    retención gratuita de 7 días.
  - **advanced**: 15 meses de retención; requiere `performance_insights_enabled`
    y retención de 465 días (mayor coste). Un bloque `check` valida esta
    coherencia.

> Diferencia estándar vs. avanzado: *standard* cubre las métricas y el panel de
> Database Insights con retención corta y sin coste adicional de PI; *advanced*
> añade retención larga y análisis extendido, con coste. Se prefiere *standard*
> salvo necesidad explícita.

## 11. Rotación del secreto gestionado

- **Propiedad y ciclo de vida**: el secreto lo crea y posee **RDS** vía
  `manage_master_user_password=true`; se cifra con la CM
  (`master_user_secret_kms_key_id`). Terraform nunca crea el secreto ni su valor.
- **Rotación automática nativa de RDS**: la rotación la gestiona RDS/Secrets
  Manager. El **programa por defecto** del secreto de usuario maestro gestionado
  es de aproximadamente **7 días**. No se implementa función Lambda de rotación
  custom ni un segundo secreto.
- **Cómo recuperan credenciales los consumidores autorizados**: vía
  `secretsmanager:GetSecretValue` sobre el ARN del secreto (referencia expuesta
  en outputs), con permiso IAM y acceso a la CMK.
- **Permisos IAM/KMS necesarios**: `GetSecretValue`/`DescribeSecret` en el
  secreto y `kms:Decrypt` (vía `secretsmanager`) sobre la CMK.
- **Sin exposición en el estado**: al no leer el valor con *data sources* ni
  crear `aws_secretsmanager_secret_version`, el valor no entra en el estado de
  Terraform. (Ver §17: un valor marcado como `sensitive` no queda excluido del
  estado por sí mismo; por eso directamente no se maneja el valor.)
- **AWS-managed vs. custom rotation**: aquí se usa **exclusivamente** la rotación
  gestionada por AWS (sin Lambda propia). La política de recurso solo contiene
  sentencias `Allow` y `block_public_policy=true`, evitando cualquier `Deny` o
  condición que pudiera impedir la rotación legítima.
- **Cómo gestionan los clientes administrativos los cambios de credencial**:
  deben resolver el secreto en cada conexión (no cachear la contraseña) para
  tolerar la rotación.

> **`pgadmin` no debe ser usado por los microservicios de aplicación.** Es la
> identidad maestra administrativa. Las aplicaciones deben usar **usuarios de BD
> dedicados y restringidos** (con privilegios mínimos por servicio), creados y
> gestionados aparte, nunca la credencial maestra.

## 12. Permisos IAM

- Rol de Enhanced Monitoring con *trust policy* a `monitoring.rds.amazonaws.com`
  y política gestionada de solo monitorización.
- La política de clave KMS separa administración y uso (ver §5).
- La política del secreto restringe lectura a identidades autorizadas.
- Las identidades de aplicación/administración (ARNs) son parámetros
  (*placeholders* en los ejemplos); no se crean roles de aplicación aquí.

## 13. Gestión del estado remoto

Diagrama: [`diagrams/02-remote-state-workflow.mmd`](diagrams/02-remote-state-workflow.mmd).

- `bootstrap/` crea: bucket de estado (versionado, TLS-only, acceso público
  bloqueado, `prevent_destroy=true`, ownership forzado) y una **KMS dedicada**
  para el estado (separada de la CMK de carga) con rotación.
- El *bootstrap* usa **estado local** por diseño (crea el propio bucket de
  estado; aún no existe backend remoto).
- Los entornos usan backend S3 con **bloqueo nativo** `use_lockfile = true`
  (Terraform ≥ 1.11), sin DynamoDB (mecanismo deprecado para nuevas
  implementaciones).
- Claves de estado separadas: `env/dev/terraform.tfstate` y
  `env/prod/terraform.tfstate`.

**Procedimiento** (en una cuenta AWS autorizada; fuera del alcance de esta fase):
1. `cd terraform/bootstrap && terraform init && terraform apply` (estado local).
2. Tomar los outputs (`state_bucket_name`, `state_kms_key_arn`).
3. En cada entorno, copiar `backend.hcl.example` a `backend.hcl` con esos valores
   y `terraform init -backend-config=backend.hcl`.
4. (Opcional) migrar el estado del *bootstrap* al bucket añadiendo un bloque
   `backend "s3"` y re-ejecutando `init`.
5. El bloqueo nativo evita cambios concurrentes: cada `plan/apply` crea un
   *lock file* en S3 que impide ejecuciones simultáneas.
6. Las identidades CI/CD acceden al backend mediante OIDC y un rol de corta
   duración con permisos sobre el bucket/clave y su prefijo de estado.
7. El acceso a estado de producción se aísla del de desarrollo mediante políticas
   IAM acotadas al prefijo `env/prod/*` (solo el rol de prod) frente a
   `env/dev/*`.

**Recuperación del estado**: el versionado de S3 permite restaurar una versión
anterior del objeto de estado si se corrompe o borra accidentalmente.

## 14. Aislamiento de entornos

Roots `dev` y `prod` independientes, con variables, outputs, backend y clave de
estado propios. Los controles de seguridad obligatorios permanecen activos en
ambos; solo varían capacidad, retención y protecciones.

## 15. Dev vs. prod — diferencias y coste

| Parámetro | Dev | Prod |
|---|---|---|
| Nº de instancias de BD | 1 | 2 (writer + reader) |
| Clase de instancia | `db.t4g.medium` | `db.r6g.large` |
| Retención de backups | 7 días | 14 días |
| Intervalo Enhanced Monitoring | 60 s | 15 s |
| Database Insights | standard | standard (opción advanced) |
| Retención de logs (CloudWatch) | 30 días | 90 días |
| Protección de borrado | off | on |
| Snapshot final | omitido | requerido |
| Retención de versiones S3 | 90 días | 365 días |
| Implicación de coste | mínima | mayor cómputo, retención y monitorización |

## 16. Estrategia de escaneo de seguridad

- **TFLint**: reglas Terraform *recommended* + *ruleset* AWS (0.50.0), aplicado a
  los tres *roots* de forma recursiva.
- **Checkov**: escaneo de las fuentes Terraform (`terraform/`), excluyendo
  `.terraform/`. Sin *soft-fail* ni *skip* general. Las excepciones legítimas se
  declaran **inline** con `# checkov:skip=<ID>:<motivo>` y se justifican.
- No se modifican controles de seguridad solo para obtener un informe limpio.
- El cumplimiento de PCI DSS / ISO 27001 / SOC 2 **no** se infiere de pasar los
  escáneres.

## 17. Suposiciones explícitas

- Región `us-east-1` es un **ejemplo configurable**, no la región real de Deuna!.
- Account IDs, VPC, subredes, ARNs de roles y security groups son
  **placeholders**.
- Versión de motor Aurora `16.6` por defecto: verificar disponibilidad con
  `aws rds describe-db-engine-versions`.
- Retenciones de backup/logs/versiones son suposiciones operativas propuestas.
- Un valor `sensitive` **no** queda excluido del estado por el solo hecho de
  marcarse así; por eso no se maneja el valor del secreto en Terraform.

## 18. Limitaciones conocidas

- Sin `terraform plan` real contra AWS (sin credenciales ni despliegue): algunas
  validaciones de tiempo de ejecución (disponibilidad de versión de motor,
  resolución de ARNs, comportamiento exacto de la rotación y de la política de
  recurso sobre el secreto gestionado) requieren una cuenta AWS autorizada.
- La política de recurso sobre el secreto gestionado por RDS debe verificarse en
  vivo para confirmar que RDS no la sustituye.
- `prevent_destroy` no admite expresión por variable; para la CMK de carga la
  protección se basa en la ventana de borrado (30 días en prod) y se recomienda
  `prevent_destroy` explícito en producción.

## 19. Recomendaciones para un entorno de producción real

- Claves KMS independientes por servicio (ver §5).
- CloudTrail (incl. *data events* de S3), AWS Config, GuardDuty, Security Hub y
  *logging* de seguridad centralizado, cuando exista el mandato y presupuesto.
- Usuarios de BD dedicados por microservicio; `pgadmin` solo administrativo.
- VPC endpoints para KMS/Secrets Manager/Logs para evitar salida a Internet.
- Pipeline de despliegue con OIDC, aprobación manual de producción y entornos
  protegidos (ver README §despliegue).
- `prevent_destroy` explícito en recursos críticos de producción.

## 20. Trazabilidad de requisitos (Tarea 3)

| Requisito | Implementación |
|---|---|
| CMK simétrica | `modules/kms` `aws_kms_key` (`SYMMETRIC_DEFAULT`) |
| Rotación automática de clave | `enable_key_rotation = true` |
| Política de clave de mínimo privilegio | `data.aws_iam_policy_document.key` (5 sentencias) |
| Separar administradores de consumidores | sentencias `KeyAdministration` / `KeyUsage` |
| `kms:ViaService` / `CallerAccount` / `GrantIsForAWSResource` | condiciones en `KeyUsage` y `AllowServiceGrants` |
| Alias KMS | `aws_kms_alias` |
| Ventana de borrado configurable | `deletion_window_in_days` |
| S3 SSE-KMS + Bucket Keys | `aws_s3_bucket_server_side_encryption_configuration` |
| Versionado S3 | `aws_s3_bucket_versioning` |
| Public access block (4) | `aws_s3_bucket_public_access_block` |
| BucketOwnerEnforced / ACLs off | `aws_s3_bucket_ownership_controls` |
| Deny transporte inseguro / TLS mínima | `aws_s3_bucket_policy` |
| Rechazo de cifrado/clave no autorizados | sentencias `DenyIncorrectEncryptionAlgorithm` / `DenyUnauthorizedKmsKey` |
| Lifecycle / versiones no actuales / multipart | `aws_s3_bucket_lifecycle_configuration` |
| `force_destroy=false` | variable `force_destroy` (default false) |
| VPC/subredes existentes como input | variables `vpc_id`, `subnet_ids` |
| Subnet group ≥ 2 AZ | `aws_db_subnet_group` + validación |
| SG dedicado, 5432 restringido | `aws_security_group` + `aws_vpc_security_group_ingress_rule` |
| Sin IP/acceso público | `publicly_accessible = false` |
| Aurora PostgreSQL, versión/clase configurables | `aws_rds_cluster` / `aws_rds_cluster_instance` |
| Usuario maestro `pgadmin` | `master_username` (validado) |
| Cifrado de almacenamiento con CMK | `storage_encrypted`, `kms_key_id` |
| Integración nativa del secreto | `manage_master_user_password`, `master_user_secret_kms_key_id` |
| TLS forzado | `rds.force_ssl=1` (parameter group) |
| HA writer+reader / failover | `instance_count`, `promotion_tier` |
| Deletion protection / snapshot final | `deletion_protection`, `skip_final_snapshot`, `final_snapshot_identifier` |
| Backups / PITR / ventanas | `backup_retention_period`, ventanas de backup/mantenimiento |
| Enhanced Monitoring + rol | `monitoring_interval`, rol IAM dedicado |
| Logs a CloudWatch + retención | `enabled_cloudwatch_logs_exports`, `aws_cloudwatch_log_group` |
| Database Insights | `database_insights_mode`, `performance_insights_*` |
| Secreto pgadmin con KMS + rotación | secreto gestionado por RDS (nativo) |
| Política de recurso + block_public_policy | `modules/secrets-manager` |
| No `random_password`/secret_version/outputs sensibles | no implementados (por diseño) |
| Estado remoto: bucket + KMS propia | `terraform/bootstrap` |
| Bloqueo nativo S3 | `use_lockfile = true` (backend.hcl.example) |
| Claves de estado dev/prod separadas | `env/dev/*`, `env/prod/*` |
| Lock files de proveedor | `.terraform.lock.hcl` por root (linux/darwin, amd64/arm64) |
| CI de validación | `.github/workflows/terraform-validation.yml` |
