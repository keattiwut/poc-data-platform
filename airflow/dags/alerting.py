"""Airflow task-failure alerting (Issue 08 / ADR-0008): posts a Microsoft
Teams card to the same two severity channels Alertmanager routes to, per
CONTEXT.md's definitions - an extraction task or dbt build failure is
Critical; mock-data tooling failures are Warning (non-blocking for the
business pipeline).

The webhook URLs default to the in-stack mock-teams receiver; production
points TEAMS_CRITICAL_WEBHOOK_URL / TEAMS_WARNING_WEBHOOK_URL at real Teams
incoming webhooks (secrets -> Vault render) without touching this code.
"""
import json
import os
import urllib.request

RUNBOOK_BASE = "https://github.com/keattiwut/poc-data-platform/blob/master/docs/runbooks"
RUNBOOKS = {
    "dbt_build": f"{RUNBOOK_BASE}/dbt-build-failed.md",
    "dbt_source_freshness": f"{RUNBOOK_BASE}/dbt-build-failed.md",
}
DEFAULT_RUNBOOK = f"{RUNBOOK_BASE}/extraction-task-failed.md"


def _notify(context, severity: str) -> None:
    ti = context["task_instance"]
    runbook = RUNBOOKS.get(ti.task_id, DEFAULT_RUNBOOK)
    url = os.environ.get(
        f"TEAMS_{severity.upper()}_WEBHOOK_URL",
        f"http://mock-teams:8080/{severity}",
    )
    card = {
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "themeColor": "d63333" if severity == "critical" else "e8a33d",
        "title": f"[{severity.upper()}] Airflow task failed: {ti.dag_id}.{ti.task_id}",
        "text": f"Run {context['run_id']} - see the runbook before digging: {runbook}",
        "potentialAction": [{
            "@type": "OpenUri",
            "name": "Runbook",
            "targets": [{"os": "default", "uri": runbook}],
        }],
    }
    request = urllib.request.Request(
        url, data=json.dumps(card).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(request, timeout=10)
    except OSError as exc:
        # Alerting must never mask the original task failure.
        print(f"WARNING: failed to deliver {severity} alert to {url}: {exc}")


def notify_critical(context) -> None:
    _notify(context, "critical")


def notify_warning(context) -> None:
    _notify(context, "warning")
