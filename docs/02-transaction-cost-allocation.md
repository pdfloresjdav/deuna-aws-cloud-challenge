# Tarea 2 — Asignación de coste por transacción

> Documento de **diseño** (Fase 2). Arquitectura propuesta; no es un sistema
> desplegado. No se creó infraestructura AWS en esta fase. Las cifras son
> **sintéticas**, no costes ni precios reales de AWS.

## Resumen ejecutivo

Las transacciones monetarias y no monetarias de Deuna! consumen servicios AWS
compartidos (API Gateway, Lambda, ECS, Aurora PostgreSQL, SQS, S3) con modelos de
precio distintos. Se propone una plataforma **FinOps batch** que calcula el coste
**aproximado** por categoría de transacción combinando dos fuentes que cumplen
funciones diferentes:

1. **Telemetría de uso de la aplicación** (OpenTelemetry + eventos de uso
   estructurados) para atribuir *consumo* por transacción.
2. **Datos de facturación** de AWS vía **AWS Data Exports (CUR 2.0)** para el
   *coste* real por recurso/ventana.

Ambas se depositan en un *data lake* en S3 (Parquet), se catalogan con Glue y se
procesan con Athena mediante un modelo de **asignación híbrido** (coste directo,
variable compartido, fijo compartido, capacidad ociosa y no asignado). El
resultado se **reconcilia** contra la facturación y se publica para dashboards de
Producto, Finanzas e Infraestructura (QuickSight o BI equivalente).

Principio central verificado: **CUR 2.0 no proporciona el coste de una transacción
de negocio individual**; el coste por transacción es una **estimación** derivada
de ponderar el coste del recurso por el consumo relativo de cada categoría. La
capacidad **ociosa** se mantiene como un *pool* separado y visible; sólo se
reparte en un coste "totalmente cargado" bajo una política de negocio explícita.

Diagramas: [arquitectura](diagrams/transaction-cost-architecture.mmd) ·
[propagación de contexto](diagrams/transaction-context-propagation.mmd) ·
[pipeline](diagrams/cost-allocation-pipeline.mmd). SQL de referencia:
[`examples/transaction-cost-allocation.sql`](examples/transaction-cost-allocation.sql).

## 4.1 Clasificación de transacciones

| Categoría | Tipos |
|---|---|
| `MONETARY` | `PAYMENT`, `TRANSFER`, `WITHDRAWAL`, `TOP_UP` |
| `NON_MONETARY` | `ONBOARDING`, `PROFILE_UPDATE`, `BALANCE_QUERY` |

La clasificación es **canónica** y la fija la **lógica de aplicación de confianza
en el punto de entrada** (API Gateway → servicio de borde), **no** cabeceras
arbitrarias del usuario (que podrían falsear la categoría financiera).

Contexto de transacción interno (sin datos sensibles):
```json
{
  "transactionId": "txn-7f3a...",          // business transaction identity
  "transactionCategory": "MONETARY",
  "transactionType": "PAYMENT",
  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",  // W3C trace-id (diagnostics)
  "environment": "prod",
  "serviceName": "payments-processor",
  "operation": "authorize",
  "attemptId": "att-01",                    // execution attempt (retries)
  "timestamp": "2026-11-24T14:03:00Z",
  "outcome": "SUCCESS",                     // SUCCESS|FAILED|CANCELLED|INCOMPLETE
  "schemaVersion": "1.0.0"
}
```

**Identificadores distintos:**
- `transactionId`: **identidad de negocio estable**; una por transacción de
  negocio. Es el denominador canónico de conteo.
- `traceId`: identificador de **traza distribuida** (W3C), para diagnóstico; puede
  abarcar varios servicios y no es estable como unidad de negocio.
- `attemptId`: **intento de ejecución** (reintentos); múltiples por `transactionId`.

**Prohibido** en el contexto: números de cuenta, saldos, importes, PII, tokens de
autenticación o *payloads* de negocio sensibles.

## 4.2 Propagación de contexto

