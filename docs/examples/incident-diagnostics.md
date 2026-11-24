# Referencia de comandos de diagnóstico de incidente (payments-processor)

> Comandos **representativos** para el runbook [`../04-production-incident.md`](../04-production-incident.md).
> **No ejecutar** aquí; sin credenciales ni datos de cliente. **No** es un script
> ejecutable (deliberadamente, para no modificar producción por accidente).
> Los **comandos read-only** son seguros de consulta; los **comandos de
> modificación** (marcados ⚠️) cambian producción y requieren autorización.

Placeholders (exportar antes de usar en un entorno autorizado):
```bash
export REGION="us-east-1"
export CLUSTER="deuna-prod"
export SERVICE="payments-processor"
export DB_HOST="<aurora-writer-endpoint>"   # from Phase 1 outputs
export DB_NAME="deuna"
# DB credentials: retrieved at runtime from Secrets Manager (RDS-managed secret),
# never hardcoded. e.g. aws secretsmanager get-secret-value --secret-id <arn>
```

---
## 1. ECS (read-only)
```bash
# Desired/running/pending, deployments[], events[] (placement failures, steady state)
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION"

# Task inventory and per-task detail (health, stopped reason, OOM)
aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --region "$REGION"
aws ecs describe-tasks --cluster "$CLUSTER" \
  --tasks <TASK_ARN_1> <TASK_ARN_2> --region "$REGION"

# Current task definition revision (to compare against last-healthy)
aws ecs describe-task-definition --task-definition "$SERVICE" --region "$REGION"
```
Evidencia: `events[]` con `SERVICE_TASK_PLACEMENT_FAILURE` → hipótesis #2;
`runningCount < desiredCount` con `pendingCount>0` → PLACEMENT_BLOCKED; `stoppedReason`
con OOM → presión de memoria.

## 2. Application Auto Scaling (read-only)
```bash
aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --resource-ids "service/$CLUSTER/$SERVICE" --region "$REGION"   # min/max

aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICE" --region "$REGION"    # target 60% policies

aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICE" --region "$REGION"    # why scaling stopped
```
Evidencia: actividad con causa "already at maximum capacity" confirma techo
alcanzado (AT_CAPACITY_LIMIT); ausencia de scale-out pese a CPU alta → topado en max.

