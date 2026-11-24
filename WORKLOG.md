# WORKLOG

Registro de implementación. Fechas en formato absoluto.

## Fase 1 — Tarea 3 (IaC con Terraform) + entorno de desarrollo
Fecha: 2026-11-24. Estado: completada.

### Fases completadas
1. Entorno Docker de desarrollo/validación (Dockerfile multi-arch, Compose,
   Makefile).
2. Solución Terraform completa (módulos kms, s3, aurora, secrets-manager;
   bootstrap de estado; roots dev y prod).
3. Documentación (README, CLAUDE.md, arquitectura, diagramas Mermaid).
4. Pase de validación enfocado (fmt, init -backend=false, validate, TFLint,
   Checkov).
5. Corrección de incidencias reales.
6. Revalidación de los componentes afectados.

### Decisiones principales
- Imagen Docker única, Debian slim, descargas por arquitectura (amd64/arm64) con
  verificación de checksum para Terraform y TFLint; usuario no root.
- Versiones fijadas: Terraform 1.16.7, TFLint 0.66.0 (+ ruleset AWS 0.50.0),
  Checkov 3.4.6, AWS CLI v2.42.2.
- Una única CMK de carga de trabajo para S3, Aurora, secreto y logs (requisito
  explícito); se documentan los trade-offs y la alternativa de claves por
  servicio.
- Credenciales maestras nativas (RDS `manage_master_user_password`); sin
  `random_password`, sin Lambda de rotación, sin `secret_version`.
- Bloqueo de estado nativo de S3 (`use_lockfile = true`, Terraform ≥ 1.11); sin
  DynamoDB (deprecado para nuevas implementaciones).
- Database Insights en modo `standard` (consciente de coste); modo `advanced`
  documentado y validado con un bloque `check`.
- CloudWatch Logs del clúster cifrado con la CMK mediante una sentencia de
  política de clave acotada por contexto de cifrado.

### Archivos/componentes implementados
- `Dockerfile`, `docker-compose.yml`, `Makefile`, `.dockerignore`, `.gitignore`,
  `.tflint.hcl`, `.checkov.yaml`.
- `.github/workflows/terraform-validation.yml`.
- `terraform/modules/{kms,s3,aurora,secrets-manager}/`.
- `terraform/bootstrap/`.
- `terraform/environments/{dev,prod}/` (+ lock files de proveedor).
- `README.md`, `CLAUDE.md`, `docs/03-terraform-architecture.md`,
  `docs/diagrams/*.mmd`.

### Comandos de validación ejecutados
- `docker compose build terraform`
- `make versions`
- `make check` (fmt-check, init -backend=false, validate, tflint, checkov)
- `terraform providers lock` (plataformas linux/darwin, amd64/arm64)

### Resultados reales de validación
<!-- RESULTS:START -->
Ejecución de `make check` (contenedor Docker, arm64 nativo) — exit 0:

| Validación | Resultado | Detalle |
|---|---|---|
| `terraform fmt -check` | PASS | Sin diferencias de formato |
| `terraform validate` (bootstrap) | PASS | "The configuration is valid." |
| `terraform validate` (dev) | PASS | "The configuration is valid." |
| `terraform validate` (prod) | PASS | "The configuration is valid." |
| TFLint (terraform + AWS 0.50.0) | PASS | 0 issues (tras corregir 7 avisos: var sin usar + `versions.tf` en 3 módulos) |
| Checkov 3.4.6 | PASS | 138 passed, 0 failed, 24 skipped (excepciones documentadas inline) |

Versiones instaladas (imagen): Terraform 1.16.7, TFLint 0.66.0, Checkov 3.4.6,
AWS CLI 2.42.2, jq 1.6, Git 2.39.5.

Correcciones aplicadas tras el primer escaneo:
- `iam_database_authentication_enabled = true` en el clúster (CKV_AWS_162).
- `auto_minor_version_upgrade = true` en las instancias (CKV_AWS_226).
- Lifecycle mínimo (abort multipart) en el bucket de estado (CKV2_AWS_61).