- **HTTP síncrono** (API Gateway → ECS → Lambda): propagación con **W3C Trace
  Context** (`traceparent`/`tracestate`) + cabecera de negocio
  `x-deuna-txn-context` (o `baggage` de OpenTelemetry) con `transactionId`,
  `transactionCategory`, `transactionType`.
- **SQS asíncrono**: contexto en **message attributes** (no en el cuerpo), para
  preservar `transactionId` y relaciones de traza entre productor y consumidor;
  se usa *span link* para relacionar el consumidor con la transacción original.
- **Reintentos y entregas duplicadas**: mismo `transactionId`, distinto
  `attemptId`; la deduplicación posterior garantiza un único conteo de negocio.
- **Batch / fan-out**: cada mensaje conserva su `transactionId`; un consumidor en
  lote emite un evento de uso por `transactionId` procesado.
- **Cargas programadas/background**: se etiquetan con un `transactionCategory`
  técnico (`NON_MONETARY`/`INTERNAL`) para no contaminar el coste de negocio.
- **Transacciones que cruzan ventanas de facturación**: el consumo se registra con
  su `billing_window` (hora UTC) propia; una transacción puede aportar uso a dos
  ventanas, cada una reconciliada por separado.

**Tags vs. telemetría (propósitos distintos):**
- **Cost allocation tags** de AWS (infraestructura): `Application`,
  `Environment`, `Owner`, `CostCenter`. Dimensión **estática** del recurso.
- **Telemetría de aplicación**: `transactionCategory`, `transactionType`,
  atribución individual. Dimensión **dinámica** por petición.

**No** se cambian tags de recursos por petición individual, ni se crean
dimensiones de métricas CloudWatch de alta cardinalidad por `transactionId`.

## 4.3 Arquitectura

| Capa | Servicios | Por qué |
|---|---|---|
| Telemetría app | OpenTelemetry → eventos de uso estructurados → CloudWatch Logs/Firehose → S3 | Capturar consumo por transacción sin alta cardinalidad en métricas |
| Facturación | AWS Billing & Cost Management → **AWS Data Exports (CUR 2.0)** → S3 | Coste real por recurso/hora con dimensiones verificadas |
| Procesamiento | Glue Data Catalog + **Athena** + EventBridge Scheduler (+ Step Functions si se justifica) | Catalogar, consultar y orquestar el batch diario |
| Presentación | QuickSight o BI equivalente | Reportes FinOps diarios/mensuales |

Se prefiere la arquitectura más simple: **batch diario sobre S3+Athena**, sin
streaming salvo requisito concreto. Esta arquitectura es **distinta** de la
infraestructura de Fase 1 (KMS/S3/Aurora/Secrets de datos de negocio); aquí los
buckets, catálogo y consultas son **analíticos** y separados.

## 4.4 Matriz de *cost drivers* por servicio

| Servicio | Dimensiones de facturación reales | Instrumentación requerida | Driver de atribución | Limitación | Tipo |
|---|---|---|---|---|---|
| **API Gateway** | nº de requests; transferencia/payload según tipo (REST/HTTP); caché | request count por `transactionId` | requests | tipo de API afecta tarifa | directo/estimado |
| **Lambda** | invocaciones; **GB-seconds** (duración facturada × memoria); arquitectura (arm64/x86); provisioned concurrency | duración+memoria por invocación | GB-seconds | concurrencia aprovisionada es fijo compartido | directo/estimado |
| **ECS (Fargate)** | vCPU-hora + GB-hora por tarea; runtime; **Split Cost Allocation Data** (CPU/mem por tarea) | vCPU-s/mem-s consumidos por request | task vCPU-s/mem-s | capacidad reservada no usada = ociosa | estimado/compartido |
| **Aurora PostgreSQL** | **instancia-hora o ACU-hora**; almacenamiento GB-mes; **I/O** (según configuración); backup storage | duración/consumo de consulta como **proxy** | proxy de consumo (no es dimensión de facturación) | query duration **no** es dimensión facturable directa | estimado/compartido |
| **SQS** | nº de API requests (por bloques de 64 KB de payload); batch | request/mensaje por `transactionId` | requests | coste compartido de requests | directo/estimado |
| **S3** | **almacenamiento GB-mes**; requests por clase; transferencia; transiciones de lifecycle; recuperación | tamaño/clase de objeto por transacción | GB-mes + requests | storage **no** es sólo requests | estimado/compartido |
| **CloudWatch** | ingesta de logs; almacenamiento; queries | bytes de telemetría por categoría | log GB | parte es overhead del propio FinOps | estimado/compartido |
| **KMS** | nº de API requests; **coste fijo por clave** | requests cripto por transacción | requests | coste fijo de clave no es por transacción | compartido/fijo |

