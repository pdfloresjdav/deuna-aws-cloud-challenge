# Matriz de trazabilidad de requisitos

> Mapea cada requisito del assessment a su evidencia en el repositorio. Estados:
> **IMPL** = implementado y validado estáticamente · **DIS** = diseñado y
> documentado · **EJ** = ejemplo ilustrativo · **AWS?** = requiere entorno AWS
> autorizado para verificación en runtime.

## Tarea 1 — Monitorización de escalado ECS (diseño)
| Requisito | Solución propuesta | Archivo | Evidencia | Estado | Supuestos/limitaciones |
|---|---|---|---|---|---|
| Detección de capacidad máxima | Detector híbrido (scheduler + eventos) evaluando desired vs max | `docs/01-ecs-scaling-monitoring.md` §3.1–3.4 | Estados, pseudocódigo | DIS | No hay evento AWS de "max"; latencia = cadencia |
| Integración observabilidad vía CloudWatch Logs | Grupos dedicados + ingesta existente, agnóstico de proveedor | §3.7 | Formato/retención/cifrado | DIS | Vendor no asumido |
| Contenido de alerta estructurado | Esquema JSON versionado + 3 ejemplos | §3.6, `examples/ecs-alert-events.json` | JSON válido | DIS/EJ | Valores sintéticos |
| Reducción de ruido | Máquina de estados DynamoDB, histéresis, dedup | §3.5 | Diagrama de estados | DIS | Umbrales configurables |
| Dashboard de guardia | Tabla + wireframe de 5 servicios | §3.8 | Mockup | DIS | No es app desplegada |

## Tarea 2 — Coste por transacción (diseño)
| Requisito | Solución propuesta | Archivo | Evidencia | Estado | Supuestos/limitaciones |
|---|---|---|---|---|---|
| Clasificación monetaria/no monetaria | Clasificación canónica en el borde | `docs/02-transaction-cost-allocation.md` §4.1 | Contexto sin PII | DIS | No cabeceras de usuario |
| Propagación de contexto | W3C Trace Context + atributos SQS | §4.2, `diagrams/transaction-context-propagation.mmd` | Diagrama | DIS | OTel recomendado |
| Atribución de recursos compartidos | Modelo híbrido + ecuación de ponderación | §4.4–4.5 | Fórmulas | DIS | Proxies (Aurora) estiman |
| Herramientas de facturación granular | AWS Data Exports CUR 2.0 (columnas verificadas) | §4.7 | Nombres de columna reales | DIS | CUR no da coste por txn |
| Pipeline de cálculo automatizado | Batch diario S3+Athena, idempotente | §4.10, `diagrams/cost-allocation-pipeline.mmd` | Diagrama | DIS | Sin streaming |
| Reporting producto/finanzas | Dashboards + resumen ejecutivo | §4.12 | Tablas | DIS | No es app BI |
| Ejemplo numérico | 800=332+268+200; recon 0.00 | §4.6, `examples/transaction-cost-allocation.sql` | Aritmética | EJ | Cifras sintéticas; SQL no ejecutado en Athena |

