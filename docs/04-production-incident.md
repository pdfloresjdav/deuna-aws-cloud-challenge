# Tarea 4 — Runbook de incidente de producción (payments-processor)

> Runbook **operativo** para guardia (Fase 3). Describe un proceso propuesto de
> respuesta a incidentes; **no** se ejecutó contra infraestructura real ni se
> desplegaron recursos AWS. La causa raíz **no** se asume.

## Resumen ejecutivo

A las **02:47** una alerta indica que el servicio ECS **`payments-processor`** ha
alcanzado su **capacidad máxima (10/10 tareas)** y que la **latencia p99 supera
los 4 s**. El objetivo del runbook es **diagnosticar por evidencia** antes de
actuar, **mitigar sin downtime planificado** protegiendo las transacciones
monetarias en vuelo, **comunicar** a equipos técnicos/producto/C-Level y preparar
un **postmortem** sin culpables.

Decisión central: **alcanzar el máximo de ECS NO prueba por sí solo** dónde está
el cuello de botella. Puede ser cómputo de ECS, Aurora o un proveedor de pagos
externo. Por eso **subir el máximo de ECS es una acción condicional, no la acción
por defecto**: hacerlo sin verificar *headroom* aguas abajo puede **empeorar** una
saturación de base de datos o amplificar reintentos contra un proveedor degradado.

## Hechos conocidos vs. supuestos

| Tipo | Contenido |
|---|---|
| **Hecho conocido (escenario)** | Hora inicial 02:47; servicio `payments-processor`; 10/10 tareas (max alcanzado); p99 > 4 s; la guardia escaló a infraestructura |
| **Hipótesis** | Cuál de ECS/Aurora/proveedor externo es responsable (a determinar por evidencia) |
| **Supuesto operativo** | Umbrales de severidad, ventanas de tiempo (T+0..T+30), estabilización 15–30 min, ejemplo de subida 10→15 |
| **Sintético/ejemplo** | `correlationId=inc-payments-20261124-0001`, identificadores con *placeholders* |
| **Dependiente de instrumentación** | Tasa de éxito de pagos, p50/p95/p99, estado del proveedor, trazas distribuidas (ver Tarea 1/2; **no desplegadas**) |

No se inventan pérdidas financieras, nº de clientes afectados, % de pagos fallidos,
tiempo real de recuperación ni causa raíz confirmada.

## 1. Activación del incidente y evaluación inicial

### Modelo de severidad (propuesto)

| Severidad | Criterio (propuesto) |
|---|---|
| **SEV-1** | Pagos monetarios fallando de forma generalizada, o incumplimiento de SLO con impacto material en clientes, o riesgo de inconsistencia financiera |
| **SEV-2** | Degradación significativa (p99 alto, saturación) **sin** fallo masivo de pagos confirmado; riesgo de escalar a SEV-1 |
| **SEV-3** | Degradación menor, sin impacto de negocio confirmado |

**Por qué este escenario merece investigación urgente:** `payments-processor` es
un flujo **monetario**; p99 > 4 s en pagos sugiere impacto potencial al cliente y
posible incumplimiento de SLO. **Pero alcanzar 10/10 tareas no es, por sí solo, un
outage crítico**: el servicio puede estar operando correctamente en su máximo.

**SEV-1 vs SEV-2 — cómo decidir (por evidencia, no por la alerta de capacidad):**
se eleva a **SEV-1** si se confirma caída de la **tasa de éxito de pagos**,
errores 5xx/timeouts elevados, incumplimiento de SLO con impacto al cliente, o
señales de **inconsistencia transaccional**. Si sólo hay latencia alta sin fallo
de pagos confirmado, se mantiene **SEV-2** con vigilancia activa. La saturación de
capacidad influye en la severidad **sólo** a través de su impacto en pagos,
negocio y SLO/SLA.

