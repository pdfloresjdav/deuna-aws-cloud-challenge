# Validación de seguridad y matriz de excepciones

> Revisión final (Fase 4) de la validación estática de la Tarea 3. Los resultados
> provienen de `make check` ejecutado en el contenedor de tooling. **No** sustituye
> a una verificación en una cuenta AWS autorizada.

## 1. Herramientas de validación
| Herramienta | Versión | Propósito |
|---|---|---|
| Terraform | 1.16.7 | `fmt`, `init -backend=false`, `validate` |
| TFLint | 0.66.0 (+ ruleset AWS 0.50.0) | Lint Terraform + reglas AWS |
| Checkov | 3.4.6 | Escaneo de seguridad IaC |

## 2. Comandos ejecutados
```bash
make check   # fmt-check + init(-backend=false) + validate (bootstrap/dev/prod) + tflint + checkov
```

## 3. Resultados reales (última ejecución, Fase 4)
| Validación | Resultado |
|---|---|
| `terraform fmt -check` | PASS |
| `terraform validate` (bootstrap/dev/prod) | PASS ×3 |
| TFLint | 0 issues |
| Checkov | **135 passed · 0 failed · 30 skipped** |

Los 30 *skipped* son **excepciones documentadas inline** (`# checkov:skip=<ID>:<motivo>`),
no comprobaciones aprobadas. No se usa *soft-fail* ni supresión general. (Totales
previos a la revisión de endurecimiento: 138/0/24; el cambio a "política de recurso
del secreto siempre creada" añadió 6 *skipped* de política de recurso en dev+prod.)

## 4. Correcciones aplicadas (vs. hallazgos genuinos)
- **Fase 1** (al primer escaneo): `iam_database_authentication_enabled` (CKV_AWS_162),
  `auto_minor_version_upgrade` (CKV_AWS_226), lifecycle del bucket de estado
  (CKV2_AWS_61) — hallazgos genuinos resueltos con cambios simples.
- **Fase 4**: `prevent_destroy = true` en la CMK de carga (protección contra borrado
  accidental vía Terraform; ver §6). No altera el conteo Checkov.
- **Endurecimiento dirigido**: enforcement de cifrado S3 reforzado (deny de `aws:kms`
  sin key id y de SSE-C; exención de *service principals* en la TLS mínima);
  descubrimiento y distribución de AZ en Aurora con *preconditions*; `prevent_destroy`
  en la KMS de estado; *trust policy* de Enhanced Monitoring con `aws:SourceAccount`/
  `aws:SourceArn`; egress de BD restringido (sin `0.0.0.0/0` por defecto); guardrails
  de producción; política de recurso del secreto **siempre creada** con ≥ 1 admin
  (ver `docs/03-terraform-architecture.md §19.b`).

## 5. Matriz de excepciones (24 *skipped* = 12 IDs sobre recursos de dev/prod/bootstrap)

| Check ID | Recurso / módulo | Justificación técnica | Impacto de seguridad potencial | Control compensatorio | Estado |
|---|---|---|---|---|---|
| CKV_AWS_109 | `kms` policy, `bootstrap` state key | Es una **política de clave KMS** (resource-based); `Resource:"*"` = la propia clave, no acceso de principal sin restricción | Bajo: malinterpretación de un wildcard de recurso | Separación admin/uso; condiciones `ViaService`+`CallerAccount` | Justificada (falso positivo de key policy) |
| CKV_AWS_111 | `kms` policy, `bootstrap` state key | Igual que 109; acciones de escritura acotadas a administradores de clave | Bajo | Mínimo privilegio por acción | Justificada |
| CKV_AWS_356 | `kms` policy, `bootstrap` state key | `Resource:"*"` en key policy refiere a la clave adjunta; no se puede acotar más | Bajo | — | Justificada |
| CKV_AWS_139 | `aurora` cluster | Deletion protection controlada por entorno (prod=true, dev=false por diseño) | Medio en dev (teardown) | prod con protección; dev efímero | Justificada (por entorno) |
| CKV2_AWS_8 | `aurora` cluster | PITR provisto por backups automáticos nativos; AWS Backup es recomendación org-level | Bajo-medio | `backup_retention_period`, PITR | Riesgo residual (recomendación diferida) |
| CKV2_AWS_27 | `aurora` cluster | *Query logging* completo (`log_statement=all`) podría capturar datos financieros sensibles en CloudWatch | Medio si se habilitara sin control | pgAudit con configuración acotada en prod (recomendado) | Riesgo residual (decisión de seguridad) |
| CKV_AWS_353 | `aurora` instance | Performance Insights configurado a nivel de **clúster** vía `database_insights_mode` (ubicación soportada) | Ninguno (control presente en el clúster) | PI + Database Insights en el clúster | Justificada (ubicación de atributo) |
| CKV_AWS_338 | `aurora` log group | Retención de logs es *trade-off* de coste, configurable (dev 30 / prod 90 días) | Bajo-medio (ventana de auditoría más corta) | Retención gestionada explícita; subir a 365 si compliance lo exige | Riesgo residual (coste vs. retención) |
| CKV_AWS_18 | `s3` bucket, `bootstrap` state bucket | *Server access logging* evita un bucket adicional con auto-log recursivo | Bajo-medio (auditoría de acceso) | **CloudTrail S3 data events** recomendado | Riesgo residual (control alternativo) |
| CKV_AWS_144 | `s3` bucket, `bootstrap` state bucket | CRR es control de **DR**; se habilita con requisito explícito | Bajo (DR, no confidencialidad) | Versionado + backups; CRR bajo requisito de DR | Riesgo residual (mejora diferida) |
| CKV2_AWS_62 | `s3` bucket, `bootstrap` state bucket | No hay flujo *event-driven* que consuma el bucket | Ninguno | — | Justificada (sin caso de uso) |
| CKV_AWS_108 | `secrets-manager` policy doc | **Política de recurso** del secreto: `*` = el propio secreto; principales acotados a admin/consumer autorizados (no es exfiltración de política de identidad) | Bajo | Principales explícitos + KMS + IAM | Justificada (falso positivo de resource policy) |
| CKV_AWS_109 | `secrets-manager` policy doc | Igual que 108; permisos limitados a principales nombrados | Bajo | — | Justificada |
| CKV_AWS_356 | `secrets-manager` policy doc | `*` en la política de recurso del secreto refiere al secreto adjunto; no se puede acotar | Bajo | — | Justificada |

**Clasificación de controles:**
- **Obligatorios (implementados)**: cifrado SSE-KMS/KMS, bloqueo de acceso público,
  TLS forzado, versionado, red privada Aurora, SG restringido, secreto gestionado,
  bloqueo de estado, cifrado de logs. (Cubiertos por los 138 *passed*.)
- **Recomendaciones dependientes de contexto**: retención de logs (338), query
  logging (27).
- **Mejoras diferidas de producción**: AWS Backup (CKV2_AWS_8), CRR (144), S3 access
  logging vía CloudTrail data events (18).
- **Riesgos residuales**: ver columna «Estado».

> **No** se declaran los *skipped* como aprobados. **No** se añaden servicios de pago
> solo para satisfacer recomendaciones opcionales del escáner (coherente con la
> consigna). Pasar los escáneres **no** implica cumplimiento PCI DSS / ISO 27001 /
> SOC 2 / regulación financiera.

## 6. Revisión de la protección de la CMK (accidental deletion)
Se añadió `lifecycle { prevent_destroy = true }` a la CMK de carga (literal; aplica a
dev y prod). **Trade-off**: el teardown de dev requiere retirar temporalmente ese
bloque en un cambio revisado. **Limitación**: `prevent_destroy` sólo protege
operaciones de **Terraform**; **no** evita un `ScheduleKeyDeletion` directo por la API
de AWS ni la eliminación del bloque de recurso del código. Controles complementarios
recomendados en producción: política IAM que **deniegue** `kms:ScheduleKeyDeletion`
salvo a roles *break-glass*, y una alarma de CloudWatch/EventBridge sobre eventos
`ScheduleKeyDeletion`. No se duplican módulos KMS para hacerlo específico por entorno.

## 7. Revisión del modelo de autorización de Secrets Manager (residual)
La política de recurso del secreto gestionado por RDS se crea **siempre** (se exige
≥ 1 principal administrativo mediante validación y *precondition*) y usa sólo
sentencias `Allow` + `block_public_policy`. **Importante y documentado**: una política *Allow-only*
**no** impide que otros principales IAM de la **misma cuenta** accedan al secreto si
sus **políticas basadas en identidad** lo permiten; `block_public_policy` sólo evita
políticas que concedan acceso **público/cross-account anónimo**, **no** es una
*allowlist* exclusiva de principales. Un *deny* exclusivo por recurso **no** se añade
porque no puede verificarse de forma segura sin un entorno AWS autorizado y podría
**romper la rotación nativa** gestionada por RDS. **Riesgo residual**: la restricción
efectiva del acceso a `pgadmin` depende de la **gobernanza IAM basada en identidad**
(mínimo privilegio en los roles de la cuenta) y de la **política de la clave KMS**
(sin `kms:Decrypt` no se puede leer). Recomendación: `pgadmin` sólo para
administración; los microservicios usan **identidades de BD dedicadas**. No se leen ni
exponen valores del secreto.