Aclaraciones obligatorias:
- La **duración de consulta de Aurora NO es una dimensión de facturación directa**;
  se usa como *proxy* de consumo para repartir el coste de instancia/ACU/almacenamiento.
- El **almacenamiento S3 NO es sólo requests**: incluye GB-mes, transferencia,
  transiciones y recuperación.
- La granularidad por recurso depende de que el servicio la soporte y de la
  configuración del export (p. ej. `INCLUDE RESOURCES` y Split Cost Allocation Data).

## 4.5 Modelo de asignación

Cinco componentes:
1. **Costes directos atribuibles** (uso con `resource_id` + telemetría 1:1).
2. **Costes variables compartidos** (pay-per-use repartido por consumo).
3. **Costes fijos de capacidad compartida** (capacidad provisionada en uso).
4. **Capacidad ociosa** (provisionado no consumido) — *pool* separado por defecto.
5. **No asignado / desconocido** (facturación sin telemetría asociada).

**Ecuación de asignación** para transacción *i*, recurso *r*, ventana *w*:

```
allocated_cost(i, r, w) = eligible_cost(r, w) * ( weight(i, r, w) / Σ_j weight(j, r, w) )
```
donde `Σ_j` recorre todas las transacciones elegibles del recurso *r* en la
ventana *w*. Agregado por categoría *c*:
```
allocated_cost(c, r, w) = eligible_cost(r, w) * ( Σ_{i∈c} weight(i,r,w) / Σ_j weight(j,r,w) )
```

Reglas:
- **Pesos por recurso**: API GW=requests; Lambda=GB-seconds; ECS=vCPU-s;
  Aurora=proxy de consumo; SQS=requests; S3=GB-mes+requests; Obs=log bytes.
- **Emparejamiento con ventanas**: telemetría y coste se unen por
  `(resource_id|resource_type, billing_window)` horario.
- **Telemetría ausente**: el coste **no** se asigna a 0; va al *pool* **no
  asignado** y se reporta (nunca silenciosamente cero).
- **Denominador cero**: si `Σ weight = 0` para un coste > 0, ese coste va a **no
  asignado** (se usa `NULLIF` en SQL).
- **Transacciones sin clasificar**: a *pool* no asignado hasta reclasificar.
- **Ociosa**: `eligible_cost(r,w) − Σ allocated` para recursos de capacidad =
  *pool* ocioso, visible por separado.
- **Versionado de política**: cada cálculo registra `policy_version`;
  recálculos históricos son reproducibles.
- **Sin doble conteo**: una base de coste única (ver 4.7); joins que no multiplican
  filas (agregaciones previas).
- **Redondeo**: cálculo en `DECIMAL(38, x)`; el residuo de redondeo se reporta.
- **Reconciliación**: ver 4.11.

**Conteo canónico**: una transacción de negocio = un `transactionId`. Los
**reintentos** (varios `attemptId`) **sí** suman consumo de recursos pero **no**
inflan el denominador de transacciones (`COUNT(DISTINCT transactionId)`).

**Conteo por outcome**: `SUCCESS`, `FAILED`, `CANCELLED`, `INCOMPLETE`. Se reporta
**coste por transacción intentada** (todas) y **por transacción exitosa** (sólo
`SUCCESS`).

**Tres nociones de coste unitario:**
- **Marginal**: sólo pools variables (coste que desaparecería si la transacción no
  ocurriera).
- **Asignado (*allocated*)**: marginal + capacidad fija compartida en uso (excluye
  ociosa).
- **Totalmente cargado (*fully-loaded*)**: asignado + reparto de ociosa/overhead
  según política de negocio explícita.

