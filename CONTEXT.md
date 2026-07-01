# poc-data-pipeline

A modernized, open-source data platform replacing a legacy crontab-based pipeline: ingests from database, Excel, CSV, and message-queue sources into a data lake, transforms into a warehouse and BI-ready marts.

## Language

**Critical alert**:
An alert condition meaning dashboards will show stale or wrong data if unaddressed — an extraction task failed, a dbt build failed entirely, a warehouse/service is unreachable, or a dbt error-severity test failed. Routed to the critical Teams channel.
_Avoid_: Outage, incident (too broad — a critical alert doesn't require a full service outage, just anything that breaks the freshness/correctness of the data reaching dashboards)

**Warning alert**:
An alert condition that doesn't block the pipeline but deserves attention — a dbt warn-severity test failed, a freshness check is nearing but hasn't breached its threshold, or resource usage (disk/memory) is trending up. Routed to the warning Teams channel, lower urgency than a critical alert.
_Avoid_: Error (a warning is explicitly non-blocking; "error" implies something broke)

## Payment Gateway domain

**Transaction**:
A single payment attempt moving through a fixed lifecycle: initiated → authorized → captured → settled, with failed and refunded as terminal side-branches. Every transaction has exactly one Bank and one Partner.
_Avoid_: Payment (too broad — a "payment" could refer to the whole customer-facing act, not the specific tracked record with a lifecycle)

**Bank**:
The financial institution that authorizes and settles funds for a transaction — the processing rail. A transaction has exactly one Bank.
_Avoid_: Partner, Acquirer (Acquirer is arguably more precise but "Bank" is the term this project uses; don't drift to it)

**Partner**:
The upstream entity (merchant, aggregator, or other payment service provider) that originates a transaction into the gateway. A transaction has exactly one Partner.
_Avoid_: Bank, Merchant, Client (this project uses "Partner" specifically for whoever sends the transaction in, regardless of whether they're technically a merchant or another PSP)

**Authorization Rate**:
% of initiated transactions that reach the authorized state. The metric banks/partners themselves report on and compare against.
_Avoid_: Success rate (ambiguous — always qualify as authorization or settlement rate)

**Settlement Rate**:
% of authorized transactions that reach the settled state. Distinct from Authorization Rate — a transaction can be authorized but later fail to settle.
_Avoid_: Success rate (ambiguous — always qualify as authorization or settlement rate)

**Fee Schedule**:
The pricing agreement that determines a transaction's fee: a fixed amount plus a percentage of transaction value, with the specific rate depending on the transaction's Partner and Bank. Looked up per transaction to compute revenue.
_Avoid_: Rate card, pricing (use "Fee Schedule" consistently as the canonical term)

**Gross Volume / Gross Revenue**:
Volume or revenue computed across all settled transactions, before subtracting refunds/chargebacks.
_Avoid_: Volume, Revenue (always qualify as gross or net — an unqualified number is ambiguous)

**Net Volume / Net Revenue**:
Gross Volume/Revenue minus refunded and charged-back amounts — the figure that reflects what the business actually kept. This is the headline number for company performance review; Gross is shown alongside it as context.
_Avoid_: Volume, Revenue (always qualify as gross or net — an unqualified number is ambiguous)

**Decline Reason**:
A categorized cause attached to a declined/failed Transaction (e.g. insufficient_funds, fraud_suspected, technical_error, invalid_account), so the dashboard can explain *why* a Bank or Partner's authorization rate is low, not just that it's low.
_Avoid_: Error code, failure reason (use "Decline Reason" consistently as the canonical term)
