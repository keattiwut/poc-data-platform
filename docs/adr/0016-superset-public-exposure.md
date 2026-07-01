# Superset exposed publicly, all other UIs internal-only

Superset is reachable from outside the internal network (for staff checking performance remotely), while Airflow, Grafana, and the MinIO console stay internal-network/VPN-only. This was a deliberate choice over keeping everything internal — Superset is the one UI end users actually need day-to-day access to, while Airflow/Grafana/MinIO are operator-only tools with no reason to be internet-reachable (and Airflow's webserver in particular has a real history of being a target when exposed without hardening).

Because this adds real attack surface, publicly exposing Superset requires: TLS termination, no default/example credentials, and rate limiting on the login endpoint at minimum. These must be in place before Superset is actually exposed — this ADR records the *decision*, not that the hardening is done.
