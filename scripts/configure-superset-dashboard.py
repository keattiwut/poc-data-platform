#!/usr/bin/env python3
"""Configures the full Superset performance dashboard (Issue 06 / ADR-0007):
the ClickHouse connection, the mart_transactions dataset, all charts across
the PRD's four pillars, and the dashboard layout. Idempotent - re-running
refreshes everything in place. Replaces the Issue-02/03-era
configure-superset-clickhouse.sh, which grew this by hand in bash.

All charts read the conformed mart (mart_transactions = fact joined to
dim_date / dim_bank / dim_partner / dim_decline_reason), so no chart
re-derives its own bank/partner/date logic.

API mechanics inherited from the bash version (empirically verified against
Superset 4.1.1 there): write endpoints need the CSRF token AND its session
cookie alongside the bearer token; ratio metrics are SQL adhoc metrics;
saving query_context up front means charts render immediately.

Env: SUPERSET_ADMIN_USER/PASSWORD, CLICKHOUSE_USER/PASSWORD (Vault render).
Runs host-side against http://localhost:8088 by default (SUPERSET_URL).
"""
import json
import os
import sys
import time

import requests

BASE = os.environ.get("SUPERSET_URL", "http://localhost:8088")
DATASET_TABLE = "mart_transactions"


def wait_for_superset() -> None:
    for _ in range(30):
        try:
            if requests.get(f"{BASE}/health", timeout=5).ok:
                return
        except requests.ConnectionError:
            pass
        time.sleep(2)
    sys.exit(f"ERROR: Superset unreachable at {BASE}")


def make_session() -> requests.Session:
    s = requests.Session()
    login = s.post(f"{BASE}/api/v1/security/login", json={
        "username": os.environ["SUPERSET_ADMIN_USER"],
        "password": os.environ["SUPERSET_ADMIN_PASSWORD"],
        "provider": "db", "refresh": True,
    })
    login.raise_for_status()
    s.headers["Authorization"] = f"Bearer {login.json()['access_token']}"
    csrf = s.get(f"{BASE}/api/v1/security/csrf_token/")
    csrf.raise_for_status()
    s.headers["X-CSRFToken"] = csrf.json()["result"]
    return s


def call(s, method, path, **kwargs):
    resp = s.request(method, f"{BASE}{path}", **kwargs)
    if not resp.ok:
        sys.exit(f"ERROR: {method} {path} -> HTTP {resp.status_code}\n{resp.text}")
    return resp.json()


def find_one(s, path, col, value, extra_match=None):
    q = f"(filters:!((col:{col},opr:eq,value:'{value}')))"
    result = call(s, "GET", path, params={"q": q})["result"]
    if extra_match:
        result = [r for r in result if extra_match(r)]
    return result[0]["id"] if result else None


def sql_metric(expression: str, label: str) -> dict:
    return {"expressionType": "SQL", "sqlExpression": expression,
            "label": label, "hasCustomLabel": True}


# --- chart builders ----------------------------------------------------------

def big_number(dataset_id: int, metric: dict) -> tuple[dict, dict]:
    params = {"datasource": f"{dataset_id}__table", "viz_type": "big_number_total",
              "metric": metric, "adhoc_filters": []}
    query_context = {
        "datasource": {"id": dataset_id, "type": "table"}, "force": False,
        "queries": [{"metrics": [metric], "groupby": [], "extras": {},
                     "orderby": [], "annotation_layers": [], "row_limit": 1,
                     "time_offsets": [], "post_processing": [],
                     "time_range": "No filter", "is_timeseries": False}],
        "form_data": params, "result_format": "json", "result_type": "full",
    }
    return params, query_context


def bar_chart(dataset_id: int, x_axis: str, metrics: list, groupby=None,
              time_grain=None, filters=None) -> tuple[dict, dict]:
    """echarts_timeseries_bar over either a time axis (x_axis + time_grain,
    the shape verified for 'Transaction Volume by Day') or a categorical
    axis (plain groupby columns)."""
    groupby = groupby or []
    params = {"datasource": f"{dataset_id}__table",
              "viz_type": "echarts_timeseries_bar", "x_axis": x_axis,
              "metrics": metrics, "groupby": groupby, "adhoc_filters": [],
              "row_limit": 10000}
    query: dict = {"metrics": metrics, "annotation_layers": [], "orderby": [],
                   "row_limit": 10000, "time_offsets": [], "post_processing": [],
                   "time_range": "No filter", "filters": filters or []}
    if time_grain:
        params["time_grain_sqla"] = time_grain
        params["granularity_sqla"] = x_axis
        query.update({"granularity": x_axis, "groupby": groupby,
                      "columns": ["__timestamp"],
                      "extras": {"time_grain_sqla": time_grain},
                      "is_timeseries": True, "order_desc": True})
    else:
        query.update({"groupby": [], "columns": [x_axis, *groupby],
                      "extras": {}, "is_timeseries": False})
    query_context = {
        "datasource": {"id": dataset_id, "type": "table"}, "force": False,
        "queries": [query], "form_data": params,
        "result_format": "json", "result_type": "full",
    }
    return params, query_context