### Roles y mecánica
- **Acknowledgement** del *page* en el momento (registrar hora).
- **Incident Commander (IC)**: coordina; no ejecuta cambios directamente.
- **Technical responders**: infraestructura (ECS/Aurora), aplicación/pagos.
- **Communication owner**: actualizaciones a producto/C-Level.
- **Canal de incidente** dedicado (p. ej. `#inc-payments-20261124-0001`).
- **Timeline**: registrar cada observación, hipótesis y acción con hora.
- **Coordinación de cambios**: congelar despliegues y `terraform apply` mientras
  dure el incidente (ver §8.1 reconciliación).

### Timeline de respuesta propuesto (objetivos, no eventos reales)
| Ventana | Objetivo |
|---|---|
| **T+0–5 min** | Ack, abrir canal, asignar IC, evaluar **impacto de cliente/negocio** |
| **T+5–15 min** | Diagnóstico ordenado (negocio → ECS → red → Aurora → externo → cambios) y decisión de mitigación |
| **T+15–30 min** | Ejecutar mitigación condicional y **verificar** efecto en métricas de cliente |
| **T+30+** | Estabilización, comunicación, reconciliación de transacciones y recuperación |

Las ventanas son **objetivos propuestos**, no tiempos garantizados ni un timeline
histórico real.

## 2. Secuencia diagnóstica (ordenada)

**Principio: primero el impacto de cliente/negocio, antes de cambiar
infraestructura.** Comandos de ejemplo en
[`examples/incident-diagnostics.md`](examples/incident-diagnostics.md).

### 6.1 Salud de negocio y servicio
Investigar: tasa de **éxito/fallo de pagos**, volumen de peticiones, **p50/p95/p99**,
ratios **4xx/5xx**, **timeouts**, pagos **pendientes**, indicadores de
**duplicados**, *backlog* de cola (si aplica), clientes/flujos afectados, y
**cambios recientes** (despliegues/config). Dependen de **instrumentación de
aplicación** (ver Tarea 1/2, **no desplegada**): tasa de éxito de pagos, p-latencias
de negocio, estados de transacción, indicadores de duplicados. No se inventa
capacidad de monitorización existente; si una señal no está instrumentada, se
marca como **no disponible** y se busca un proxy (p. ej. 5xx del ALB).

### 6.2 ECS y configuración de escalado
Investigar: desired/running/pending, min/max, CPU/mem, reinicios de tarea, **OOM**,
salud de contenedor, **eventos de servicio ECS**, **scaling activities**, fallos de
**placement**, estado de **deployment**, **service quotas** de ECS, capacidad de
infraestructura disponible, y comportamiento del **capacity provider** (Fargate o
EC2) **según el modelo real** (no se asume ninguno en exclusiva).

Comandos read-only (placeholders): `aws ecs describe-services`,
`aws ecs list-tasks`, `aws ecs describe-tasks`,
`aws application-autoscaling describe-scalable-targets`,
`aws application-autoscaling describe-scaling-policies`,
`aws application-autoscaling describe-scaling-activities`,
`aws cloudwatch get-metric-data`. Propósito y evidencia en el apéndice de comandos.
- `describe-services` → desired/running/pending, `events[]` (p. ej.
  `SERVICE_TASK_PLACEMENT_FAILURE`), estado de `deployments[]`.
- `describe-scaling-activities` → si Auto Scaling intentó escalar y por qué se
  detuvo (p. ej. tope en `MaxCapacity`).
- `get-metric-data` → CPU/mem del servicio para distinguir **AT_CAPACITY_LIMIT** de
  **SATURATED** (ver estados de Tarea 1).

### 6.3 Balanceador y red (componente condicional)
**El escenario no especifica un ALB**; si existe, investigar con métricas
**verificadas** de `AWS/ApplicationELB`: `RequestCount`, `TargetResponseTime`,
`HTTPCode_Target_5XX_Count`, `HTTPCode_ELB_5XX_Count`, `HealthyHostCount`,
`UnHealthyHostCount`, `RejectedConnectionCount`, `TargetConnectionErrorCount`;
además registro/baja de *targets*, saturación de conexiones y timeouts de red. Si
no hay ALB, se omite esta sección.

