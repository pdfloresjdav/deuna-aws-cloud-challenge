-- ============================================================================
-- Transaction-level cost allocation - representative Athena (Trino) SQL.
--
-- ILLUSTRATIVE REFERENCE ONLY. This was NOT executed against Athena in this
-- phase. It is written for Athena's Trino-based dialect (WITH, window
-- functions, DECIMAL, NULLIF, COUNT(DISTINCT)).
--
-- Expected input tables (normalized analytical model; see docs/02):
--   transaction_fact(
--     transaction_id, transaction_category, transaction_type, outcome,
--     environment, event_date, schema_version)
--   resource_usage_fact(
--     usage_id, transaction_id, attempt_id, resource_type, resource_id,
--     usage_dimension, usage_quantity, billing_window, environment,
--     event_date, schema_version, ingest_timestamp)
--   aws_billing_fact(                       -- normalized from CUR 2.0
--     billing_window, resource_type, resource_id, service, usage_type,
--     line_item_type, cost_basis_amount, currency, environment, event_date)
--
-- Conventions:
--   * cost_basis_amount = single normalized net-amortized basis (see docs 4.7).
--   * Allocation grain = (resource_type, billing_window). resource_id-level is
--     analogous by adding resource_id to the GROUP BY / JOIN keys.
--   * Retries (attempt_id) add to consumption but NOT to the txn denominator.
--   * Missing/zero denominators -> cost preserved as unallocated (never 0).
-- Parameters: set :run_date and :env before running.
-- ============================================================================

-- Step 1: Deduplicate telemetry (keep the latest row per usage_id).
WITH usage_dedup AS (
    SELECT *
    FROM (
        SELECT
            u.*,
            ROW_NUMBER() OVER (
                PARTITION BY u.usage_id
                ORDER BY u.ingest_timestamp DESC
            ) AS rn
        FROM resource_usage_fact u
        WHERE u.event_date = DATE :run_date
          AND u.environment = :env
    )
    WHERE rn = 1
),

-- Step 2: Aggregate usage by resource_type, billing_window and transaction
--         (joined to its canonical category). Retries collapse into the
--         business transaction via transaction_id.
usage_by_txn AS (
    SELECT
        d.resource_type,
        d.billing_window,
        d.transaction_id,
        t.transaction_category,
        t.transaction_type,
        t.outcome,
        CAST(SUM(d.usage_quantity) AS DECIMAL(38, 10)) AS txn_weight
    FROM usage_dedup d
    JOIN transaction_fact t
      ON t.transaction_id = d.transaction_id
     AND t.event_date = DATE :run_date
     AND t.environment = :env
    GROUP BY
        d.resource_type, d.billing_window, d.transaction_id,
        t.transaction_category, t.transaction_type, t.outcome
),

-- Step 3: Shared-resource weights = total eligible consumption per
--         resource_type + billing_window (the allocation denominator).
weights_total AS (
    SELECT
        resource_type,
        billing_window,
        CAST(SUM(txn_weight) AS DECIMAL(38, 10)) AS total_weight
    FROM usage_by_txn
    GROUP BY resource_type, billing_window
),

-- Eligible billing cost pool per resource_type + billing_window.
-- Exclude non-usage line item types (tax/credit/refund) from the usage pool.
billing_eligible AS (
    SELECT
        b.resource_type,
        b.billing_window,
        CAST(SUM(b.cost_basis_amount) AS DECIMAL(38, 10)) AS eligible_cost
    FROM aws_billing_fact b
    WHERE b.event_date = DATE :run_date
      AND b.environment = :env
      AND b.line_item_type IN ('Usage', 'DiscountedUsage', 'SavingsPlanCoveredUsage')
    GROUP BY b.resource_type, b.billing_window
),

