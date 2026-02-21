#!/usr/bin/env bash
set -euo pipefail

# Cloudflare API token test for DNS-01
# - Loads DOMAIN and CLOUDFLARE_API_TOKEN from config/kubernetes.env
# - Looks up zone ID (tests Zone:Read)
# - Creates a TXT record (tests Zone:DNS:Edit)
# - Verifies retrieval, then deletes it

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f config/kubernetes.env ]]; then
  echo "config/kubernetes.env not found. Copy config/kubernetes.env.example and fill values." >&2
  exit 1
fi

set -a
source config/kubernetes.env
set +a

API="https://api.cloudflare.com/client/v4"

echo "[1/4] Zone lookup for $DOMAIN"
ZSTATUS=$(curl -sS -o /tmp/cf_zones.json -w "%{http_code}\n" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "$API/zones?name=$DOMAIN")
echo "zones HTTP: $ZSTATUS"

python3 - <<'PY'
import json
try:
  data=json.load(open('/tmp/cf_zones.json'))
  print('zones success:', data.get('success'))
  res=data.get('result') or []
  zid=(res[0].get('id') if res else '')
  print('zone id:', zid)
except Exception as e:
  print('parse error:', e)
PY

ZID=$(python3 - <<'PY'
import json
try:
  data=json.load(open('/tmp/cf_zones.json'))
  res=data.get('result') or []
  print(res[0].get('id',''))
except Exception:
  print('')
PY
)
if [[ -z "$ZID" ]]; then
  echo "Zone ID not found. Token may lack Zone:Read permission or domain mismatch." >&2
  exit 1
fi

echo "[2/4] Create TXT _acme-challenge.token-check.$DOMAIN"
RAND=$(head -c 12 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 10)
NAME="_acme-challenge.token-check.$DOMAIN"
VALUE="test-$RAND"

CSTATUS=$(curl -sS -o /tmp/cf_create.json -w "%{http_code}\n" -X POST \
  "$API/zones/$ZID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"TXT\",\"name\":\"$NAME\",\"content\":\"$VALUE\",\"ttl\":120}")
echo "create HTTP: $CSTATUS"

python3 - <<'PY'
import json
data=json.load(open('/tmp/cf_create.json'))
print('create success:', data.get('success'))
print('created id:', (data.get('result') or {}).get('id',''))
PY

RID=$(python3 - <<'PY'
import json
try:
  data=json.load(open('/tmp/cf_create.json'))
  print((data.get('result') or {}).get('id',''))
except Exception:
  print('')
PY
)
if [[ -z "$RID" ]]; then
  echo "Create failed. Token may lack Zone:DNS:Edit permission." >&2
  echo "Response: $(head -c 400 /tmp/cf_create.json)" >&2
  exit 1
fi

echo "[3/4] Verify TXT retrieval"
GSTATUS=$(curl -sS -o /tmp/cf_get.json -w "%{http_code}\n" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "$API/zones/$ZID/dns_records?type=TXT&name=$NAME")
echo "get HTTP: $GSTATUS"

python3 - <<'PY'
import json
data=json.load(open('/tmp/cf_get.json'))
print('get success:', data.get('success'))
res=data.get('result') or []
print('get count:', len(res))
print('get content:', (res[0] if res else {}).get('content',''))
PY

echo "[4/4] Cleanup test record"
DSTATUS=$(curl -sS -o /tmp/cf_del.json -w "%{http_code}\n" -X DELETE \
  "$API/zones/$ZID/dns_records/$RID" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json")
echo "delete HTTP: $DSTATUS"

python3 - <<'PY'
import json
data=json.load(open('/tmp/cf_del.json'))
print('delete success:', data.get('success'))
PY

echo "DONE: Cloudflare token test completed"