## 4.6 Ejemplo numérico (datos sintéticos, 1 día)

Volumen: **10 000 monetarias**, **40 000 no monetarias** (50 000 intentadas).
Tasas de éxito sintéticas: monetarias 95 % (9 500), no monetarias 99 % (39 600).

| Pool | Coste total | Driver | Consumo monetario | Consumo no monetario | Monetario asignado | No monetario asignado | Ocioso/No asignado |
|---|---:|---|---:|---:|---:|---:|---:|
| API Gateway | 90.00 | requests | 30 000 | 60 000 | 30.00 | 60.00 | 0.00 |
| Lambda | 120.00 | GB-seconds | 60 000 | 60 000 | 60.00 | 60.00 | 0.00 |
| ECS | 200.00 | vCPU-s (split) | 45 000 | 30 000 | 90.00 | 60.00 | 50.00 |
| Aurora | 240.00 | consumo (proxy) | 100 000 | 50 000 | 100.00 | 50.00 | 90.00 |
| SQS | 20.00 | requests | 24 000 | 6 000 | 16.00 | 4.00 | 0.00 |
| S3 | 30.00 | GB-mes+req | 8 000 | 12 000 | 12.00 | 18.00 | 0.00 |
| Observabilidad | 40.00 | log bytes | 24 000 | 16 000 | 24.00 | 16.00 | 0.00 |
| Overhead compartido | 60.00 | no atribuible | — | — | 0.00 | 0.00 | 60.00 |
| **Total** | **800.00** | | | | **332.00** | **268.00** | **200.00** |

Verificación aritmética (una vez):
- Monetario = 30+60+90+100+16+12+24+0 = **332.00**
- No monetario = 60+60+60+50+4+18+16+0 = **268.00**
- Ocioso/No asignado = 50+90+60 = **200.00**
- Total = 332+268+200 = **800.00** ✓ (= coste elegible)

**Costes unitarios:**
- **Asignado**: monetaria = 332.00 / 10 000 = **0.033200**; no monetaria =
  268.00 / 40 000 = **0.006700**.
- **Marginal** (pools variables: API+Lambda+SQS+S3+Obs): monetario = 30+60+16+12+24
  = 142.00 → **0.014200**; no monetario = 60+60+4+18+16 = 158.00 → **0.003950**.
- **Totalmente cargado** (reparto de ociosa 200 por cuota de asignado 332/600 y
  268/600): monetario = 332 + 200·(332/600) = 332 + 110.6667 = 442.6667 →
  **0.044267**; no monetario = 268 + 89.3333 = 357.3333 → **0.008933**.
  Comprobación: 442.6667 + 357.3333 = 800.00 ✓
- **Por transacción exitosa** (asignado): monetaria = 332.00 / 9 500 =
  **0.034947**; no monetaria = 268.00 / 39 600 = **0.006768**.

**Ociosa/No asignado total** = **200.00** (ECS 50 + Aurora 90 + Overhead 60).
**Diferencia de reconciliación** = 800 − (332 + 268 + 200) = **0.00**; residuo de
redondeo = **0.00**.

## 4.7 AWS Data Exports y CUR 2.0

AWS Data Exports entrega **CUR 2.0** a S3 con esquema `snake_case`. Características
y columnas **verificadas** en la documentación oficial:
- Granularidad **horaria** (cuando se configura); `line_item_resource_id` sólo se
  puebla con `INCLUDE RESOURCES`.
- Columnas de cuenta/región/uso: `line_item_usage_account_id`,
  `line_item_usage_start_date`, `line_item_product_code`, `line_item_usage_type`,
  `line_item_operation`, `product` (mapa anidado, p. ej. región),
  `resource_tags` (mapa anidado con las *cost allocation tags* activadas).
- Tipo de línea: `line_item_line_item_type` (valores incluyen `Usage`, `Tax`,
  `Credit`, `Refund`, `DiscountedUsage`, `SavingsPlanCoveredUsage`,
  `SavingsPlanRecurringFee`, `RIFee`, `Fee`, `Discount`, `BundledDiscount`,
  `SavingsPlanNegation`, `SavingsPlanUpfrontFee`).