### 6.4 Aurora PostgreSQL (consistente con Fase 1)
Investigar con **CloudWatch Database Insights**, **Enhanced Monitoring** y métricas
Aurora (implementadas en Fase 1): `CPUUtilization`, `DatabaseConnections`,
**`DBLoad`/`DBLoadCPU`/`DBLoadNonCPU`** (Performance Insights) y **wait events**,
latencias `ReadLatency`/`WriteLatency` o `CommitLatency`, `FreeableMemory`,
IOPS/`[Read|Write]Throughput`, `AuroraReplicaLag` (si hay réplicas), bloqueos y
transacciones largas, agotamiento de *connection pool* y cambios recientes.

Consultas PostgreSQL read-only (sin exponer parámetros sensibles ni *payloads*):
`pg_stat_activity` (sesiones/estado/espera), `pg_locks` + `pg_blocking_pids()`
(bloqueos), `pg_stat_database` (conexiones/xacts/deadlocks),
`pg_stat_statements` **sólo si está habilitado**.

> **No** terminar sesiones de BD sin entender su impacto transaccional (una sesión
> podría estar a mitad de un débito/crédito). **Subir tareas de ECS puede empeorar
> un cuello de botella de BD**: cada tarea abre más conexiones y concurrencia de
> consultas sobre el mismo Aurora, agravando *connection exhaustion* o contención
> de locks.

### 6.5 Dependencias de pago externas
Investigar: tiempo de respuesta del proveedor, **tasa de timeouts**, errores HTTP
externos, fallos de conexión/DNS/TLS, **rate limiting**, **amplificación de
reintentos**, estado de **circuit breaker** (si existe), estado de transacción
específico del proveedor, su *status page*, y **correlación por trazas**.

**Distinguir tiempo local vs. espera externa:** con trazas distribuidas (W3C Trace
Context, ver Tarea 2) se compara el *span* de procesamiento interno con el *span*
de la llamada saliente al proveedor; si la mayor parte del p99 está en el *span*
externo, el cuello de botella es la dependencia, no ECS. No se inventan nombres de
proveedores.

### 6.6 Cambios recientes
Investigar: revisiones de **task definition**, *releases*, cambios de configuración
y de **scaling policy**, cambios de infraestructura, **migraciones de BD** y cambios
de dependencias, usando **CloudTrail** e historial de despliegue. **No** se asume
que el incidente lo causó el último despliegue; se correlaciona por tiempo con el
inicio de la degradación (que puede ser anterior a 02:47).

## 3. Matriz de decisión de causa raíz

| # | Hipótesis | Evidencia a favor | Evidencia en contra | Métricas/comandos | Mitigación segura | Acción que podría empeorar |
|---|---|---|---|---|---|---|
| 1 | Saturación de cómputo ECS | CPU/mem > objetivo en el máximo; AS topado en max | CPU/mem bajos pese a 10/10 | `get-metric-data` CPU/mem; `describe-scaling-activities` | Subir max **incremental** si hay headroom aguas abajo (§8.1) | Subir max con Aurora/externo saturado |
| 2 | Placement / capacidad de infra | `SERVICE_TASK_PLACEMENT_FAILURE`; running<desired; sin IPs de subred | pending=0 y tasks sanas | `describe-services events[]`; subnet IPs; quotas | Liberar IPs/quota; corregir capacity provider | Forzar más tareas sin IPs/capacidad |
| 3 | Saturación de CPU de Aurora | `DBLoad`/CPU altos; latencias de consulta altas | DBLoad normal | Database Insights; `pg_stat_activity` | Reducir concurrencia; optimizar queries (§8.2) | **Añadir tareas ECS**; failover innecesario |
| 4 | Contención de locks / queries lentas | `pg_locks`/`pg_blocking_pids` con bloqueos; wait events de lock | sin bloqueos | `pg_locks`, `pg_blocking_pids()`, `pg_stat_statements` | Resolver bloqueante tras entender impacto | Matar sesiones a ciegas |
| 5 | Agotamiento de conexiones | `DatabaseConnections` cerca del límite; errores de pool | conexiones holgadas | `DatabaseConnections`; logs de pool | Ajustar pool; reducir concurrencia | Más tareas ECS (más conexiones) |
| 6 | Degradación de proveedor externo | p99 dominado por *span* externo; timeouts externos | spans externos normales | trazas; métricas de cliente HTTP | Backoff+jitter, circuit breaker (§8.3) | Reintentos ciegos (amplificación) |
| 7 | Amplificación de reintentos | pico de intentos (attemptId) >> transacciones; carga externa/BD creciente | ratio intentos/txn normal | conteo intentos vs txn (Tarea 2) | Limitar reintentos; presupuesto de reintentos | Subir capacidad para "absorber" reintentos |
| 8 | Regresión por despliegue | degradación coincide con nueva task def/release | sin cambios recientes | CloudTrail; revisiones de task def | Rollback a última sana (§8.4) | Rollback con migración irreversible |
| 9 | Pico de tráfico (legítimo/abusivo) | `RequestCount` anómalo; patrón de origen | volumen normal | ALB `RequestCount`; WAF | Admisión controlada; proteger pagos (§8.5) | Bloquear tráfico de pago legítimo |
| 10 | Telemetría ausente/engañosa | observaciones obsoletas; UNKNOWN (Tarea 1) | datos frescos y coherentes | heartbeat; frescura | Validar antes de actuar | Actuar sobre datos obsoletos |