## Tarea 3 — Terraform (implementado)
| Requisito | Solución | Archivo/módulo | Evidencia | Estado | Supuestos/limitaciones |
|---|---|---|---|---|---|
| KMS clave simétrica | `aws_kms_key` SYMMETRIC_DEFAULT | `terraform/modules/kms/main.tf` | `validate` PASS | IMPL | — |
| KMS política mínimo privilegio | 5 sentencias (admin/uso/grants/logs) | `modules/kms/main.tf` | Checkov 109/111/356 justificados | IMPL | Key policy wildcard = la clave |
| KMS rotación automática | `enable_key_rotation=true` | `modules/kms` | — | IMPL | — |
| KMS tags de clasificación | Application/Env/Owner/ManagedBy/CostCenter/DataClassification | envs `common_tags` | — | IMPL | — |
| KMS protección de borrado | `prevent_destroy=true` + controles IAM/alarma (doc) | `modules/kms/main.tf` | `docs/security-validation.md` §6 | IMPL/DIS | Solo protege Terraform |
| S3 cifrado con CMK | SSE-KMS + Bucket Keys | `modules/s3/main.tf` | `validate` PASS | IMPL | — |
| S3 política segura | Deny transporte inseguro/TLS<1.2/cifrado o clave no autorizados | `modules/s3/main.tf` | Maneja header omitido (default) | IMPL | — |
| S3 versionado + lifecycle + sin acceso público | recursos dedicados, PAB ×4 | `modules/s3/main.tf` | — | IMPL | — |
| Aurora cifrado con CMK | `storage_encrypted`+`kms_key_id` | `modules/aurora/main.tf` | — | IMPL | — |
| Aurora subredes privadas + SG restringido | subnet group ≥2 AZ, ingress sólo SGs aprobados | `modules/aurora/main.tf` | — | IMPL | VPC/subredes existentes (input) |
| Aurora backups + monitorización | backups, Enhanced Monitoring, Database Insights, logs | `modules/aurora/main.tf` | — | IMPL | Versión/clase no verificadas en AWS |
| Secrets Manager pgadmin + KMS + rotación | `manage_master_user_password` nativo | `modules/aurora` + `modules/secrets-manager` | — | IMPL | Rotación/política requieren AWS? |
| Secrets Manager política restringida | resource policy + `block_public_policy` | `modules/secrets-manager/main.tf` | `security-validation.md` §7 | IMPL | Allow-only; gobernanza IAM residual |
| Estructura modular | modules + envs + bootstrap | `terraform/` | árbol | IMPL | — |
| Estado remoto | bucket + KMS propia, `use_lockfile` | `terraform/bootstrap/`, `backend.hcl.example` | — | IMPL | Aislamiento real requiere IAM |
| Herramientas de validación de seguridad | TFLint + Checkov + CI | `.tflint.hcl`, `.checkov.yaml`, workflow | 138/0/24 | IMPL | — |

## Tarea 4 — Incidente de producción (runbook)
| Requisito | Solución | Archivo | Evidencia | Estado | Supuestos/limitaciones |
|---|---|---|---|---|---|
| Diagnóstico ordenado | Negocio→ECS→red→Aurora→externo→cambios | `docs/04-production-incident.md` §2 | Comandos read-only | DIS | Comandos no ejecutados |
| Diferenciación de causa raíz | Matriz de 10 hipótesis + árbol | §3, `diagrams/incident-diagnosis-decision-tree.mmd` | Diagrama | DIS | Causa raíz no asumida |
| Mitigación sin downtime evitable | Playbooks por categoría; subida ECS condicional | §4 | `register-scalable-target` 10→15 (EJ) | DIS/EJ | No garantiza 0 downtime |
| Comunicación técnica/producto/C-Level | Plantillas + cadencia | §6 | Mensajes ejemplo | DIS | Sin cifras inventadas |
| Postmortem y prevención | Plantilla sin culpables + acciones mapeadas | §8 | Tabla | DIS | Causa raíz pendiente |

## Matriz de dimensiones de evaluación (evidencia, sin notas ficticias)
| Dimensión (peso) | Dónde encontrar la evidencia |
|---|---|
| Profundidad y precisión técnica (30%) | Comportamiento real de target tracking (T1 §3.3), CUR 2.0 verificado (T2 §4.7), atributos de proveedor verificados (T3 Aurora/Database Insights), diagnóstico por evidencia (T4) |
| Seguridad AWS (25%) | Política KMS (T3 §5), política S3, red privada Aurora, secreto gestionado, `docs/security-validation.md` (24 excepciones revisadas) |
| Calidad Terraform (20%) | Módulos tipados con validación, lock files multi-plataforma, `validate`/TFLint/Checkov PASS, `docs/03-terraform-architecture.md` |
| Eficiencia de coste (15%) | Bucket Keys, lifecycle, Database Insights `standard`, dev<prod, estimaciones por fórmula (T1 §3.9, T2 §4.14) |
| Claridad de entrega (10%) | PDF consolidado, diagramas renderizados, README, esta matriz, trazabilidad por tarea |

No se asignan calificaciones ni se garantiza una puntuación.