- Coste: `line_item_unblended_cost` y **`line_item_net_unblended_cost`** (neto de
  descuentos). RI/SP amortizado vía `reservation_net_effective_cost` y
  `savings_plan_net_savings_plan_effective_cost`.
- **Split Cost Allocation Data** (ECS): `split_line_item_parent_resource_id`,
  `split_line_item_split_cost`, `split_line_item_unused_cost`,
  `split_line_item_net_split_cost`, `split_line_item_net_unused_cost`,
  `split_line_item_split_usage`, `split_line_item_split_usage_ratio`.
- Créditos, *refunds*, impuestos, descuentos, correcciones de facturación y
  latencia de entrega aparecen como `line_item_line_item_type` específicos.

**Base de coste normalizada única**: se usa **coste neto amortizado** combinando
`line_item_net_unblended_cost` para `Usage`/`DiscountedUsage` con
`reservation_net_effective_cost`/`savings_plan_net_savings_plan_effective_cost`
para la cobertura de RI/SP, **sin mezclar** unblended, amortizado y efectivo de
forma que se dupliquen cargos. Se **excluyen** `Tax`, `Credit`, `Refund` del
*pool* elegible de uso y se reportan por separado en reconciliación.

> **CUR 2.0 NO proporciona el coste de transacciones de negocio individuales**; da
> coste por recurso/uso/hora. El coste por transacción es la estimación del §4.5.

## 4.8 Modelo de datos analítico

Formato preferido: **S3 Parquet**, particionado por **fecha y entorno**
(`event_date`, `environment`). **No** se particiona por `transactionId`.

| Tabla | Propósito | Claves lógicas | Columnas clave | Relaciones |
|---|---|---|---|---|
| `transaction_fact` | Transacciones de negocio | `transaction_id` (+`attempt_id`) | `transaction_category`, `transaction_type`, `outcome`, `environment`, `event_date`, `schema_version` | 1:N → resource_usage_fact |
| `resource_usage_fact` | Uso de recursos por transacción | `usage_id` | `transaction_id`, `attempt_id`, `resource_type`, `resource_id`, `usage_dimension`, `usage_quantity`, `billing_window`, `environment`, `event_date`, `schema_version` | N:1 → transaction_fact; N:1 → aws_billing_fact |
| `aws_billing_fact` | Coste normalizado desde CUR 2.0 | (`billing_window`,`resource_id`,`usage_type`) | `service`, `cost_basis_amount`, `currency`, `account`, `region`, `environment`, `line_item_type` | referenciada por allocation |
| `allocation_rules` | Reglas versionadas | (`resource_type`,`policy_version`) | `driver`, `eligibility`, `policy_version` | guía de asignación |
| `transaction_cost_fact` | Coste asignado (salida) | (`transaction_id`,`resource_type`,`billing_window`,`policy_version`) | `allocated_cost`, `attribution_method`, `data_quality_status`, `transaction_category` | salida del pipeline |
| `daily_cost_summary` | Agregado diario | (`event_date`,`environment`,`transaction_category`,`policy_version`) | `allocated_cost`, `idle_cost`, `unallocated_cost`, `txn_count`, `unit_cost` | consumo BI |

Las **claves lógicas** documentan identidad/relaciones; el motor analítico
(Athena sobre S3) **no impone** PK/FK: la unicidad se garantiza con
deduplicación en el pipeline, no con *constraints*.

## 4.9 SQL Athena representativo

Ver [`examples/transaction-cost-allocation.sql`](examples/transaction-cost-allocation.sql):
dedup de telemetría, agregación por recurso/ventana/transacción, pesos
compartidos, asignación proporcional, preservación de ociosa/no asignado,
agregación por categoría/tipo, costes unitarios con `COUNT(DISTINCT)` y
reconciliación. Maneja división por cero (`NULLIF`), `DECIMAL` financiero y evita
joins que multipliquen filas. Es una **referencia ilustrativa**; **no** se ejecutó
contra Athena en esta fase.

## 4.10 Pipeline de procesamiento diario