**Árbol de decisión:**
[`diagrams/incident-diagnosis-decision-tree.mmd`](diagrams/incident-diagnosis-decision-tree.mmd)
(demuestra que subir el max de ECS es **condicional**).

## 4. Mitigación sin downtime planificado

> No se garantiza **cero** downtime en todos los modos de fallo. Las mitigaciones
> buscan **minimizar** la interrupción, **preservar** la capacidad sana existente
> y **proteger** las transacciones en vuelo.

### 8.1 Cuello de botella de capacidad ECS
**Sólo si** la evidencia confirma que ECS es el cuello de botella **y** hay
*headroom* aguas abajo:
1. Evaluar **service quotas** y disponibilidad de capacidad.
2. Verificar **IPs de subred** disponibles (ENIs por tarea).
3. Verificar **capacidad de conexiones** de Aurora.
4. Verificar **rate limits** del proveedor externo.
5. Revisar **scaling policies** y cooldowns.
6. **Subir el máximo de forma incremental** (ejemplo sintético **10 → 15**).
7. Dejar que **Application Auto Scaling** solicite tareas adicionales.
8. Confirmar que las nuevas tareas quedan **healthy**.
9. Vigilar métricas de cliente.
10. Definir **criterios de rollback**.

```bash
# Synthetic example - raise MAX capacity 10 -> 15 (preserves min=2 and policies).
# This changes the registered scalable target bounds, NOT the desired count;
# Application Auto Scaling then decides the desired count via the policies.
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER}/payments-processor" \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 \
  --max-capacity 15 \
  --region "${REGION}"
```
**Max vs desired:** subir `--max-capacity` **sube el techo**; la `DesiredCount` la
sigue fijando el *target tracking*. No se fija `desired` a mano salvo necesidad
puntual justificada. Se **preservan** `min-capacity` y las políticas. **No** se
sube a un número arbitrariamente alto. No ejecutar el comando aquí.

**Reconciliación con Terraform:** un cambio de emergencia introduce *drift* frente
a la Fase 1. Durante el incidente se **congela** `terraform apply` para que una
reconciliación automática **no revierta** la mitigación. Tras estabilizar, el
cambio se **reconcilia** actualizando las variables Terraform (p. ej.
`aurora_*`/capacidad) o el *scalable target* gestionado, y se aplica de forma
controlada (ver §11).

### 8.2 Cuello de botella de base de datos (Aurora)
Si la evidencia señala Aurora:
- **Evitar más concurrencia** de aplicación (no añadir tareas ECS).
- Revisar límites del **connection pool**.
- Identificar queries caras o **bloqueadas** (entendiendo su impacto).
- Reducción de carga segura; **diferir operaciones no esenciales** si el negocio lo
  permite.