Excepciones Checkov documentadas inline (`# checkov:skip=<ID>:<motivo>`):
CKV_AWS_109/111/356 (políticas de clave KMS: `*` = la propia clave, root kms:*
anti-lockout), CKV_AWS_353 (PI a nivel de clúster), CKV_AWS_139 (deletion
protection por entorno), CKV_AWS_338 (retención de logs configurable),
CKV_AWS_18 (logging vía CloudTrail), CKV_AWS_144 (CRR = DR opcional),
CKV2_AWS_62 (sin consumidores de eventos), CKV2_AWS_8 (backups nativos + PITR),
CKV2_AWS_27 (query logging podría exponer datos sensibles).
<!-- RESULTS:END -->

### Limitaciones conocidas
- Sin `terraform plan`/`apply` real contra AWS (sin credenciales ni despliegue).
- Verificaciones de runtime (versión de motor, ARNs reales, rotación efectiva,
  persistencia de la política de recurso del secreto) requieren cuenta AWS
  autorizada.
- `prevent_destroy` no admite variables; en la CMK de carga se usa ventana de
  borrado y se recomienda `prevent_destroy` explícito en prod.

### Tareas restantes del assessment (al cierre de Fase 1)
- Tarea 1 (monitorización de escalado ECS): pendiente → entregada en Fase 2.
- Tarea 2 (asignación de costes por transacción): pendiente → entregada en Fase 2.
- Tarea 4 (gestión de incidentes): pendiente.

### Estado de despliegue AWS
Ningún recurso de AWS fue desplegado ni modificado.

## Fase 2 — Tareas 1 y 2 (documentación de diseño)
Fecha: 2026-11-24. Estado: completada (sólo documentación; sin cambios de
infraestructura, Docker ni Terraform).

### Entregables
- `docs/01-ecs-scaling-monitoring.md` (Tarea 1): detección híbrida (EventBridge
  Scheduler + eventos ECS + Lambda), estados de servicio, ciclo de vida de alerta
  en DynamoDB, esquema JSON versionado, integración con observabilidad externa,
  dashboard, seguridad/coste. Diagramas `ecs-monitoring-architecture.mmd` y
  `ecs-alert-state-machine.mmd`; ejemplos `examples/ecs-alert-events.json`.
- `docs/02-transaction-cost-allocation.md` (Tarea 2): clasificación y propagación,
  matriz de cost drivers, modelo de asignación híbrido, ejemplo numérico
  reconciliado, CUR 2.0 verificado, modelo de datos, pipeline, calidad y
  gobernanza. Diagramas `transaction-cost-architecture.mmd`,
  `transaction-context-propagation.mmd`, `cost-allocation-pipeline.mmd`; SQL
  `examples/transaction-cost-allocation.sql`.
- Actualizados `README.md` y `CLAUDE.md` con el estado y los enlaces.

### Decisiones clave (Fase 2)
- No existe evento AWS de "capacidad máxima" (verificado) → reconciliación
  periódica + aceleración por eventos ECS como señal.
- El detector observa y alerta; no modifica capacidad ECS automáticamente.
- CUR 2.0 no da coste por transacción de negocio → estimación por ponderación de
  consumo; capacidad ociosa como pool separado y visible.
- Columnas CUR 2.0 verificadas en la documentación oficial antes de escribir SQL.

### Verificación (Fase 2)
- Documentos y diagramas creados; enlaces Markdown relativos verificados.
- Ejemplo numérico comprobado una vez: 800.00 = 332.00 (monetario) + 268.00 (no
  monetario) + 200.00 (ocioso/no asignado); diferencia de reconciliación 0.00.
- SQL revisado para evitar doble conteo (agregación previa, sin joins que
  multipliquen) y división por cero (`NULLIF`).
- `git diff --check` sin errores; sin cambios en archivos Terraform.
- Referencias AWS verificadas (eventos ECS, CUR 2.0, split cost allocation).
- No se reconstruyó Docker ni se reejecutó Terraform/TFLint/Checkov.

### Pendientes de revisión para la entrega final (registrados, sin modificar Fase 1)
- Revisar las 24 excepciones Checkov documentadas.
- Revisar la protección de la CMK de carga ante borrado accidental
  (`prevent_destroy` explícito en prod).
- Revisar los límites efectivos de acceso a Secrets Manager, incluidos los
  permisos IAM basados en identidad existentes.