1. Recolectar telemetría de uso de la aplicación.
2. Entregar telemetría a S3 (vía CloudWatch Logs/Firehose).
3. Recibir AWS Data Exports (CUR 2.0) en S3.
4. Normalizar telemetría y facturación (base de coste única).
5. Validar completitud y clasificación.
6. Deduplicar eventos de uso.
7. Calcular pesos de asignación.
8. Aplicar políticas versionadas.
9. Calcular costes por transacción.
10. Reconciliar con facturación.
11. Publicar agregados diarios.
12. Refrescar dashboards de producto y finanzas.

- **Ejecución programada**: EventBridge Scheduler diario; orquestación simple
  (Step Functions sólo si se justifica).
- **Idempotencia**: cada ejecución reescribe la **partición** `(event_date,
  environment)` completa (*partition overwrite*), no *append*.
- **Reintentos**: por paso, con backoff; fallo → notificación.
- **Telemetría tardía / correcciones de facturación**: se reprocesa la partición
  afectada (reproceso histórico por `policy_version`).
- **Frescura y auditabilidad**: se registran *watermarks* y versiones.
- **Provisional vs. final**: coste **diario provisional**; **mensual finalizado**
  tras correcciones de facturación.
- **Sin streaming** salvo requisito concreto.

## 4.11 Calidad de datos y reconciliación

| Control | Umbral inicial (configurable) |
|---|---|
| Cobertura de clasificación de transacciones | ≥ 99 % |
| Completitud de eventos de uso | ≥ 98 % |
| Tasa de telemetría duplicada | ≤ 1 % |
| Cobertura de facturación (coste con telemetría) | ≥ 95 % |
| % coste asignado | ≥ 90 % |
| % coste no asignado | ≤ 10 % |
| Diferencia de reconciliación | ≤ 1.0 % |
| Frescura de datos | export del día previo disponible |
| Registros tardíos | reprocesados < 72 h |

Umbrales = **suposiciones operativas configurables**. Finanzas distingue
**alta confianza** (atribución directa con `resource_id`) de **estimación**
(proxies/pesos) mediante `attribution_method` y `data_quality_status`. **Ningún
dato ausente se asigna silenciosamente a 0**: va a no asignado.

**Ecuación de reconciliación:**
```
eligible_billing_cost = allocated_transaction_costs + idle_costs
                        + unallocated_costs + rounding_residual
```
En el ejemplo: 800.00 = 600.00 + 200.00 + 0.00 + 0.00.

## 4.12 Reporting de Producto, Finanzas e Infraestructura

**Producto**: coste por transacción monetaria / no monetaria; coste por subtipo;
volumen diario/mensual; tendencia de coste unitario; desglose por servicio;
variación de coste tras *releases*.

**Finanzas**: coste AWS elegible total; asignado vs. no asignado; coste por
entorno; por categoría; fijo vs. variable; coste de capacidad ociosa; variación
presupuestaria; estado de reconciliación; estado de finalización mensual.

**Infraestructura**: utilización de recursos; capacidad compartida; servicios de
alto coste; eficiencia; cobertura de asignación; anomalías de coste.

**Resumen ejecutivo (ejemplo sintético):** coste elegible diario 800.00; monetario
332.00 (0.033200/txn), no monetario 268.00 (0.006700/txn); ociosa/no asignado
200.00 (25 %); totalmente cargado 0.044267 (monetaria) / 0.008933 (no monetaria);
reconciliación 0.00.

No se construye una aplicación BI; es diseño.

## 4.13 Seguridad y gobernanza

- **Cifrado** en reposo (KMS) y en tránsito (TLS) en todo el *data lake*.
- **Fronteras de clave KMS**: clave(s) analíticas **separadas** de la CMK de datos
  de negocio de Fase 1.
- **Buckets S3 privados** (mismos controles que Fase 1: public access block, TLS).
- **IAM de mínimo privilegio** y **separación**: telemetría de aplicación y datos
  de facturación en prefijos/roles distintos; **Finanzas vs. Ingeniería** con
  límites de acceso separados.