def ensure_chart(s, name: str, viz_type: str, dataset_id: int,
                 params: dict, query_context: dict) -> int:
    body = {"params": json.dumps(params),
            "query_context": json.dumps(query_context),
            "query_context_generation": True}
    chart_id = find_one(s, "/api/v1/chart/", "slice_name", name)
    if chart_id:
        call(s, "PUT", f"/api/v1/chart/{chart_id}", json=body)
        print(f"Refreshed chart '{name}' ({chart_id})")
    else:
        body |= {"slice_name": name, "viz_type": viz_type,
                 "datasource_id": dataset_id, "datasource_type": "table"}
        chart_id = call(s, "POST", "/api/v1/chart/", json=body)["id"]
        print(f"Created chart '{name}' ({chart_id})")
    return chart_id


def main() -> None:
    wait_for_superset()
    s = make_session()

    # --- database + dataset (check-before-create) ---------------------------
    # In-network address: Superset talks to ClickHouse over the Compose
    # network (8123), not the host-remapped 8124.
    uri = (f"clickhousedb://{os.environ['CLICKHOUSE_USER']}:"
           f"{os.environ['CLICKHOUSE_PASSWORD']}@clickhouse:8123/default")
    db_id = find_one(s, "/api/v1/database/", "database_name", "ClickHouse")
    if db_id:
        call(s, "PUT", f"/api/v1/database/{db_id}", json={"sqlalchemy_uri": uri})
        print(f"Refreshed database connection ({db_id})")
    else:
        db_id = call(s, "POST", "/api/v1/database/",
                     json={"database_name": "ClickHouse", "sqlalchemy_uri": uri})["id"]
        print(f"Created database connection ({db_id})")

    dataset_id = find_one(s, "/api/v1/dataset/", "table_name", DATASET_TABLE,
                          extra_match=lambda d: d.get("database", {}).get("id") == db_id)
    if not dataset_id:
        dataset_id = call(s, "POST", "/api/v1/dataset/", json={
            "database": db_id, "table_name": DATASET_TABLE, "schema": "default",
        })["id"]
        print(f"Created dataset '{DATASET_TABLE}' ({dataset_id})")
    else:
        print(f"Found dataset '{DATASET_TABLE}' ({dataset_id})")
    # Re-sync column metadata from the live view: dbt rebuilds can change the
    # mart's columns, and charts validate against Superset's cached copy.
    call(s, "PUT", f"/api/v1/dataset/{dataset_id}/refresh")
    print(f"Refreshed dataset '{DATASET_TABLE}' column metadata")

    # --- charts: the PRD's four pillars on the conformed mart ---------------
    settled = "settled_at IS NOT NULL AND refunded_at IS NULL"
    charts: list[tuple[str, str, dict, dict]] = []

    def add(name, viz, built):
        charts.append((name, viz, *built))

    # Pillar 1: Volume (Gross and Net)
    add("Transaction Volume by Day", "echarts_timeseries_bar",
        bar_chart(dataset_id, "initiated_at", ["count"], time_grain="P1D"))
    add("Gross Volume (USD)", "big_number_total",
        big_number(dataset_id, sql_metric("sum(amount_cents) / 100", "Gross Volume (USD)")))
    add("Net Volume (USD)", "big_number_total",
        big_number(dataset_id, sql_metric(f"sumIf(amount_cents, {settled}) / 100", "Net Volume (USD)")))
    # Period comparison via dim_date's week_start (WoW).
    add("Weekly Gross vs Net Volume", "echarts_timeseries_bar",
        bar_chart(dataset_id, "week_start",
                  [sql_metric("sum(amount_cents) / 100", "Gross Volume (USD)"),
                   sql_metric(f"sumIf(amount_cents, {settled}) / 100", "Net Volume (USD)")]))

    # Pillar 2: Authorization Rate and Settlement Rate
    add("Authorization Rate", "big_number_total",
        big_number(dataset_id, sql_metric(
            "countIf(authorized_at IS NOT NULL) / countIf(initiated_at IS NOT NULL) * 100",
            "Authorization Rate")))
    add("Settlement Rate", "big_number_total",
        big_number(dataset_id, sql_metric(
            "countIf(settled_at IS NOT NULL) / countIf(authorized_at IS NOT NULL) * 100",
            "Settlement Rate")))

    # Pillar 3: Revenue (Gross and Net)
    add("Gross Revenue", "big_number_total",
        big_number(dataset_id, sql_metric("sum(fee_amount_cents) / 100", "Gross Revenue (USD)")))
    add("Net Revenue", "big_number_total",
        big_number(dataset_id, sql_metric(f"sumIf(fee_amount_cents, {settled}) / 100", "Net Revenue (USD)")))

    # Pillar 4: Bank/Partner comparison
    add("Volume by Bank", "echarts_timeseries_bar",
        bar_chart(dataset_id, "bank_id", ["count"]))
    add("Volume by Partner", "echarts_timeseries_bar",
        bar_chart(dataset_id, "partner_id", ["count"]))

    # Decline Reason breakdown per Bank/Partner
    not_null_reason = [{"col": "effective_decline_reason", "op": "IS NOT NULL"}]
    add("Decline Reasons by Bank", "echarts_timeseries_bar",
        bar_chart(dataset_id, "bank_id", ["count"],
                  groupby=["effective_decline_reason"], filters=not_null_reason))
    add("Decline Reasons by Partner", "echarts_timeseries_bar",
        bar_chart(dataset_id, "partner_id", ["count"],
                  groupby=["effective_decline_reason"], filters=not_null_reason))

    ids = {name: ensure_chart(s, name, viz, dataset_id, params, qc)
           for name, viz, params, qc in charts}

    # --- dashboard + layout -------------------------------------------------
    dash_id = find_one(s, "/api/v1/dashboard/", "dashboard_title", "Payment Gateway Performance")
    if not dash_id:
        dash_id = call(s, "POST", "/api/v1/dashboard/", json={
            "dashboard_title": "Payment Gateway Performance",
            "slug": "payment-gateway-performance",
        })["id"]
        print(f"Created dashboard ({dash_id})")

    for chart_id in ids.values():
        call(s, "PUT", f"/api/v1/chart/{chart_id}", json={"dashboards": [dash_id]})

    rows = [  # (row of (chart name, grid width)); Superset grid is 12 wide
        [("Transaction Volume by Day", 12)],
        [("Authorization Rate", 3), ("Settlement Rate", 3),
         ("Gross Revenue", 3), ("Net Revenue", 3)],
        [("Gross Volume (USD)", 6), ("Net Volume (USD)", 6)],
        [("Weekly Gross vs Net Volume", 12)],
        [("Volume by Bank", 6), ("Volume by Partner", 6)],
        [("Decline Reasons by Bank", 6), ("Decline Reasons by Partner", 6)],
    ]
    position = {
        "DASHBOARD_VERSION_KEY": "v2",
        "ROOT_ID": {"type": "ROOT", "id": "ROOT_ID", "children": ["GRID_ID"]},
        "GRID_ID": {"type": "GRID", "id": "GRID_ID", "parents": ["ROOT_ID"],
                    "children": [f"ROW-{i}" for i in range(1, len(rows) + 1)]},
    }
    for i, row in enumerate(rows, start=1):
        row_id = f"ROW-{i}"
        position[row_id] = {"type": "ROW", "id": row_id,
                            "children": [f"CHART-{ids[n]}" for n, _ in row],
                            "parents": ["ROOT_ID", "GRID_ID"],
                            "meta": {"background": "BACKGROUND_TRANSPARENT"}}
        for name, width in row:
            key = f"CHART-{ids[name]}"
            position[key] = {"type": "CHART", "id": key, "children": [],
                             "parents": ["ROOT_ID", "GRID_ID", row_id],
                             "meta": {"chartId": ids[name], "width": width,
                                      "height": 50, "sliceName": name}}
    call(s, "PUT", f"/api/v1/dashboard/{dash_id}",
         json={"position_json": json.dumps(position)})

    print(f"PASS: database ({db_id}), dataset ({dataset_id}), "
          f"{len(ids)} charts, dashboard 'Payment Gateway Performance' ({dash_id}) configured")


if __name__ == "__main__":
    main()