- Verificar persistencia y rotación del secreto gestionado por RDS cuando haya un
  entorno AWS autorizado.
- Distinguir compatibilidad Docker probada en ARM64 vs. compatibilidad AMD64 por
  diseño (no ejecutada).
- Mantener la limitación explícita: no se ejecutó plan ni despliegue real de AWS.

### Tareas restantes del assessment (al cierre de Fase 2)
- Tarea 4 (gestión de incidentes): pendiente → entregada en Fase 3.

## Fase 3 — Tarea 4 (runbook de incidente de producción)
Fecha: 2026-11-24. Estado: completada (sólo documentación; sin cambios de
infraestructura, Docker ni Terraform; sin ejecución de comandos contra AWS/BD).

### Entregables
- `docs/04-production-incident.md`: runbook del incidente `payments-processor`
  (02:47, 10/10 tareas, p99 > 4 s). Modelo de severidad y activación, timeline
  T+0..T+30, secuencia diagnóstica ordenada (negocio→ECS→red→Aurora→externo→
  cambios), matriz de 10 hipótesis de causa raíz, playbooks de mitigación (ECS/
  Aurora/externo/despliegue/tráfico) sin downtime garantizado, integridad
  transaccional financiera, comunicación (técnico/producto/C-Level + cadencia),
  criterios de recuperación/cierre, postmortem sin culpables con acciones
  mapeadas y métricas (MTTD/MTTA/TTM/TTR/SLO/reconciliación), consistencia con
  Tareas 1/2/3, trazabilidad y referencias AWS.
- Diagramas `incident-diagnosis-decision-tree.mmd` (subir max de ECS condicional)
  e `incident-response-lifecycle.mmd`.
- `docs/examples/incident-diagnostics.md`: comandos AWS CLI/PostgreSQL
  representativos, read-only vs ⚠️ modificación (con preconditions/auth/efecto/
  verificación/rollback), placeholders por entorno, sin credenciales; no es script
  ejecutable.
- Actualizados `README.md` y `CLAUDE.md`.

### Decisiones clave (Fase 3)
- Causa raíz **no** asumida; decisión por evidencia (ECS vs Aurora vs externo).
- Subir el máximo de ECS es **condicional** (sólo con headroom aguas abajo);
  ejemplo sintético 10→15, preservando min y políticas; distinción max vs desired.
- Reconciliación de cambios de emergencia con Terraform tras estabilizar;
  congelar `terraform apply` durante el incidente.
- Integridad financiera: timeouts externos ambiguos → PENDING/UNKNOWN, nunca
  FAILED automático; idempotencia y reconciliación antes de reintentar.

### Verificación (Fase 3)
- Documentos y diagramas creados; enlaces Markdown relativos verificados.
- Consistencia con Tareas 1 (estados/correlationId), 2 (intentos vs txn, coste
  incremental) y 3 (Aurora privada, Database Insights, Secrets Manager, Terraform).
- Hechos conocidos preservados (02:47, 10/10, p99>4s); causa raíz marcada como
  pendiente, no confirmada.
- Nombres de métricas/comandos AWS verificados (ECS, Auto Scaling, ALB, Aurora/PI,
  CloudTrail, pg_*).
- `git diff --check` limpio; sin cambios en archivos Terraform/Docker.
- No se reconstruyó Docker ni se reejecutó validación de Fase 1.

### Ítems de revisión para la entrega final (preservados, sin resolver aún)
Checkov (24 excepciones), protección de borrado de la CMK, límites efectivos de
acceso a Secrets Manager, rotación del secreto RDS, ARM64 probado vs AMD64 por
diseño, sin plan/despliegue real de AWS, SQL ilustrativo no ejecutado en Athena,
diagramas Mermaid no renderizados.

### Estado del assessment (al cierre de Fase 3)
- Tarea 1: diseño completado (Fase 2).
- Tarea 2: diseño completado (Fase 2).
- Tarea 3: implementada y validada estáticamente (Fase 1).
- Tarea 4: runbook completado (Fase 3).
Las cuatro tareas están cubiertas. Pendiente: fase de entrega final / PDF (no
iniciada).
