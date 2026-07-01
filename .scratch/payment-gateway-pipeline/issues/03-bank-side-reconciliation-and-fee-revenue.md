Status: ready-for-agent

# Add Bank-side source + full reconciliation + fee revenue

## Parent

`.scratch/payment-gateway-pipeline/PRD.md`

## What to build

Extend the walking skeleton with the Bank side of every Transaction, and make reconciliation real.

Extend the mock generator so each Transaction it creates emits both a Partner-side view (as in the previous slice) and a correlated Bank-side view sharing the same gateway-assigned Transaction ID, written into a second mock Postgres source (or the same instance, a separate table/schema representing the Bank's system).

Update the dbt model to perform the actual full outer join between Bank-side and Partner-side staging models on Transaction ID (ADR-0009, ADR-0012): a Transaction is visible in `fct_transactions` as soon as either side has reported it, with null attributes on whichever side hasn't arrived. Compute the transaction's fee at capture time using the Fee Schedule (fixed + percentage, varying per Partner/Bank) and store it denormalized directly on the fact row (ADR-0011) — do not join to a live rates table at query time.

With both sides reconciled, Authorization Rate and Settlement Rate (CONTEXT.md) become computable as two distinct metrics. Add both to the Superset dashboard, along with Gross Revenue (sum of the captured fee amounts).

## Acceptance criteria

- [ ] Mock generator emits correlated Bank-side and Partner-side records sharing the same Transaction ID
- [ ] `fct_transactions` full-outer-joins both sides on Transaction ID; a transaction with only one side reported is still visible with nulls on the other side
- [ ] Fee amount is computed once at capture time and stored on the fact row, not recomputed via a live rates join
- [ ] Authorization Rate and Settlement Rate are computed as two distinct metrics, never collapsed into a single "success rate"
- [ ] Superset dashboard shows Authorization Rate, Settlement Rate, and Gross Revenue
- [ ] A test scenario exists where a transaction has only Bank-side or only Partner-side data, and the fact table handles it without erroring

## Blocked by

- 02-walking-skeleton-single-source.md