- **Read replicas sólo para lecturas** adecuadas. **Añadir *readers* NO aumenta la
  capacidad del *writer*.**
- Evaluar escalado de BD por evidencia y procedimientos soportados; **evitar
  failover** salvo que el modo de fallo lo justifique (el redimensionado/failover
  **no** es necesariamente sin interrupción).
- **No** terminar sesiones de forma incontrolada; documentar seguridad transaccional.

### 8.3 Degradación de dependencia externa
Si el proveedor externo es el cuello de botella:
- **Reintentos acotados** con backoff exponencial + jitter; respetar **rate limits**.
- **Circuit breakers** donde existan; reducir **amplificación**.
- Preservar **idempotencia**; usar **colas durables** sólo si el flujo de negocio
  existente lo soporta.
- Mantener estados **pendiente/desconocido** cuando el resultado externo es ambiguo;
  **reconciliar** el estado antes de reintentar operaciones financieras.
- Proveedores alternativos **sólo** si ya existe un enrutamiento autorizado.

> **No** reintentar pagos a ciegas. **No** marcar transacciones como `FAILED` sólo
> porque hubo un timeout (el pago pudo completarse en el proveedor).

### 8.4 Regresión por despliegue
Si la evidencia liga el incidente a un *release*:
- **Pausar** nuevos despliegues.
- Evaluar compatibilidad de **rollback** y de **migraciones de BD**.
- Rollback a la última **task definition sana** cuando sea seguro, preservando la
  capacidad sana durante el *rollout*.
- Verificar health checks; usar el **deployment circuit breaker** de ECS
  (rollback automático) donde aplique.

```bash
# Representative rollback to a known-healthy task definition revision.
aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service payments-processor \
  --task-definition "payments-processor:${LAST_HEALTHY_REVISION}" \
  --force-new-deployment \
  --region "${REGION}"
```
> **No** se asume que el rollback es seguro si hubo una **migración de BD
> irreversible** (p. ej. columna eliminada): primero se verifica compatibilidad.

### 8.5 Pico de tráfico o tráfico abusivo
- Distinguir **demanda legítima** de **abuso**.
- Proteger los flujos **monetarios** críticos; **admisión controlada** donde se
  soporte; priorizar operaciones en vuelo; diferir cargas no críticas.
