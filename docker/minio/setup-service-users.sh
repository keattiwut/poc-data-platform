#!/bin/sh
# Per-service least-privilege MinIO users + bucket encryption (Issue 09,
# ADR-0017, review finding 7). Runs inside minio-init (mc image) after the
# bucket exists; idempotent. Root credentials are used HERE ONLY - every
# pipeline consumer gets its own scoped user:
#   svc_extraction  read/write bronze/   (dlt tasks, incl. its state files)
#   svc_promotion   read bronze/, write silver/   (promotion job)
#   svc_warehouse   read silver/ only    (ClickHouse s3() named collection,
#                                         i.e. dbt's staging views + Superset)
set -eu

alias_() { mc alias set local https://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"; }
alias_ > /dev/null

make_policy() {
  name="$1"; file="/tmp/${name}.json"; cat > "$file"
  mc admin policy create local "$name" "$file" > /dev/null
  echo "policy: $name"
}

make_policy extraction-rw-bronze <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
     "Resource": ["arn:aws:s3:::data-lake"]},
    {"Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
     "Resource": ["arn:aws:s3:::data-lake/bronze/*"]}
  ]
}
EOF

make_policy promotion-bronze-ro-silver-rw <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
     "Resource": ["arn:aws:s3:::data-lake"]},
    {"Effect": "Allow", "Action": ["s3:GetObject"],
     "Resource": ["arn:aws:s3:::data-lake/bronze/*"]},
    {"Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
     "Resource": ["arn:aws:s3:::data-lake/silver/*"]}
  ]
}
EOF

make_policy warehouse-silver-ro <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
     "Resource": ["arn:aws:s3:::data-lake"]},
    {"Effect": "Allow", "Action": ["s3:GetObject"],
     "Resource": ["arn:aws:s3:::data-lake/silver/*"]}
  ]
}
EOF

make_user() {
  user="$1"; password="$2"; policy="$3"
  # `mc admin user add` is an upsert (updates the secret if the user exists).
  mc admin user add local "$user" "$password" > /dev/null
  mc admin policy attach local "$policy" --user "$user" > /dev/null 2>&1 \
    || true  # attach fails if already attached; that's the idempotent case
  echo "user: $user -> $policy"
}

make_user "$MINIO_EXTRACTION_USER" "$MINIO_EXTRACTION_PASSWORD" extraction-rw-bronze
make_user "$MINIO_PROMOTION_USER" "$MINIO_PROMOTION_PASSWORD" promotion-bronze-ro-silver-rw
make_user "$MINIO_WAREHOUSE_USER" "$MINIO_WAREHOUSE_PASSWORD" warehouse-silver-ro

# Server-side encryption for the whole lake bucket (ADR-0017): SSE-S3 backed
# by MinIO's built-in KMS (MINIO_KMS_SECRET_KEY on the minio service).
mc encrypt set sse-s3 local/data-lake > /dev/null
echo "bucket encryption: sse-s3 on data-lake"
echo "MinIO service users, policies, and bucket SSE configured."