## 3. CloudWatch (read-only)
```bash
# Service CPU/Memory (batch multiple metric queries in one call)
aws cloudwatch get-metric-data --region "$REGION" \
  --start-time 2026-11-24T02:30:00Z --end-time 2026-11-24T03:30:00Z \
  --metric-data-queries '[
    {"Id":"cpu","MetricStat":{"Metric":{"Namespace":"AWS/ECS",
      "MetricName":"CPUUtilization","Dimensions":[
      {"Name":"ClusterName","Value":"'"$CLUSTER"'"},
      {"Name":"ServiceName","Value":"'"$SERVICE"'"}]},"Period":60,"Stat":"Average"}},
    {"Id":"mem","MetricStat":{"Metric":{"Namespace":"AWS/ECS",
      "MetricName":"MemoryUtilization","Dimensions":[
      {"Name":"ClusterName","Value":"'"$CLUSTER"'"},
      {"Name":"ServiceName","Value":"'"$SERVICE"'"}]},"Period":60,"Stat":"Average"}}]'
```
Evidencia: CPU/mem > 60 % en el máximo → SATURATED (#1); CPU/mem bajos pese a 10/10
→ el cuello de botella **no** es cómputo ECS (mirar Aurora/externo).

## 4. Aurora PostgreSQL (read-only)
Métricas (CloudWatch/Database Insights): `CPUUtilization`, `DatabaseConnections`,
`DBLoad`/`DBLoadCPU`/`DBLoadNonCPU` (Performance Insights), `ReadLatency`/`WriteLatency`,
`FreeableMemory`, `AuroraReplicaLag`.
```sql
-- Active sessions and what they wait on (no sensitive query params exposed).
SELECT pid, usename, state, wait_event_type, wait_event,
       now() - xact_start AS xact_age
FROM pg_stat_activity
WHERE datname = current_database() AND state <> 'idle'
ORDER BY xact_age DESC NULLS LAST;

-- Blocking relationships.
SELECT bl.pid AS blocked_pid, pg_blocking_pids(bl.pid) AS blocking_pids,
       bl.wait_event_type, bl.state
FROM pg_stat_activity bl
WHERE cardinality(pg_blocking_pids(bl.pid)) > 0;

-- Locks overview.
SELECT locktype, mode, granted, count(*) FROM pg_locks GROUP BY 1,2,3;

-- Connection/throughput counters.
SELECT numbackends, xact_commit, xact_rollback, deadlocks
FROM pg_stat_database WHERE datname = current_database();

-- Only if pg_stat_statements is enabled: top statements by total time.
SELECT queryid, calls, total_exec_time, mean_exec_time
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
```
Evidencia: `DatabaseConnections` cerca del límite → #5; bloqueos en `pg_locks`/
`pg_blocking_pids` → #4; `DBLoad`/CPU altos → #3. **No** terminar sesiones sin
entender su impacto transaccional.

## 5. Balanceador (condicional, read-only)
Sólo si existe un ALB. Métricas `AWS/ApplicationELB`: `RequestCount`,
`TargetResponseTime`, `HTTPCode_Target_5XX_Count`, `HTTPCode_ELB_5XX_Count`,
`HealthyHostCount`, `UnHealthyHostCount`, `RejectedConnectionCount`.
```bash
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --region "$REGION"
# TargetResponseTime via get-metric-data, Namespace AWS/ApplicationELB,
# Dimension LoadBalancer=<lb-id> (and TargetGroup=<tg-id> where applicable).
```

## 6. Historial de cambios (read-only)
```bash
# Task definition revisions (regression correlation)
aws ecs list-task-definitions --family-prefix "$SERVICE" --sort DESC --region "$REGION"

# Recent control-plane changes (scaling, service updates, infra)
aws cloudtrail lookup-events --region "$REGION" \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=ecs.amazonaws.com \
  --start-time 2026-11-24T00:00:00Z
```
Evidencia: una nueva revisión/`UpdateService` justo antes del inicio de la
degradación → hipótesis #8 (no se asume que fue el último despliegue).

---
## 7. Mitigación de emergencia (⚠️ MODIFICA PRODUCCIÓN)

### ⚠️ 7.1 Subir el máximo de ECS (condicional)
- **Preconditions:** evidencia de que ECS es el cuello de botella **y** headroom
  confirmado en Aurora (conexiones) y proveedor externo (rate limits); quotas e
  IPs de subred disponibles.
- **Authorization:** aprobación del Incident Commander; despliegues y
  `terraform apply` **congelados**.
- **Expected effect:** sube el **techo** (max) 10→15; Auto Scaling puede aumentar
  `desired`. **No** cambia `desired` directamente. Preserva `min` y políticas.
```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$SERVICE" \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 --max-capacity 15 --region "$REGION"
```
- **Verification:** `describe-scalable-targets` muestra max=15; nuevas tareas
  `HEALTHY`; p99 y éxito de pagos mejoran; Aurora no se degrada.
- **Rollback:** si p99 no mejora o Aurora se degrada, restaurar `--max-capacity 10`
  y revisar Aurora/externo. **Reconciliar** el cambio en Terraform tras estabilizar.

### ⚠️ 7.2 Rollback de despliegue
- **Preconditions:** incidente correlacionado con un *release*; **sin** migración de
  BD irreversible; existe una revisión sana conocida.
- **Authorization:** IC + dueño del servicio.
- **Expected effect:** el servicio vuelve a la task definition sana con nuevo
  *deployment* (circuit breaker de ECS puede revertir si falla).
```bash
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$SERVICE:<LAST_HEALTHY_REVISION>" \
  --force-new-deployment --region "$REGION"
```
- **Verification:** `describe-services` → `deployments[]` estable, tareas `HEALTHY`,
  métricas de cliente normalizadas.
- **Rollback (del rollback):** si la revisión previa también falla, fijar la
  anterior conocida sana; evaluar *fix-forward* si hay incompatibilidad de esquema.

> **No** incluir credenciales, secretos de conexión ni datos financieros. **No**
> convertir estos comandos en un script ejecutable: cada comando ⚠️ se ejecuta
> manualmente, con verificación entre pasos.