- Usar **rate limiting**/**WAF** existentes sólo si están disponibles.
- **No** bloquear indiscriminadamente tráfico de pago legítimo.

## 5. Integridad de transacciones financieras

Salvaguardas para operaciones monetarias durante el incidente (se distingue lo
**recomendado a nivel de aplicación** de lo **confirmado en Deuna!**, que es
desconocido):
- **Identificadores de transacción estables** (`transactionId`, ver Tarea 2) y
  **claves de idempotencia** para prevenir **débitos/créditos duplicados**.
- **Estado de transacción durable** y manejo explícito de **timeouts externos
  ambiguos** como estado **PENDING/UNKNOWN**, nunca `FAILED` automático.
- **Reintentos controlados** (no amplificar) y **reconciliación** del estado real
  con el proveedor antes de reintentar.
- **Audit trail** de cada intento (`attemptId`) sin exponer PAN/saldos/PII.
- **Coordinación negocio↔infra**: operaciones puede necesitar retener liquidaciones
  hasta reconciliar.

> **La recuperación de infraestructura no basta**: aunque ECS/Aurora vuelvan a la
> normalidad, si quedan transacciones monetarias **inconsistentes o sin resolver**,
> el incidente **no** está cerrado hasta reconciliarlas (evitar doble cargo o
> pérdida de un pago).

## 6. Comunicación del incidente

Cadencia propuesta: **SEV-1** → técnico cada 15–30 min, producto cada 30–60 min,
C-Level al inicio y en hitos; **SEV-2** → técnico cada 30 min, producto/C-Level en
hitos. Todos los ejemplos son **sintéticos**; no se promete ETA de recuperación sin
evidencia.

### 10.1 Equipo técnico
Incluye: ID de incidente, severidad, síntomas, evidencia conocida, hipótesis
activas, acciones en curso, responsables, riesgos, **próxima actualización**.

- **Escalado inicial:** «**[SEV-2] inc-payments-20261124-0001** — 02:47
  `payments-processor` en 10/10 tareas, p99 > 4 s. IC: @ic. Evaluando impacto en
  pagos; aún **sin** causa raíz. Diagnóstico: negocio→ECS→Aurora→externo. Próxima
  actualización T+15.»
- **Update de diagnóstico:** «Update: CPU de servicio al 82 %, Auto Scaling topado
  en max; revisando `DBLoad` de Aurora y *spans* externos para descartar que subir
  tareas empeore la BD. Sin cambios de capacidad aún. Próxima: +15 min.»
- **Update de mitigación:** «Mitigación: confirmado headroom en Aurora y proveedor;
  subimos max 10→15 de forma incremental (desired lo fija Auto Scaling). Vigilando
  p99 y éxito de pagos. Rollback si p99 no baja en 10 min. Próxima: +15 min.»
- **Confirmación de recuperación:** «Recuperado: p99 dentro de SLO objetivo,
  éxito de pagos en baseline, tareas convergidas y sanas. Iniciando reconciliación
  de transacciones y estabilización. Postmortem programado.»

### 10.2 Producto y negocio (evitar jerga de infraestructura)
Incluye: impacto a cliente, flujos afectados, estado operativo, progreso de
mitigación, consideraciones de comunicación a cliente, **estado de integridad
transaccional**, próxima actualización.

- **Inicial:** «Estamos investigando **lentitud** que puede afectar a algunos
  **pagos** desde ~02:47. Equipo trabajando con prioridad alta. Protegiendo la
  integridad de las transacciones; **sin** confirmación aún de pagos perdidos.
  Próxima actualización en ~30 min.»
- **Estabilización:** «La situación se **estabiliza**: los pagos se procesan con
  normalidad y verificamos que no haya transacciones duplicadas o pendientes.
  Compartiremos resumen y acciones preventivas.»

### 10.3 C-Level (conciso)
Incluye: impacto de negocio, severidad, riesgo actual, estrategia de mitigación,
integridad transaccional, estado de recuperación, próxima actualización.

- **Inicial:** «**[SEV-2, en investigación]** Degradación de latencia en pagos
  desde 02:47; posible impacto parcial al cliente. Mitigación por evidencia en
  curso, priorizando **integridad de transacciones**. Sin pérdidas ni alcance
  confirmados. Próxima actualización en 30 min.»
- **Estabilización:** «Servicio estabilizándose; reconciliando transacciones para
  garantizar que no haya cargos duplicados ni pagos perdidos. Postmortem sin
  culpables con acciones preventivas a seguir.»

No se inventan pérdidas, nº de clientes, % de fallos ni ETA.

## 7. Estabilización y recuperación

**Criterios de recuperación (todos):**
- p99 vuelve al **SLO acordado** (el SLO real de Deuna! es **desconocido**; no se
  inventa como requisito confirmado).
- **Tasa de éxito de pagos** vuelve a baseline; errores/timeouts normalizados.
- `desired` y `running` **convergen**; placement sano.
- Carga y conexiones de Aurora estabilizadas.
- Dependencias externas recuperadas.
- *Backlog* de cola drena de forma **controlada** (si aplica).
- Transacciones monetarias **pendientes/ambiguas reconciliadas**; **sin** nuevos
  indicadores de duplicados.
- Telemetría **fresca** (sin observaciones obsoletas, Tarea 1).

Periodo de estabilización propuesto: **15–30 min** de métricas sanas sostenidas
(**supuesto operativo**, no un SLA).

**Por qué no bajar inmediatamente el max de ECS a su valor original:** reducirlo
durante la recuperación podría re-disparar la saturación. Se mantiene el techo
elevado hasta confirmar estabilidad sostenida y luego se restaura de forma
controlada.

**Proceso seguro de cierre:**
1. Retirar mitigaciones temporales **gradualmente** (p. ej. restaurar max tras
   estabilidad sostenida).
2. Restaurar scaling policies normales.
3. **Reconciliar *drift* con Terraform**: portar el cambio de emergencia a código
   (variables de Fase 1) y `plan`/`apply` controlado; reactivar CI/CD.
4. Revisar los cambios de emergencia (quién/qué/por qué).
5. **Cerrar** el incidente sólo tras cumplir **todos** los criterios, incluida la
   reconciliación transaccional.

## 8. Postmortem (sin culpables)

```
# Postmortem - inc-payments-20261124-0001  (BLAMELESS)

Incident summary : payments-processor reached 10/10 tasks and p99 > 4s at 02:47.
Severity         : SEV-2 (initial) - revisit with payment-impact evidence.
Business impact  : PENDING INVESTIGATION (no invented figures).
Detection        : automated max-capacity + p99 alert (see Task 1 design).
Timeline         : 02:47 alert; subsequent entries recorded during response.
Root cause       : PENDING INVESTIGATION - not assumed (ECS/Aurora/external).
Contributing factors : PENDING (e.g. cooldowns, pool limits, retry policy).
Evidence         : metrics/commands captured per diagnostic sequence (§2).
Mitigation actions   : per confirmed category (§4); recorded with timestamps.
Recovery validation  : recovery criteria met (§7).
Transaction reconciliation : monetary txns reconciled; no duplicate debits/credits.
What worked      : PENDING.
What did not work: PENDING.
Detection gaps   : PENDING.
Response gaps    : PENDING.
Corrective actions   : see table below (mapped to hypotheses).
Owners / Priorities / Target dates / Success criteria : see table.
```
El `summary` usa los **hechos conocidos**; causa raíz e impacto quedan
**explícitamente pendientes**. No se escribe una causa raíz ficticia como
confirmada.

**Acciones correctivas (representativas; implementar sólo las que justifique la
causa raíz confirmada):**

| Acción correctiva | Hipótesis que aborda (#) | Prioridad | Criterio de éxito |
|---|---|---|---|
| Planificación de capacidad ECS + headroom | 1, 2 | Alta | Max dimensionado a demanda pico + margen |
| Load testing periódico del flujo de pagos | 1, 6, 9 | Alta | Curvas de saturación conocidas antes de prod |
| Revisar umbrales/cooldowns de escalado | 1, 7 | Media | Escalado estable sin *flapping* |
| **Presupuesto de conexiones** de BD por servicio | 3, 5 | Alta | Conexiones totales < límite Aurora con todas las tareas |
| Monitorización de queries lentas y locks | 4 | Media | Alertas de bloqueo/`pg_stat_statements` activas |
| Resiliencia de dependencia externa (circuit breaker) | 6 | Alta | Degradación externa no satura ECS/BD |
| **Presupuesto de reintentos** + backoff/jitter | 6, 7 | Alta | Ratio intentos/txn acotado |
| Idempotencia y reconciliación de pagos | — (integridad) | Alta | Cero duplicados; estados ambiguos resueltos |
| Calidad de alertas (estado vs saturación) | 10 | Media | Alertas distinguen AT_CAPACITY de SATURATED (Tarea 1) |
| Documentación de respuesta a incidentes | — | Media | Runbook probado en *game day* |

**Métricas de rendimiento del incidente** (definidas; **sin** valores inventados):
MTTD, MTTA, *time to mitigate*, *time to recover*, impacto de SLO, **completitud de
reconciliación**. Se miden a partir del timeline real registrado, no se estiman aquí.

## 9. Consistencia con Tareas 1, 2 y 3

- **Tarea 1:** este incidente es exactamente el que detecta el diseño de la Tarea 1
  (estados **AT_CAPACITY_LIMIT**/**SATURATED**/**PLACEMENT_BLOCKED**,
  `correlationId=inc-payments-20261124-0001`, eventos JSON a CloudWatch Logs,
  dashboard, **guardrails de escalado manual**, evento de recuperación). *No
  desplegado*: es diseño.
- **Tarea 2:** los **reintentos** (`attemptId`) suman consumo pero **no** cuentan
  como transacciones de negocio; subir capacidad tiene **coste incremental** y la
  **capacidad ociosa** posterior es un *trade-off* que la plataforma FinOps
  visibiliza. *No desplegado*.
- **Tarea 3:** Aurora en **red privada**, **Database Insights** + **Enhanced
  Monitoring**, cifrado y **Secrets Manager** (credenciales rotadas, nunca en logs
  del incidente); infraestructura **gestionada por Terraform** con **reconciliación
  de cambios de emergencia** y separación dev/prod. (Implementado y validado
  estáticamente en Fase 1.)

## 10. Diagramas
- [`diagrams/incident-diagnosis-decision-tree.mmd`](diagrams/incident-diagnosis-decision-tree.mmd)
- [`diagrams/incident-response-lifecycle.mmd`](diagrams/incident-response-lifecycle.mmd)

## Supuestos y limitaciones
- Causa raíz **no** determinable con la información del escenario; el runbook es
  **evidence-based**, no asume ECS/Aurora/externo.
- SLO real desconocido; ventanas de tiempo y estabilización son **supuestos**.
- Capacidades de instrumentación (éxito de pagos, trazas, circuit breaker) son
  **recomendadas**; su existencia en Deuna! no se confirma.
- ALB es **condicional** (no especificado en el escenario).
- Comandos **no ejecutados**; sin despliegue AWS; sin BD real.

## Trazabilidad de requisitos (Tarea 4)

| Requisito | Sección |
|---|---|
| Modelo de severidad + activación + roles + timeline | §1 |
| Diagnóstico ordenado (negocio primero) 6.1–6.6 | §2 |
| Comandos read-only ECS/AutoScaling/CloudWatch/Aurora | §2 / examples |
| ALB como componente condicional, métricas verificadas | §2 (6.3) |
| Aurora consistente con Fase 1; queries pg_*; no matar sesiones; ECS empeora BD | §2 (6.4) |
| Externo: local vs espera; trazas; sin inventar proveedor | §2 (6.5) |
| Matriz de causa raíz (10 hipótesis) + árbol de decisión | §3 |
| Mitigación 8.1–8.5 sin downtime garantizado | §4 |
| Max vs desired; subida incremental 10→15; reconciliación Terraform | §4 (8.1) |
| Integridad transaccional financiera | §5 |
| Comunicación técnico/producto/C-Level + cadencia | §6 |
| Criterios de recuperación + cierre + no bajar max de inmediato | §7 |
| Postmortem sin culpables + acciones mapeadas + métricas | §8 |
| Consistencia con Tareas 1/2/3 | §9 |
| Diagramas (árbol + ciclo de vida) | §10 / diagrams |
| Referencia de comandos operativos | examples/ |

## Referencias AWS
- [ECS DescribeServices](https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DescribeServices.html) · [service events](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs_service_events.html) · [deployment circuit breaker](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html)
- [Application Auto Scaling RegisterScalableTarget](https://docs.aws.amazon.com/autoscaling/application/APIReference/API_RegisterScalableTarget.html) · [DescribeScalingActivities](https://docs.aws.amazon.com/autoscaling/application/APIReference/API_DescribeScalingActivities.html)
- [CloudWatch GetMetricData](https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_GetMetricData.html) · [ALB CloudWatch metrics](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-cloudwatch-metrics.html)
- [Aurora Database Insights](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_DatabaseInsights.html) · [Performance Insights DBLoad](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_PerfInsights.html) · [Enhanced Monitoring](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_Monitoring.OS.html)
- [PostgreSQL pg_stat_activity](https://www.postgresql.org/docs/current/monitoring-stats.html) · [pg_locks / pg_blocking_pids](https://www.postgresql.org/docs/current/view-pg-locks.html)
- [CloudTrail](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html)