-- Step 4: Allocate eligible cost proportionally to each transaction.
--         NULLIF guards division by zero.
allocated AS (
    SELECT
        ubt.resource_type,
        ubt.billing_window,
        ubt.transaction_id,
        ubt.transaction_category,
        ubt.transaction_type,
        ubt.outcome,
        be.eligible_cost,
        wt.total_weight,
        CASE
            WHEN wt.total_weight IS NULL OR wt.total_weight = 0 THEN CAST(0 AS DECIMAL(38, 10))
            ELSE CAST(
                be.eligible_cost * (ubt.txn_weight / NULLIF(wt.total_weight, 0))
                AS DECIMAL(38, 10))
        END AS allocated_cost
    FROM usage_by_txn ubt
    JOIN weights_total wt
      ON wt.resource_type = ubt.resource_type
     AND wt.billing_window = ubt.billing_window
    JOIN billing_eligible be
      ON be.resource_type = ubt.resource_type
     AND be.billing_window = ubt.billing_window
),

-- Step 5: Preserve idle / unallocated cost per resource_type + billing_window.
--         unallocated = eligible cost whose resource+window had no usage.
--         idle/residual = eligible - sum(allocated) for matched resources.
allocated_rollup AS (
    SELECT
        resource_type,
        billing_window,
        CAST(SUM(allocated_cost) AS DECIMAL(38, 10)) AS allocated_cost
    FROM allocated
    GROUP BY resource_type, billing_window
),
idle_unallocated AS (
    SELECT
        be.resource_type,
        be.billing_window,
        be.eligible_cost,
        COALESCE(ar.allocated_cost, CAST(0 AS DECIMAL(38, 10))) AS allocated_cost,
        CAST(be.eligible_cost - COALESCE(ar.allocated_cost, 0) AS DECIMAL(38, 10))
            AS idle_or_unallocated_cost
    FROM billing_eligible be
    LEFT JOIN allocated_rollup ar
      ON ar.resource_type = be.resource_type
     AND ar.billing_window = be.billing_window
),

-- Step 6: Aggregate allocated cost by transaction category and type.
cost_by_category AS (
    SELECT
        transaction_category,
        transaction_type,
        CAST(SUM(allocated_cost) AS DECIMAL(38, 10)) AS allocated_cost
    FROM allocated
    GROUP BY transaction_category, transaction_type
),

-- Step 7: Unit costs with DISTINCT business transaction counts
--         (attempted = all; successful = outcome SUCCESS). Retries excluded
--         from the denominator by COUNT(DISTINCT transaction_id).
txn_counts AS (
    SELECT
        transaction_category,
        COUNT(DISTINCT transaction_id) AS attempted_txns,
        COUNT(DISTINCT CASE WHEN outcome = 'SUCCESS' THEN transaction_id END) AS successful_txns
    FROM transaction_fact
    WHERE event_date = DATE :run_date
      AND environment = :env
    GROUP BY transaction_category
),
category_alloc AS (
    SELECT
        transaction_category,
        CAST(SUM(allocated_cost) AS DECIMAL(38, 10)) AS allocated_cost
    FROM cost_by_category
    GROUP BY transaction_category
),
unit_costs AS (
    SELECT
        c.transaction_category,
        c.allocated_cost,
        n.attempted_txns,
        n.successful_txns,
        CASE WHEN n.attempted_txns = 0 THEN NULL
             ELSE CAST(c.allocated_cost / NULLIF(n.attempted_txns, 0) AS DECIMAL(38, 10))
        END AS cost_per_attempted_txn,
        CASE WHEN n.successful_txns = 0 THEN NULL
             ELSE CAST(c.allocated_cost / NULLIF(n.successful_txns, 0) AS DECIMAL(38, 10))
        END AS cost_per_successful_txn
    FROM category_alloc c
    JOIN txn_counts n USING (transaction_category)
)

-- Primary result: unit costs per category.
SELECT * FROM unit_costs ORDER BY transaction_category;

-- Step 8: Reconciliation (run separately):
--   eligible = allocated + idle/unallocated + rounding_residual
-- SELECT
--     CAST(SUM(eligible_cost) AS DECIMAL(38, 10))               AS eligible_cost,
--     CAST(SUM(allocated_cost) AS DECIMAL(38, 10))              AS allocated_cost,
--     CAST(SUM(idle_or_unallocated_cost) AS DECIMAL(38, 10))    AS idle_or_unallocated_cost,
--     CAST(SUM(eligible_cost) - SUM(allocated_cost) - SUM(idle_or_unallocated_cost)
--          AS DECIMAL(38, 10))                                  AS rounding_residual
-- FROM idle_unallocated;