- **Retención** por capa; **CloudTrail** para auditoría de acceso analítico.
- **Sin PAN, números de cuenta, saldos, secretos ni *payloads* financieros**: la
  telemetría de coste contiene identidades técnicas y métricas de consumo, no
  datos financieros → no introduce exposición financiera.
- **Clasificación de confianza** (no cabeceras de usuario); **reglas de asignación
  versionadas**; cálculos históricos **reproducibles**.

## 4.14 Eficiencia de coste de la plataforma FinOps

- Telemetría **compacta** y estructurada; **sin** métricas custom de alta
  cardinalidad por transacción.
- **Parquet** comprimido + **partition pruning** en Athena; reutilización de
  resultados; agregación **batch** programada.
- Retención de logs ajustada + **lifecycle S3**; datasets BI **agregados**.
- **Evitar streaming** innecesario.

**Muestreo**: muestrear trazas **sin corregir** distorsiona el coste por
transacción (subcuenta consumo). Por ello se usan **eventos de contabilidad de uso
no muestreados y ligeros** para la atribución de coste, manteniendo las **trazas
de diagnóstico muestreadas** como un canal separado.

## 4.15 Diagramas

- [arquitectura](diagrams/transaction-cost-architecture.mmd)
- [propagación de contexto](diagrams/transaction-context-propagation.mmd)
- [pipeline](diagrams/cost-allocation-pipeline.mmd)

## Supuestos y limitaciones
- Cifras **sintéticas**, no costes/precios reales de AWS.
- El coste por transacción es **estimación**, no facturación directa (CUR 2.0 no
  da coste por transacción de negocio).
- La granularidad por recurso depende del soporte del servicio y del export
  (`INCLUDE RESOURCES`, Split Cost Allocation Data).
- Proxies (Aurora) introducen error; se reportan como estimación.
- El SQL es referencia; no ejecutado contra Athena en esta fase.

## Trazabilidad de requisitos (Tarea 2)

| Requisito | Sección |
|---|---|
| Clasificación canónica + contexto sin PII | 4.1 |
| Propagación (HTTP/SQS/batch/fan-out/ventanas) + tags vs telemetría | 4.2 |
| Arquitectura (telemetría/facturación/proceso/presentación) | 4.3 |
| Matriz de cost drivers + aclaraciones (Aurora/S3) | 4.4 |
| Modelo híbrido + ecuación + marginal/asignado/cargado + conteo | 4.5 |
| Ejemplo numérico consistente + reconciliación | 4.6 |
| CUR 2.0 columnas verificadas + base única | 4.7 |
| Modelo de datos + claves lógicas vs constraints + Parquet/particiones | 4.8 |
| SQL representativo (8 pasos) | 4.9 / examples/ |
| Pipeline diario + idempotencia + tardíos/correcciones | 4.10 |
| Calidad + reconciliación + no-cero-silencioso | 4.11 |
| Dashboards Producto/Finanzas/Infra + resumen ejecutivo | 4.12 |
| Seguridad/gobernanza + sin datos financieros | 4.13 |
| Eficiencia + muestreo | 4.14 |
| Diagramas | 4.15 / diagrams/ |

## Referencias AWS
- [AWS Data Exports - CUR 2.0 line item columns](https://docs.aws.amazon.com/cur/latest/userguide/table-dictionary-cur2-line-item.html)
- [CUR 2.0 split cost allocation (ECS) columns](https://docs.aws.amazon.com/cur/latest/userguide/table-dictionary-cur2-split-line-item.html)
- [CUR 2.0 reservation columns](https://docs.aws.amazon.com/cur/latest/userguide/table-dictionary-cur2-reservation.html)
- [CUR 2.0 savings plan columns](https://docs.aws.amazon.com/cur/latest/userguide/table-dictionary-cur2-savings-plan.html)
- [Migrating from CUR to Data Exports (CUR 2.0)](https://docs.aws.amazon.com/cur/latest/userguide/dataexports-migrate.html)
- [ECS split cost allocation data](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/cost-allocation-data.html)
- [Amazon Athena (SQL on S3)](https://docs.aws.amazon.com/athena/latest/ug/what-is.html)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [Amazon SQS message attributes](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-message-metadata.html)
