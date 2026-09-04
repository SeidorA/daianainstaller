#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/utils/npm_ssl_bootstrap.sh"
DOCS="$ROOT_DIR/docs/certs.md"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"

suite_xtrace_was_enabled=0
case "$-" in
  *x*) suite_xtrace_was_enabled=1; set +x ;;
esac
set -a
export NPM_ADMIN_EMAIL=admin@example.test NPM_ADMIN_PASS=super-secret
set +a
if (( suite_xtrace_was_enabled )); then
  set -x
fi

bash() {
  local xtrace_was_enabled=0
  local child_status
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  command bash "$@"
  child_status=$?
  if (( xtrace_was_enabled )); then
    set -x
  fi
  return "$child_status"
}

# NPM 2.15.1 normalizes an empty advanced_config from null to an empty string.
# Emit and compare the canonical empty representation to keep readback checks stable.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    payload="$(proxy_host_payload nginx nginx.example.test npm 81 "")"
    jq -e '\''type == "object" and .advanced_config == ""'\'' <<<"$payload" >/dev/null
    init_proxy_rollback
    expected='\''{"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}'\''
    actual="${expected/null/\"\"}"
    same_proxy_host_state "$expected" "$actual"
  ' _ "$SCRIPT"
printf 'mock certificate\n' > "$TMP_DIR/local-nginx.crt"
printf 'mock private key\n' > "$TMP_DIR/local-nginx.key"

cat > "$MOCK_BIN/openssl" <<'MOCK'
#!/usr/bin/env bash
set -u
scenario="${NPM_TEST_SCENARIO:-}"
case "$scenario" in
  custom-success|custom-tls-failure|custom-san-mismatch|custom-expired|custom-malformed) ;;
  *) exit 1 ;;
esac
[[ "${1:-}" == x509 ]] || exit 2
certificate_file=""
requested_host=""
checkend=""
for ((i = 2; i <= $#; i++)); do
  case "${!i}" in
    -in) i=$((i + 1)); certificate_file="${!i}" ;;
    -checkend) i=$((i + 1)); checkend="${!i}" ;;
    -checkhost) i=$((i + 1)); requested_host="${!i}" ;;
  esac
done
[[ -n "$certificate_file" && -f "$certificate_file" ]] || exit 3
[[ -n "$checkend" || -n "$requested_host" || ( "$#" -eq 4 && "${4:-}" == -noout ) ]] || exit 4
fixture_san=""
fixture_expiry=""
first_line=""
last_line=""
while IFS='=' read -r key value; do
  [[ -n "$first_line" ]] || first_line="$key${value:+=$value}"
  last_line="$key${value:+=$value}"
  case "$key" in
    SAN) fixture_san="$value" ;;
    NOT_AFTER) fixture_expiry="$value" ;;
  esac
done < "$certificate_file"
[[ "$first_line" == '-----BEGIN MOCK CERTIFICATE-----' && "$last_line" == '-----END MOCK CERTIFICATE-----' ]] || exit 5
[[ -n "$fixture_san" && -n "$fixture_expiry" ]] || exit 6

if [[ -n "$checkend" ]]; then
  [[ "$checkend" == 0 ]] || exit 7
  expiry_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$fixture_expiry" '+%s' 2>/dev/null || date -u -d "$fixture_expiry" '+%s' 2>/dev/null)" || exit 8
  (( expiry_epoch > $(date -u '+%s') )) || exit 9
fi
if [[ -n "$requested_host" ]]; then
  [[ "$requested_host" == "$fixture_san" ]] || exit 10
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/openssl"

cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
set -u
scenario="${NPM_TEST_SCENARIO:?}"
state_file="${NPM_TEST_STATE:?}"
url=""
method=GET
payload_arg=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in
    http://*|https://*) url="${!i}" ;;
    -X) i=$((i + 1)); method="${!i}" ;;
    -d|--data|--data-raw) i=$((i + 1)); payload_arg="${!i}" ;;
    --data-binary)
      i=$((i + 1))
      if [[ "${!i}" == @- ]]; then payload_arg="$(cat)"; else payload_arg="${!i}"; fi
      ;;
  esac
done
if [[ "$url" == https://* ]]; then
  [[ "$scenario" != "tls-failure" && "$scenario" != "custom-tls-failure" ]] || exit 60
  if [[ "$scenario" == tls-http-401 ]]; then
    for arg in "$@"; do
      [[ "$arg" != --fail ]] || exit 55
    done
    printf '{}\n401\n'
    exit 0
  fi
  if [[ "$scenario" == post-mutation-tls-reload ]]; then
    tls_probe_file="${state_file}.tls-probes"
    tls_probes=0
    [[ -f "$tls_probe_file" ]] && tls_probes="$(<"$tls_probe_file")"
    tls_probes=$((tls_probes + 1))
    printf '%s' "$tls_probes" > "$tls_probe_file"
    [[ "$tls_probes" -gt 1 ]] || exit 60
  fi
  requested_hostname="${url#https://}"
  requested_hostname="${requested_hostname%%/*}"
  requested_hostname="${requested_hostname%%:*}"
  expected_hostname="nginx.example.test"
  [[ "$scenario" == "issuance-after-mutation-main" || "$scenario" == verification-after-mutation-* ]] && expected_hostname="api.example.test"
  [[ "$scenario" == "tls-hostname-mismatch" ]] && expected_hostname="other.example.test"
  if [[ "$scenario" == verification-after-mutation-* && "$requested_hostname" == "nginx.example.test" ]]; then
    exit 60
  fi
  if [[ "$requested_hostname" != "$expected_hostname" ]]; then
    printf 'mock TLS hostname mismatch: requested %s, certificate SAN %s\n' \
      "$requested_hostname" "$expected_hostname" >&2
    exit 51
  fi
  printf 'HTTPS %s\n' "$url" >> "$state_file.order"
  printf '{}\n200\n'
  exit 0
fi
path="${url#http://127.0.0.1:81}"
printf '%s %s\n' "$method" "$path" >> "$state_file.order"
count=0
[[ -f "$state_file" ]] && count="$(<"$state_file")"
mutation_file="${state_file}.mutations"
mutations=0
[[ -f "$mutation_file" ]] && mutations="$(<"$mutation_file")"
proxy_state_file="${state_file}.proxy-state"
[[ -f "$proxy_state_file" ]] || printf 'baseline' > "$proxy_state_file"
if [[ "$path" == /api/nginx/certificates/* ]]; then
  certificate_url_calls=0
  certificate_url_calls_file="${state_file}.certificate-url-calls"
  [[ -f "$certificate_url_calls_file" ]] && certificate_url_calls="$(<"$certificate_url_calls_file")"
  certificate_url_calls=$((certificate_url_calls + 1))
  printf '%s' "$certificate_url_calls" > "$certificate_url_calls_file"
fi
if [[ "$path" == "/api/" ]]; then
  count=$((count + 1)); printf '%s' "$count" > "$state_file"
  if [[ "$scenario" == "timeout" ]]; then exit 7; fi
  if [[ "$scenario" == "transient" && "$count" == 1 ]]; then exit 56; fi
  printf '{}\n200\n'
  exit 0
fi

if { [[ "$method" == PUT && "$path" == /api/nginx/proxy-hosts/* ]] ||
     [[ "$method" == POST && "$path" == /api/nginx/proxy-hosts ]]; }; then
  payload="$payload_arg"
  mutations=$((mutations + 1))
  printf '%s' "$mutations" > "$mutation_file"
   if [[ "$scenario" == success || "$scenario" == verification-after-mutation-* || "$scenario" == issuance-after-mutation-main || "$scenario" == http-only-transition || "$scenario" == http-only-post-tls-failure ]] && [[ "$path" == "/api/nginx/proxy-hosts/7" ]]; then
     required_payload_keys='["domain_names","forward_scheme","forward_host","forward_port","certificate_id","ssl_forced","hsts_enabled","hsts_subdomains","trust_forwarded_proto","http2_support","block_exploits","caching_enabled","allow_websocket_upgrade","access_list_id","advanced_config","enabled","locations"]'
     jq -e --argjson required "$required_payload_keys" '. as $object | type == "object" and ($required | all(.[]; . as $key | $object | has($key)))' <<<"$payload" >/dev/null || exit 62
     printf '%s' "$payload" > "${state_file}.proxy-host-7-put-${mutations}.json"
     printf '%s' "$payload" > "${state_file}.proxy-host-7.json"
   fi
   if [[ "$scenario" == issuance-after-mutation-main && "$path" == "/api/nginx/proxy-hosts/7" ]]; then
     printf '%s' "$payload" > "${state_file}.proxy-host-7-current.json"
   fi
   if [[ ( "$scenario" == verification-after-mutation-* || "$scenario" == tls-failure ) && "$path" == "/api/nginx/proxy-hosts/7" && "$mutations" == 1 ]]; then
    printf 'api-mutated' > "$proxy_state_file"
    elif [[ ( "$scenario" == verification-after-mutation-* || "$scenario" == tls-failure ) && "$path" == "/api/nginx/proxy-hosts/7" && ( "$mutations" == 2 || "$mutations" == 4 ) ]]; then
     printf 'api-restored' > "$proxy_state_file"
     printf '1' > "${state_file}.restore-verifications"
     : > "${state_file}.proxy-host-7-restored"
   else
     printf 'mutated' > "$proxy_state_file"
   fi
    if [[ "$scenario" == issuance-after-mutation-main && "$path" == "/api/nginx/proxy-hosts/7" && "$mutations" == 2 ]]; then
      printf 'api-restored' > "$proxy_state_file"
      printf '1' > "${state_file}.restore-verifications"
      : > "${state_file}.proxy-host-7-restored"
   fi
fi

if [[ "$scenario" == confirmed-404 && "$method" == DELETE && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  printf '{}\n204\n'
  exit 0
fi
if [[ "$scenario" == confirmed-404 && "$method" == GET && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  printf '{}\n404\n'
  exit 0
fi
if [[ "$scenario" == ambiguous-reread && "$method" == DELETE && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  printf '{}\n204\n'
  exit 0
fi
if [[ "$scenario" == ambiguous-reread && "$method" == GET && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  exit 28
fi
if [[ "$scenario" == non-404-reread && "$method" == DELETE && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  printf '{}\n204\n'
  exit 0
fi
if [[ "$scenario" == non-404-reread && "$method" == GET && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  printf '{"id":8}\n200\n'
  exit 0
fi
if [[ "$scenario" == malformed-reread && "$method" == DELETE && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  printf '{}\n204\n'
  exit 0
fi
if [[ "$scenario" == malformed-reread && "$method" == GET && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  printf 'malformed-response\n200\n'
  exit 0
fi
if [[ "$scenario" == transport-delete && "$method" == DELETE && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  exit 28
fi

if [[ "$scenario" == custom-tls-failure && "$method" == GET && "$path" == /api/nginx/proxy-hosts/7 ]]; then
  if [[ "$mutations" == 1 ]]; then
     printf '{"id":7,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":99,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":true,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}\n200\n'
  else
     printf '{"id":7,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}\n200\n'
  fi
  exit 0
fi
if [[ "$scenario" == issuance-after-mutation-main && "$method" == GET && "$path" == "/api/nginx/certificates?per_page=200" ]]; then
  cert_query_file="${state_file}.cert-queries"
  cert_queries=0
  [[ -f "$cert_query_file" ]] && cert_queries="$(<"$cert_query_file")"
  cert_queries=$((cert_queries + 1))
  printf '%s' "$cert_queries" > "$cert_query_file"
  if [[ "$cert_queries" == 1 ]]; then
    printf '[{"id":42,"provider":"letsencrypt","domain_names":["api.example.test"]}]\n200\n'
  else
    printf '[]\n200\n'
  fi
  exit 0
fi
if [[ "$scenario" == verification-after-mutation-* && "$method" == GET && "$path" == "/api/nginx/certificates?per_page=200" ]]; then
  cert_query_file="${state_file}.cert-queries"
  cert_queries=0
  [[ -f "$cert_query_file" ]] && cert_queries="$(<"$cert_query_file")"
  cert_queries=$((cert_queries + 1))
  printf '%s' "$cert_queries" > "$cert_query_file"
  if [[ "$cert_queries" == 1 ]]; then
    printf '[{"id":42,"provider":"letsencrypt","domain_names":["api.example.test"]}]\n200\n'
  else
    printf '[{"id":43,"provider":"letsencrypt","domain_names":["nginx.example.test"]}]\n200\n'
  fi
  exit 0
fi
if [[ "$scenario" == issuance-after-mutation-main && "$method" == GET && "$path" == /api/nginx/certificates/42 ]]; then
  printf '{"id":42,"provider":"letsencrypt","status":"issued","domain_names":["api.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n'
  exit 0
fi
if [[ "$scenario" == verification-after-mutation-* && "$method" == GET && "$path" == /api/nginx/certificates/42 ]]; then
  printf '{"id":42,"provider":"letsencrypt","status":"issued","domain_names":["api.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n'
  exit 0
fi
if [[ "$scenario" == verification-after-mutation-* && "$method" == GET && "$path" == /api/nginx/certificates/43 ]]; then
  if [[ "$scenario" == verification-after-mutation-san ]]; then
    printf '{"id":43,"provider":"letsencrypt","status":"issued","domain_names":["other.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n'
  elif [[ "$scenario" == verification-after-mutation-expired ]]; then
    printf '{"id":43,"provider":"letsencrypt","status":"issued","domain_names":["nginx.example.test"],"expires_on":"2020-01-01T00:00:00Z"}\n200\n'
  else
    printf '{"id":43,"provider":"letsencrypt","status":"issued","domain_names":["nginx.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n'
  fi
  exit 0
fi
if [[ "$scenario" == issuance-after-mutation-main && "$method" == GET && "$path" == "/api/nginx/proxy-hosts?per_page=200" ]]; then
   printf '{"page":1,"per_page":200,"total":1,"data":[{"id":7,"domain_names":["api.example.test"]}]}\n200\n'
  exit 0
fi
if [[ "$scenario" == verification-after-mutation-* && "$method" == GET && "$path" == "/api/nginx/proxy-hosts?per_page=200" ]]; then
  if [[ "$mutations" == 0 ]]; then
    printf '%s\n200\n' '{"page":1,"per_page":200,"total":2,"data":[{"id":7,"domain_names":["api.example.test"],"forward_scheme":"http","forward_host":"api-original","forward_port":5001,"certificate_id":17,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":true,"trust_forwarded_proto":false,"http2_support":true,"block_exploits":false,"caching_enabled":true,"allow_websocket_upgrade":false,"access_list_id":4,"advanced_config":"proxy_read_timeout 45s;","enabled":false,"locations":[{"path":"/original","forward_host":"api-original","forward_port":5001}]},{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"nginx-original","forward_port":8080,"certificate_id":18,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":false,"trust_forwarded_proto":false,"http2_support":true,"block_exploits":false,"caching_enabled":true,"allow_websocket_upgrade":false,"access_list_id":5,"advanced_config":"proxy_read_timeout 30s;","enabled":true,"locations":[{"path":"/original","forward_host":"nginx-original","forward_port":8080}]}]}'
  else
    printf '%s\n200\n' '{"page":1,"per_page":200,"total":1,"data":[{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"nginx-original","forward_port":8080,"certificate_id":18,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":false,"trust_forwarded_proto":false,"http2_support":true,"block_exploits":false,"caching_enabled":true,"allow_websocket_upgrade":false,"access_list_id":5,"advanced_config":"proxy_read_timeout 30s;","enabled":true,"locations":[{"path":"/original","forward_host":"nginx-original","forward_port":8080}]}]}'
  fi
  exit 0
fi
if [[ "$scenario" == issuance-after-mutation-main && "$method" == GET && "$path" == /api/nginx/proxy-hosts/7 ]]; then
   original_state='{"id":7,"domain_names":["api.example.test"],"forward_scheme":"http","forward_host":"api-original","forward_port":5001,"certificate_id":17,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":true,"trust_forwarded_proto":false,"http2_support":true,"block_exploits":false,"caching_enabled":true,"allow_websocket_upgrade":false,"access_list_id":4,"advanced_config":"proxy_read_timeout 45s;","enabled":false,"locations":[{"path":"/original","forward_host":"api-original","forward_port":5001}]}'
   if [[ ! -f "${state_file}.proxy-host-7-current.json" ]]; then
     printf '%s' "$original_state" | jq 'del(.id)' > "${state_file}.proxy-host-7-original.json"
     printf '%s' "$original_state" | jq 'del(.id)' > "${state_file}.proxy-host-7-current.json"
   fi
   current_state="$(jq -c '. + {id: 7}' "${state_file}.proxy-host-7-current.json")"
    if [[ -f "${state_file}.proxy-host-7-restored" ]]; then
      reread_counter_file="${state_file}.proxy-host-7-rereads"
      reread_ids_file="${state_file}.proxy-host-reread-ids"
      rereads=0
      [[ -f "$reread_counter_file" ]] && rereads="$(<"$reread_counter_file")"
      rereads=$((rereads + 1))
      printf '%s' "$rereads" > "$reread_counter_file"
      printf '7\n' >> "$reread_ids_file"
      printf '%s' "$current_state" | jq 'del(.id)' > "${state_file}.proxy-host-7-reread.json"
   fi
   printf '%s\n200\n' "$current_state"
   exit 0
fi
if [[ "$scenario" == verification-after-mutation-* && "$method" == GET && "$path" == /api/nginx/proxy-hosts/7 ]]; then
  if [[ -f "${state_file}.proxy-host-7.json" ]]; then
    jq -c '. + {id: 7}' "${state_file}.proxy-host-7.json"
     if [[ -f "${state_file}.proxy-host-7-restored" ]]; then
       reread_counter_file="${state_file}.proxy-host-7-rereads"
       reread_ids_file="${state_file}.proxy-host-reread-ids"
       rereads=0
       [[ -f "$reread_counter_file" ]] && rereads="$(<"$reread_counter_file")"
       rereads=$((rereads + 1))
       printf '%s' "$rereads" > "$reread_counter_file"
       printf '7\n' >> "$reread_ids_file"
       cp "${state_file}.proxy-host-7.json" "${state_file}.proxy-host-7-reread.json"
     fi
    printf '200\n'
  else
    original_state='{"id":7,"domain_names":["api.example.test"],"forward_scheme":"http","forward_host":"api-original","forward_port":5001,"certificate_id":17,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":true,"trust_forwarded_proto":false,"http2_support":true,"block_exploits":false,"caching_enabled":true,"allow_websocket_upgrade":false,"access_list_id":4,"advanced_config":"proxy_read_timeout 45s;","enabled":false,"locations":[{"path":"/original","forward_host":"api-original","forward_port":5001}]}'
    printf '%s' "$original_state" | jq 'del(.id)' > "${state_file}.proxy-host-7-original.json"
    printf '%s\n200\n' "$original_state"
  fi
  exit 0
fi
if [[ "$scenario" == verification-after-mutation-* && "$method" == GET && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  printf '{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"nginx-original","forward_port":8080,"certificate_id":18,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":false,"trust_forwarded_proto":false,"http2_support":true,"block_exploits":false,"caching_enabled":true,"allow_websocket_upgrade":false,"access_list_id":5,"advanced_config":"proxy_read_timeout 30s;","enabled":true,"locations":[{"path":"/original","forward_host":"nginx-original","forward_port":8080}]}\n200\n'
  exit 0
fi
if [[ "$scenario" == issuance-after-mutation-main && "$method" == GET && "$path" == /api/nginx/proxy-hosts/7 ]]; then
  printf '{"id":7,"domain_names":["api.example.test"],"forward_scheme":"http","forward_host":"daiana-python","forward_port":5002,"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}\n200\n'
  exit 0
fi
if [[ "$scenario" == issuance-after-mutation-main && "$method" == PUT && "$path" == /api/nginx/proxy-hosts/7 ]]; then
  printf '{}\n200\n'
  exit 0
fi
if [[ "$scenario" == transient && "$method" == GET && "$path" == /api/nginx/proxy-hosts?per_page=200 && "$mutations" != 0 ]]; then
  printf '%s\n200\n' '{"page":1,"per_page":200,"total":1,"data":[{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":"","enabled":true,"locations":[]}]}'
  exit 0
fi
if [[ "$scenario" == post-500-side-effect || "$scenario" == post-transport-side-effect ]] &&
   [[ "$method" == GET && "$path" == /api/nginx/proxy-hosts?per_page=200 && "$mutations" != 0 ]]; then
  jq -n '{page:1,per_page:200,total:1,data:[{id:8,domain_names:["nginx.example.test"],forward_scheme:"http",forward_host:"npm",forward_port:81,certificate_id:0,ssl_forced:false,hsts_enabled:false,hsts_subdomains:false,trust_forwarded_proto:true,http2_support:false,block_exploits:true,caching_enabled:false,allow_websocket_upgrade:true,access_list_id:0,advanced_config:"",enabled:true,locations:[]}]}'
  printf '200\n'
  exit 0
fi
if [[ "$scenario" == post-500-side-effect || "$scenario" == post-transport-side-effect ]]; then
  if [[ "$method" == GET && "$path" == /api/nginx/proxy-hosts?per_page=200 ]]; then
    if [[ "$mutations" == 0 ]]; then
      printf '{"page":1,"per_page":200,"total":0,"data":[]}\n200\n'
    else
      printf '%s\n200\n' '{"page":1,"per_page":200,"total":1,"data":[{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}]}'
    fi
    exit 0
  fi
  if [[ "$method" == DELETE && "$path" == /api/nginx/proxy-hosts/8 ]]; then
    printf '{}\n204\n'
    exit 0
  fi
  if [[ "$method" == GET && "$path" == /api/nginx/proxy-hosts/8 ]]; then
    printf '{}\n404\n'
    exit 0
  fi
fi
if [[ "$scenario" == transient && "$method" == GET && "$path" == /api/nginx/proxy-hosts?per_page=200 ]]; then
           if [[ "$mutations" == 0 ]]; then
             printf '{"page":1,"per_page":200,"total":0,"data":[]}\n200\n'
  else
             printf '{"page":1,"per_page":200,"total":1,"data":[{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}]}\n200\n'
  fi
  exit 0
fi
if [[ "$scenario" == transient && "$method" == GET && "$path" == /api/nginx/proxy-hosts/8 ]]; then
  printf '{"id":8,"domain_names":["nginx.example.test"],"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"http2_support":false,"enabled":true}\n200\n'
  exit 0
fi

case_scenario="$scenario"
[[ "$scenario" == tls-http-401 ]] && case_scenario=success
case "$case_scenario:$method:$path" in
  *:POST:/api/tokens) printf '{"token":"mock-token"}\n200\n' ;;
  empty:GET:/api/nginx/certificates\?per_page=200|upload-failure:GET:/api/nginx/certificates\?per_page=200|custom-success:GET:/api/nginx/certificates\?per_page=200|custom-tls-failure:GET:/api/nginx/certificates\?per_page=200|custom-san-mismatch:GET:/api/nginx/certificates\?per_page=200|custom-expired:GET:/api/nginx/certificates\?per_page=200|custom-malformed:GET:/api/nginx/certificates\?per_page=200|custom-invalid:GET:/api/nginx/certificates\?per_page=200|le-invalid:GET:/api/nginx/certificates\?per_page=200|le-created-valid:GET:/api/nginx/certificates\?per_page=200|transient:GET:/api/nginx/certificates\?per_page=200) printf '[]\n200\n' ;;
  le-created-valid:POST:/api/nginx/certificates) if [[ -n "${CERT_CREATE_RESPONSE:-}" ]]; then printf '%s\n201\n' "$CERT_CREATE_RESPONSE"; else printf '{"id":42}\n201\n'; fi ;;
  empty:POST:/api/nginx/certificates|custom-success:POST:/api/nginx/certificates|custom-tls-failure:POST:/api/nginx/certificates|custom-san-mismatch:POST:/api/nginx/certificates|custom-expired:POST:/api/nginx/certificates|custom-malformed:POST:/api/nginx/certificates|transient:POST:/api/nginx/certificates) if [[ -n "${CERT_CREATE_RESPONSE:-}" ]]; then printf '%s\n201\n' "$CERT_CREATE_RESPONSE"; else printf '{"id":99}\n201\n'; fi ;;
  custom-invalid:POST:/api/nginx/certificates) printf '%s\n201\n' "${CERT_CREATE_RESPONSE:?}" ;;
  le-invalid:POST:/api/nginx/certificates) printf '%s\n201\n' "${CERT_CREATE_RESPONSE:?}" ;;
  upload-failure:POST:/api/nginx/certificates) printf '{"id":99}\n201\n' ;;
  upload-failure:POST:/api/nginx/certificates/99/upload) printf '{"error":"mock upload failure"}\n500\n' ;;
  custom-success:POST:/api/nginx/certificates/99/upload|custom-tls-failure:POST:/api/nginx/certificates/99/upload|custom-san-mismatch:POST:/api/nginx/certificates/99/upload|custom-expired:POST:/api/nginx/certificates/99/upload|custom-malformed:POST:/api/nginx/certificates/99/upload) printf '{}\n200\n' ;;
  success:GET:/api/nginx/certificates\?per_page=200|post-mutation-tls-reload:GET:/api/nginx/certificates\?per_page=200|valid-status:GET:/api/nginx/certificates\?per_page=200|invalid-status:GET:/api/nginx/certificates\?per_page=200|hostname-mismatch:GET:/api/nginx/certificates\?per_page=200|expired:GET:/api/nginx/certificates\?per_page=200|tls-failure:GET:/api/nginx/certificates\?per_page=200|tls-hostname-mismatch:GET:/api/nginx/certificates\?per_page=200|proxy-host-failure:GET:/api/nginx/certificates\?per_page=200) printf '[{"id":42,"provider":"letsencrypt","domain_names":["nginx.example.test"]}]\n200\n' ;;
    success:GET:/api/nginx/certificates/42|post-mutation-tls-reload:GET:/api/nginx/certificates/42|proxy-host-failure:GET:/api/nginx/certificates/42|tls-failure:GET:/api/nginx/certificates/42|tls-hostname-mismatch:GET:/api/nginx/certificates/42) printf '{"id":42,"provider":"letsencrypt","status":"issued","domain_names":["nginx.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n' ;;
  custom-success:GET:/api/nginx/certificates/99|custom-tls-failure:GET:/api/nginx/certificates/99|custom-san-mismatch:GET:/api/nginx/certificates/99|custom-expired:GET:/api/nginx/certificates/99|custom-malformed:GET:/api/nginx/certificates/99) printf '{"id":99,"provider":"other","status":null,"domain_names":["example.test"],"expires_on":"2099-01-01 00:00:00"}\n200\n' ;;
  transient:GET:/api/nginx/certificates/99) printf '{"id":99,"provider":"letsencrypt","status":"issued","domain_names":["nginx.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n' ;;
  le-created-valid:GET:/api/nginx/certificates/42) printf '{"id":42,"provider":"letsencrypt","status":"issued","domain_names":["nginx.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n' ;;
  valid-status:GET:/api/nginx/certificates/42) printf '{"id":42,"provider":"letsencrypt","status":"valid","domain_names":["nginx.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n' ;;
  invalid-status:GET:/api/nginx/certificates/42) printf '{"id":42,"provider":"letsencrypt","status":"pending","domain_names":["nginx.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n' ;;
  hostname-mismatch:GET:/api/nginx/certificates/42) printf '{"id":42,"provider":"letsencrypt","status":"issued","domain_names":["other.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n' ;;
  expired:GET:/api/nginx/certificates/42) printf '{"id":42,"provider":"letsencrypt","status":"issued","domain_names":["nginx.example.test"],"expires_on":"2020-01-01T00:00:00Z"}\n200\n' ;;
  tls-hostname-mismatch:GET:/api/nginx/certificates/42) printf '{"id":42,"provider":"letsencrypt","status":"issued","domain_names":["nginx.example.test"],"expires_on":"2099-01-01T00:00:00Z"}\n200\n' ;;
      success:GET:/api/nginx/proxy-hosts\?per_page=200|post-mutation-tls-reload:GET:/api/nginx/proxy-hosts\?per_page=200|custom-success:GET:/api/nginx/proxy-hosts\?per_page=200|custom-tls-failure:GET:/api/nginx/proxy-hosts\?per_page=200|custom-san-mismatch:GET:/api/nginx/proxy-hosts\?per_page=200|custom-expired:GET:/api/nginx/proxy-hosts\?per_page=200|custom-malformed:GET:/api/nginx/proxy-hosts\?per_page=200|le-created-valid:GET:/api/nginx/proxy-hosts\?per_page=200|tls-failure:GET:/api/nginx/proxy-hosts\?per_page=200|tls-hostname-mismatch:GET:/api/nginx/proxy-hosts\?per_page=200) printf '{"page":1,"per_page":200,"total":1,"data":[{"id":7,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":42,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":true,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}] }\n200\n' ;;
      success:GET:/api/nginx/proxy-hosts/7|post-mutation-tls-reload:GET:/api/nginx/proxy-hosts/7|custom-success:GET:/api/nginx/proxy-hosts/7|custom-san-mismatch:GET:/api/nginx/proxy-hosts/7|custom-expired:GET:/api/nginx/proxy-hosts/7|custom-malformed:GET:/api/nginx/proxy-hosts/7|le-created-valid:GET:/api/nginx/proxy-hosts/7|tls-failure:GET:/api/nginx/proxy-hosts/7|tls-hostname-mismatch:GET:/api/nginx/proxy-hosts/7) printf '{"id":7,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}\n200\n' ;;
    success:PUT:/api/nginx/proxy-hosts/7|post-mutation-tls-reload:PUT:/api/nginx/proxy-hosts/7|custom-success:PUT:/api/nginx/proxy-hosts/7|custom-tls-failure:PUT:/api/nginx/proxy-hosts/7|custom-san-mismatch:PUT:/api/nginx/proxy-hosts/7|custom-expired:PUT:/api/nginx/proxy-hosts/7|custom-malformed:PUT:/api/nginx/proxy-hosts/7|le-created-valid:PUT:/api/nginx/proxy-hosts/7) printf '{}\n200\n' ;;
   transient:GET:/api/nginx/proxy-hosts\?per_page=200|proxy-host-failure:GET:/api/nginx/proxy-hosts\?per_page=200) printf '{"page":1,"per_page":200,"total":0,"data":[]}\n200\n' ;;
  transient:POST:/api/nginx/proxy-hosts) if [[ -n "${CREATE_RESPONSE:-}" ]]; then printf '%s\n201\n' "$CREATE_RESPONSE"; else printf '{"id":8}\n201\n'; fi ;;
   proxy-host-failure:POST:/api/nginx/proxy-hosts) printf '{"error":"mock proxy host failure"}\n500\n' ;;
   post-500-side-effect:POST:/api/nginx/proxy-hosts) printf '{"error":"committed before failure"}\n500\n' ;;
   post-transport-side-effect:POST:/api/nginx/proxy-hosts) exit 28 ;;
  *) printf '{}\n200\n' ;;
esac
MOCK
chmod +x "$MOCK_BIN/curl"

run_bootstrap() {
  local scenario="$1"
  local tls_mode=none
  local xtrace_was_enabled=0
  local bootstrap_status
  printf '0' > "$TMP_DIR/$scenario.state.mutations"
  printf 'baseline' > "$TMP_DIR/$scenario.state.proxy-state"
  case "$scenario" in
    custom-success|custom-tls-failure)
      printf '%s\n' '-----BEGIN MOCK CERTIFICATE-----' 'SAN=nginx.example.test' 'NOT_AFTER=2099-01-01T00:00:00Z' '-----END MOCK CERTIFICATE-----' > "$TMP_DIR/local-nginx.crt"
      ;;
    custom-san-mismatch)
      printf '%s\n' '-----BEGIN MOCK CERTIFICATE-----' 'SAN=other.example.test' 'NOT_AFTER=2099-01-01T00:00:00Z' '-----END MOCK CERTIFICATE-----' > "$TMP_DIR/local-nginx.crt"
      ;;
    custom-expired)
      printf '%s\n' '-----BEGIN MOCK CERTIFICATE-----' 'SAN=nginx.example.test' 'NOT_AFTER=2020-01-01T00:00:00Z' '-----END MOCK CERTIFICATE-----' > "$TMP_DIR/local-nginx.crt"
      ;;
    custom-malformed)
      printf '%s\n' 'not a PEM certificate' > "$TMP_DIR/local-nginx.crt"
      ;;
  esac
  case "$scenario" in
    empty|success|tls-http-401|post-mutation-tls-reload|valid-status|invalid-status|hostname-mismatch|expired|tls-failure|tls-hostname-mismatch|proxy-host-failure|issuance-after-mutation-main|verification-after-mutation-main|verification-after-mutation-san|verification-after-mutation-expired) tls_mode=letsencrypt ;;
    custom-success|custom-tls-failure|custom-san-mismatch|custom-expired|custom-malformed|custom-invalid) tls_mode=local ;;
    le-created-valid) tls_mode=letsencrypt ;;
    upload-failure) tls_mode=local ;;
  esac
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  if NPM_TEST_SCENARIO="$scenario" NPM_TEST_STATE="$TMP_DIR/$scenario.state" CERT_CREATE_RESPONSE="${CERT_CREATE_RESPONSE:-}" \
     PATH="$MOCK_BIN:$PATH" BASE_DOMAIN=example.test NPM_TLS_VERIFY_IP=192.168.0.19 NPM_ADMIN_EMAIL=admin@example.test \
     NPM_API_URL=http://127.0.0.1:81 \
    NPM_CONNECT_TIMEOUT=1 NPM_OPERATION_TIMEOUT=1 NPM_READY_DELAY=0 NPM_READY_ATTEMPTS=3 \
    ONLY_PREFIX=nginx TLS_MODE="$tls_mode" \
     NPM_LOCAL_CERT_FILE="$TMP_DIR/local-nginx.crt" NPM_LOCAL_KEY_FILE="$TMP_DIR/local-nginx.key" run_secret_child bash "$SCRIPT"; then
    bootstrap_status=0
  else
    bootstrap_status=$?
  fi
  if (( xtrace_was_enabled )); then
    set -x
  fi
  return "$bootstrap_status"
}

run_integrated_bootstrap() {
  local scenario="$1"
  local state_file="$TMP_DIR/$scenario.state"
  local xtrace_was_enabled=0
  local bootstrap_status
  printf '0' > "$state_file.mutations"
  printf 'baseline' > "$state_file.proxy-state"
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  if NPM_TEST_SCENARIO="$scenario" NPM_TEST_STATE="$state_file" \
    PATH="$MOCK_BIN:$PATH" NPM_ADMIN_EMAIL=admin@example.test NPM_ADMIN_PASS=super-secret \
    NPM_API_URL=http://127.0.0.1:81 NPM_CONNECT_TIMEOUT=1 NPM_OPERATION_TIMEOUT=1 \
    NPM_READY_DELAY=0 NPM_READY_ATTEMPTS=3 TLS_MODE=letsencrypt BASE_DOMAIN=example.test \
    bash "$SCRIPT"; then
    bootstrap_status=0
  else
    bootstrap_status=$?
  fi
  if (( xtrace_was_enabled )); then
    set -x
  fi
  return "$bootstrap_status"
}

run_secret_child() {
  local xtrace_was_enabled=0
  local child_status
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  "$@"
  child_status=$?
  if (( xtrace_was_enabled )); then
    set -x
  fi
  return "$child_status"
}

assert_no_fixture_secret() {
  local output_file="$1"
  local xtrace_was_enabled=0
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  if grep -q 'super-secret' "$output_file"; then
    printf 'Failure diagnostics leaked a secret for %s\n' "${output_file##*/}" >&2
    if (( xtrace_was_enabled )); then
      set -x
    fi
    return 1
  fi
  if (( xtrace_was_enabled )); then
    set -x
  fi
}

run_expect_failure() {
  local scenario="$1"
  if run_bootstrap "$scenario" >"$TMP_DIR/$scenario.out" 2>&1; then
    printf 'Expected %s to fail\n' "$scenario" >&2
    return 1
  fi
  if ! grep -q 'NPM_BOOTSTRAP_STATUS=FAILED' "$TMP_DIR/$scenario.out"; then
    printf 'Unexpected output for %s:\n' "$scenario" >&2
    sed -n '1,120p' "$TMP_DIR/$scenario.out" >&2
    return 1
  fi
  if grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/$scenario.out"; then
    printf 'Failed %s emitted a success receipt\n' "$scenario" >&2
    return 1
  fi
  assert_no_fixture_secret "$TMP_DIR/$scenario.out"
}

# Documentation keeps authenticated inspection credential-safe and uses GET-based
# TLS verification rather than treating HEAD support as a certificate signal.
grep -q 'NPM_API_TOKEN' "$DOCS"
grep -q 'Source NPM_API_TOKEN securely' "$DOCS"
grep -q -- '--resolve' "$DOCS"
grep -q -- "--proto '=https'" "$DOCS"
if grep -Eq 'curl .* -I([[:space:]]|$)' "$DOCS"; then
  printf 'Documentation must not use curl -I as a verification signal\n' >&2
  exit 1
fi

# nip.io verification must use the address encoded in the configured public
# base domain, never a local interface/hostname or an ambiguous host label.
 PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    for address in 001.002.003.004 192.168.000.19 192.168.0.019 256.1.1.1 1.2.3. 1.2.3 1.2.3.4.5 abc.def.ghi.jkl ""; do
      if is_ipv4_address "$address"; then
        printf "Accepted non-canonical IPv4 address: %s\n" "$address" >&2
        exit 1
      fi
    done
    for address in 0.0.0.0 1.2.3.4 192.168.0.19 255.255.255.255; do
      is_ipv4_address "$address"
    done
    ! extract_nip_io_ip 001.002.003.004.nip.io
    [[ "$(extract_nip_io_ip 192.168.0.19.nip.io)" == 192.168.0.19 ]]
    BASE_DOMAIN=192.168.0.19.nip.io NPM_TLS_VERIFY_IP=""
    [[ "$(derive_tls_verify_ip whatsapp.192.168.0.19.nip.io)" == 192.168.0.19 ]]
    DOMAIN_DAIANA=custom.example.test
    [[ "$(tls_domain_for_service daiana)" == daiana.192.168.0.19.nip.io ]] || exit 1
    BASE_DOMAIN=192.168.0.19
    [[ "$(tls_domain_for_service daiana)" == daiana.192.168.0.19 ]] || exit 1
    BASE_DOMAIN=192.168.0.19.nip.io
    DOMAIN_NGINX=custom-nginx.example.test
    [[ "$(tls_domain_for_service nginx)" == custom-nginx.example.test ]] || exit 1
    BASE_DOMAIN=public.example.test
    [[ "$(tls_domain_for_service daiana)" == custom.example.test ]] || exit 1
    NPM_TLS_VERIFY_IP=192.168.0.19
    [[ "$(derive_tls_verify_ip whatsapp.public.example.test)" == 192.168.0.19 ]]
    BASE_DOMAIN=wrong.nip.io NPM_TLS_VERIFY_IP=""
    ! derive_tls_verify_ip whatsapp.wrong.nip.io
    BASE_DOMAIN=wrong.nip.io NPM_TLS_VERIFY_IP=192.168.0.19
    [[ "$(derive_tls_verify_ip whatsapp.wrong.nip.io)" == 192.168.0.19 ]]
    BASE_DOMAIN=192.168.0.19.nip.io NPM_TLS_VERIFY_IP=192.168.0.20
    ! derive_tls_verify_ip whatsapp.192.168.0.19.nip.io
    BASE_DOMAIN=192.168.0.19.nip.io NPM_TLS_VERIFY_IP=""
    TLS_MODE=local NPM_LOCAL_CERT_FILE="$2"
    build_tls_verify_args whatsapp.192.168.0.19.nip.io
    [[ "${TLS_VERIFY_ARGS[*]}" == *"--resolve whatsapp.192.168.0.19.nip.io:443:192.168.0.19"* ]]
    [[ "${TLS_VERIFY_ARGS[*]}" == *"--cacert $2"* ]]
    [[ "${TLS_VERIFY_ARGS[*]}" == *"--request GET"* ]]
    [[ "${TLS_VERIFY_ARGS[*]}" == *"--proto =https"* ]]
    [[ "${TLS_VERIFY_ARGS[*]}" == *"https://whatsapp.192.168.0.19.nip.io/"* ]]
  ' _ "$SCRIPT" "$TMP_DIR/local-nginx.crt"
if grep -q 'Bearer [A-Za-z0-9._-]\{20,\}' "$DOCS"; then
  printf 'Documentation must not contain a literal bearer token\n' >&2
  exit 1
fi

# A reset is retried, and eventual readiness proceeds to the idempotent host update.
run_bootstrap transient >"$TMP_DIR/transient.out" 2>&1
grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/transient.out"
grep -q 'NPM_BOOTSTRAP_TLS_RESULT=not_requested' "$TMP_DIR/transient.out"

# Exercise the production script itself under xtrace.  The fixture password is
# inherited through the environment, so this proves production secret
# handling rather than relying on the harness to disable xtrace in the child.
if NPM_TEST_SCENARIO=success NPM_TEST_STATE="$TMP_DIR/production-xtrace.state" \
  PATH="$MOCK_BIN:$PATH" BASE_DOMAIN=example.test \
  NPM_API_URL=http://127.0.0.1:81 \
  NPM_CONNECT_TIMEOUT=1 NPM_OPERATION_TIMEOUT=1 NPM_READY_DELAY=0 NPM_READY_ATTEMPTS=3 \
  ONLY_PREFIX=nginx TLS_MODE=letsencrypt bash -x "$SCRIPT" \
  >"$TMP_DIR/production-xtrace.out" 2>&1; then
  :
else
  printf 'Production bash -x resilience path unexpectedly failed\n' >&2
  exit 1
fi
assert_no_fixture_secret "$TMP_DIR/production-xtrace.out"
grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/production-xtrace.out"

# Readiness timeout, empty certificate ID, and certificate application failure all fail closed.
run_expect_failure timeout
run_expect_failure empty

# An existing certificate ID is applied only after certificate and TLS verification.
run_bootstrap success >"$TMP_DIR/success.out" 2>&1
grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/success.out"
grep -q 'NPM_BOOTSTRAP_TLS_RESULT=applied' "$TMP_DIR/success.out"
metadata_line="$(grep -n 'GET /api/nginx/certificates/42' "$TMP_DIR/success.state.order" | cut -d: -f1)"
host_read_line="$(grep -n 'GET /api/nginx/proxy-hosts/7' "$TMP_DIR/success.state.order" | cut -d: -f1)"
mutation_line="$(grep -n 'PUT /api/nginx/proxy-hosts/7' "$TMP_DIR/success.state.order" | cut -d: -f1)"
handshake_line="$(grep -n '^HTTPS ' "$TMP_DIR/success.state.order" | cut -d: -f1)"
[[ "$metadata_line" -lt "$host_read_line" && "$host_read_line" -lt "$mutation_line" && "$mutation_line" -lt "$handshake_line" ]]
jq -e '.certificate_id == 42 and .ssl_forced == true' \
  "$TMP_DIR/success.state.proxy-host-7-put-1.json" >/dev/null

# NPM can acknowledge the mutation before its generated Nginx configuration is
# active.  A first SNI failure is retried, while the eventual successful probe
# still uses normal certificate and hostname verification.
run_bootstrap post-mutation-tls-reload >"$TMP_DIR/post-mutation-tls-reload.out" 2>&1
grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/post-mutation-tls-reload.out"
grep -q 'NPM TLS verification retry' "$TMP_DIR/post-mutation-tls-reload.out"
[[ "$(<"$TMP_DIR/post-mutation-tls-reload.state.tls-probes")" == 2 ]]

# A trusted TLS handshake succeeds even when the upstream application returns
# HTTP 401; authorization status is not part of certificate verification.
run_bootstrap tls-http-401 >"$TMP_DIR/tls-http-401.out" 2>&1
grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/tls-http-401.out"
grep -q 'NPM_BOOTSTRAP_TLS_RESULT=applied' "$TMP_DIR/tls-http-401.out"

# Invalid status, hostname/SAN, expiry, or TLS handshake never produce false success.
run_expect_failure invalid-status
run_expect_failure valid-status
run_expect_failure hostname-mismatch
run_expect_failure expired
run_expect_failure tls-failure
run_expect_failure tls-hostname-mismatch

# Custom certificates accept provider=other/status=null and base-domain-only
# API metadata when the local PEM, SAN/hostname, expiry, and trusted GET pass.
CERT_CREATE_RESPONSE='{ "id" : 99 }' run_bootstrap custom-success >"$TMP_DIR/custom-success.out" 2>&1
grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/custom-success.out"
run_expect_failure custom-san-mismatch
run_expect_failure custom-expired
run_expect_failure custom-malformed
for scenario in custom-san-mismatch custom-expired custom-malformed; do
  if [[ "$scenario" == custom-san-mismatch || "$scenario" == custom-malformed ]]; then
    grep -q 'NPM_BOOTSTRAP_REASON=certificate_application_failed_before_proxy_mutation' "$TMP_DIR/$scenario.out"
  else
    grep -q 'NPM_BOOTSTRAP_REASON=certificate_verification_failed_before_proxy_mutation' "$TMP_DIR/$scenario.out"
  fi
  if grep -q 'proxy_hosts_restored\|ROLLBACK_DIAGNOSTIC_DIR' "$TMP_DIR/$scenario.out"; then
    printf '%s unexpectedly entered proxy rollback\n' "$scenario" >&2
    exit 1
  fi
  [[ "$(<"$TMP_DIR/$scenario.state.mutations")" == 0 ]]
done
CERT_CREATE_RESPONSE='{ "id" : 42 }' run_bootstrap le-created-valid >"$TMP_DIR/le-created-valid.out" 2>&1
grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/le-created-valid.out"
run_expect_failure custom-tls-failure
grep -q 'NPM_BOOTSTRAP_REASON=certificate_verification_failed_proxy_hosts_restored' "$TMP_DIR/custom-tls-failure.out"
[[ "$(<"$TMP_DIR/custom-tls-failure.state.mutations")" == 2 ]]

# Certificate upload fails before proxy mutation: no host state changes, no
# proxy rollback is needed, and the failure receipt remains non-zero/redacted.
run_expect_failure upload-failure
run_expect_failure proxy-host-failure
for scenario in post-500-side-effect post-transport-side-effect; do
  run_expect_failure "$scenario"
  grep -q 'proxy_hosts_restored' "$TMP_DIR/$scenario.out"
  grep -q 'NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=' "$TMP_DIR/$scenario.out"
  diagnostic_dir="$(grep 'NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=' "$TMP_DIR/$scenario.out" | cut -d= -f2)"
  evidence_found=0
  for evidence in "$diagnostic_dir"/create-failure-*.txt; do
    if [[ -s "$evidence" ]]; then
      grep -q 'raw_response_begin' "$evidence"
      evidence_found=1
      break
    fi
  done
  [[ "$evidence_found" == 1 ]]
done
[[ "$(<"$TMP_DIR/upload-failure.state.mutations")" == 0 ]]
[[ "$(<"$TMP_DIR/upload-failure.state.proxy-state")" == baseline ]]
grep -q 'NPM_BOOTSTRAP_REASON=certificate_application_failed_before_proxy_mutation' "$TMP_DIR/upload-failure.out"
if grep -q 'Usando certificado local NPM' "$TMP_DIR/upload-failure.out"; then
  printf 'Upload failure continued after certificate application\n' >&2
  exit 1
fi
if grep -q 'Listo:' "$TMP_DIR/upload-failure.out" || grep -q 'Listo:' "$TMP_DIR/proxy-host-failure.out"; then
  printf 'Application failure continued to the success message\n' >&2
  exit 1
fi

# The real main loop must compensate an earlier proxy mutation when the next
# service's ACME issuance fails, without emitting a success receipt.
if run_integrated_bootstrap issuance-after-mutation-main >"$TMP_DIR/issuance-after-mutation-main.out" 2>&1; then
  printf 'Expected integrated issuance failure to fail\n' >&2
  exit 1
fi
grep -q 'NPM_BOOTSTRAP_REASON=certificate_issuance_failed_proxy_hosts_restored' "$TMP_DIR/issuance-after-mutation-main.out"
if grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/issuance-after-mutation-main.out"; then
  printf 'Integrated issuance failure emitted a success receipt\n' >&2
  exit 1
fi
assert_no_fixture_secret "$TMP_DIR/issuance-after-mutation-main.out"
[[ "$(<"$TMP_DIR/issuance-after-mutation-main.state.mutations")" == 2 ]]
[[ "$(<"$TMP_DIR/issuance-after-mutation-main.state.proxy-state")" == api-restored ]]
[[ "$(<"$TMP_DIR/issuance-after-mutation-main.state.restore-verifications")" == 1 ]]
[[ "$(<"$TMP_DIR/issuance-after-mutation-main.state.proxy-host-7-rereads")" == 1 ]]
[[ "$(<"$TMP_DIR/issuance-after-mutation-main.state.proxy-host-reread-ids")" == $'7\n' ]]
jq -e -s '.[0] == .[1]' \
  "$TMP_DIR/issuance-after-mutation-main.state.proxy-host-7-original.json" \
  "$TMP_DIR/issuance-after-mutation-main.state.proxy-host-7-put-2.json" >/dev/null
jq -e -s '.[0] == .[1]' \
  "$TMP_DIR/issuance-after-mutation-main.state.proxy-host-7-reread.json" \
  "$TMP_DIR/issuance-after-mutation-main.state.proxy-host-7-put-2.json" >/dev/null

# A later certificate/TLS verification failure must compensate an earlier
# successful host mutation instead of discarding its rollback journal.
if run_integrated_bootstrap verification-after-mutation-main >"$TMP_DIR/verification-after-mutation-main.out" 2>&1; then
  printf 'Expected multi-host verification failure to fail\n' >&2
  exit 1
fi
grep -q 'NPM_BOOTSTRAP_REASON=certificate_verification_failed_proxy_hosts_restored' "$TMP_DIR/verification-after-mutation-main.out"
if grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/verification-after-mutation-main.out"; then
  printf 'Multi-host verification failure emitted a success receipt\n' >&2
  exit 1
fi
assert_no_fixture_secret "$TMP_DIR/verification-after-mutation-main.out"
[[ "$(<"$TMP_DIR/verification-after-mutation-main.state.mutations")" == 4 ]]
[[ "$(<"$TMP_DIR/verification-after-mutation-main.state.proxy-state")" == api-restored ]]
[[ "$(<"$TMP_DIR/verification-after-mutation-main.state.restore-verifications")" == 1 ]]
[[ "$(<"$TMP_DIR/verification-after-mutation-main.state.proxy-host-7-rereads")" == 1 ]]
[[ "$(<"$TMP_DIR/verification-after-mutation-main.state.proxy-host-reread-ids")" == $'7\n' ]]
jq -e -s '.[0] == .[1]' \
  "$TMP_DIR/verification-after-mutation-main.state.proxy-host-7-original.json" \
  "$TMP_DIR/verification-after-mutation-main.state.proxy-host-7-put-4.json" >/dev/null
jq -e -s '.[0] == .[1]' \
  "$TMP_DIR/verification-after-mutation-main.state.proxy-host-7-reread.json" \
  "$TMP_DIR/verification-after-mutation-main.state.proxy-host-7-put-4.json" >/dev/null

# SAN and expiry failures on host B occur after host A has already been
# mutated.  The mock records the real PUT bodies and serves those bodies on
# reread, so rollback proves the complete host-A snapshot was restored rather
# than accepting a synthetic success response.
for scenario in verification-after-mutation-san verification-after-mutation-expired; do
  state_file="$TMP_DIR/$scenario.state"
  if run_integrated_bootstrap "$scenario" >"$TMP_DIR/$scenario.out" 2>&1; then
    printf 'Expected post-mutation %s failure\n' "$scenario" >&2
    exit 1
  fi
  grep -q 'NPM_BOOTSTRAP_REASON=certificate_verification_failed_proxy_hosts_restored' "$TMP_DIR/$scenario.out"
  if grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/$scenario.out"; then
    printf '%s emitted a success receipt\n' "$scenario" >&2
    exit 1
  fi
  assert_no_fixture_secret "$TMP_DIR/$scenario.out"
  [[ "$(<"$state_file.mutations")" == 2 ]]
  [[ "$(<"$state_file.proxy-state")" == api-restored ]]
   [[ "$(<"$state_file.restore-verifications")" == 1 ]]
   [[ "$(<"$state_file.proxy-host-7-rereads")" == 1 ]]
   [[ "$(<"$state_file.proxy-host-reread-ids")" == $'7\n' ]]
  jq -e -s '.[0] == .[1]' "$state_file.proxy-host-7-original.json" \
    "$state_file.proxy-host-7-put-2.json" >/dev/null
  jq -e -s '.[0] == .[1]' "$state_file.proxy-host-7-reread.json" \
    "$state_file.proxy-host-7-put-2.json" >/dev/null
done

# A trusted handshake failure after the first proxy mutation uses the
# compensating rollback path and never claims a pre-mutation failure.
run_expect_failure tls-failure
grep -q 'NPM_BOOTSTRAP_REASON=certificate_verification_failed_proxy_hosts_restored' "$TMP_DIR/tls-failure.out"
[[ "$(<"$TMP_DIR/tls-failure.state.mutations")" == 2 ]]
[[ "$(<"$TMP_DIR/tls-failure.state.proxy-state")" == api-restored ]]
if grep -q 'NPM_BOOTSTRAP_STATUS=SUCCESS' "$TMP_DIR/tls-failure.out"; then
  printf 'Permanent TLS failure emitted a success receipt\n' >&2
  exit 1
fi

# Rollback snapshots are deduplicated to the earliest state and processed in
# reverse order, so every changed host is reread and verified exactly once.
NPM_TEST_SCENARIO=rollback-unit PATH="$MOCK_BIN:$PATH" \
 \
  bash -c '
    source "$1"
     ROLLBACK_STATE_DIR="$2.state"
     mkdir -p "$ROLLBACK_STATE_DIR"
     : > "$ROLLBACK_STATE_DIR/reread-ids"
     api_get() {
       local host_id="${1##*/}"
       local host_state
       case "$1" in
          /api/nginx/proxy-hosts/7) host_state="{\"id\":7,\"domain_names\":[\"seven.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0,\"ssl_forced\":false,\"hsts_enabled\":false,\"hsts_subdomains\":false,\"trust_forwarded_proto\":true,\"http2_support\":false,\"block_exploits\":true,\"caching_enabled\":false,\"allow_websocket_upgrade\":true,\"access_list_id\":0,\"advanced_config\":null,\"enabled\":true,\"locations\":[]}";;
          /api/nginx/proxy-hosts/8) host_state="{\"id\":8,\"domain_names\":[\"eight.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0,\"ssl_forced\":false,\"hsts_enabled\":false,\"hsts_subdomains\":false,\"trust_forwarded_proto\":true,\"http2_support\":false,\"block_exploits\":true,\"caching_enabled\":false,\"allow_websocket_upgrade\":true,\"access_list_id\":0,\"advanced_config\":null,\"enabled\":true,\"locations\":[]}";;
        esac
        host_state="${host_state//advanced_config:null/advanced_config:\"\"}"
        host_state="$(jq -c '\''.advanced_config = ""'\'' <<<"$host_state")"
        printf "%s" "$host_state" > "$ROLLBACK_STATE_DIR/host-$host_id-current.json"
       if [[ -f "$ROLLBACK_STATE_DIR/host-$host_id-restored" ]]; then
         counter_file="$ROLLBACK_STATE_DIR/host-$host_id-rereads"
         rereads=0
         [[ -f "$counter_file" ]] && rereads="$(<"$counter_file")"
         rereads=$((rereads + 1))
         printf "%s" "$rereads" > "$counter_file"
        printf "%s " "$host_id" >> "$ROLLBACK_STATE_DIR/reread-ids"
         cp "$ROLLBACK_STATE_DIR/host-$host_id-current.json" "$ROLLBACK_STATE_DIR/host-$host_id-reread.json"
       fi
       printf "%s" "$host_state"
      }
     ROLLBACK_LOG="$2"
     ROLLBACK_PAYLOADS="$2.payloads"
     npm_request() {
       payload="${3:-}"
       jq -e "type == \"object\" and (([\"domain_names\",\"enabled\",\"forward_scheme\",\"forward_host\",\"forward_port\",\"certificate_id\",\"ssl_forced\",\"hsts_enabled\",\"hsts_subdomains\",\"trust_forwarded_proto\",\"http2_support\",\"block_exploits\",\"caching_enabled\",\"allow_websocket_upgrade\",\"access_list_id\",\"advanced_config\",\"locations\"] - keys) | length == 0)" <<<"$payload" >/dev/null
       printf "%s " "${2##*/}" >> "$ROLLBACK_LOG"
        host_id="${2##*/}"
        jq -c . <<<"$payload" >> "$ROLLBACK_PAYLOADS"
        jq -c . <<<"$payload" > "$ROLLBACK_STATE_DIR/host-$host_id-payload.json"
        : > "$ROLLBACK_STATE_DIR/host-$host_id-restored"
     }
    init_proxy_rollback
    capture_proxy_host_state 7 1
    capture_proxy_host_state 8 2
    capture_proxy_host_state 7 3
    [[ "$(wc -l < "$ROLLBACK_RECORDS")" -eq 2 ]]
     rollback_proxy_hosts
     [[ "$(<"$2")" == "8 7 " ]]
     [[ "$(wc -l < "$ROLLBACK_PAYLOADS" | tr -d " ")" == 2 ]]
       jq -s -e '\''.[0].domain_names[0] == "eight.example.test" and .[1].domain_names[0] == "seven.example.test"'\'' "$ROLLBACK_PAYLOADS" >/dev/null
       [[ "$(<"$ROLLBACK_STATE_DIR/reread-ids")" == "8 7 " ]]
       for host_id in 7 8; do
         [[ "$(<"$ROLLBACK_STATE_DIR/host-$host_id-rereads")" == 1 ]]
         jq -e -s '\''.[0] as $expected | .[1] == ($expected | del(.id))'\'' "$ROLLBACK_STATE_DIR/host-$host_id-current.json" "$ROLLBACK_STATE_DIR/host-$host_id-payload.json" >/dev/null
         jq -e -s '\''.[0] == (.[1] | del(.id))'\'' "$ROLLBACK_STATE_DIR/host-$host_id-payload.json" "$ROLLBACK_STATE_DIR/host-$host_id-reread.json" >/dev/null
       done
   ' _ "$SCRIPT" "$TMP_DIR/rollback.order"

# A successful create with a malformed response is journaled from the unique
# post-create inventory diff and then follows normal compensating rollback.
 PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    ENSURE_PROXY_HOSTS=1
    COUNT_FILE="$3"
    printf 0 > "$COUNT_FILE"
    REMOVED_ID=""
    proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
    api_get() {
      if [[ "$1" == /api/nginx/proxy-hosts\?per_page=200 ]]; then
        INVENTORY_READS=$(<"$COUNT_FILE")
        INVENTORY_READS=$((INVENTORY_READS + 1)); printf "%s" "$INVENTORY_READS" > "$COUNT_FILE"
         if [[ "$INVENTORY_READS" -lt 3 ]]; then printf '\''{"page":1,"per_page":200,"total":0,"data":[]}\n'\''; else printf '\''{"page":1,"per_page":200,"total":1,"data":[{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0}]}\n'\''; fi
       fi
      }
     curl() { printf '\''malformed-response\n200\n'\''; }
    remove_created_proxy_host() { REMOVED_ID="$1"; return 0; }
    init_proxy_rollback
    ensure_proxy_host nginx nginx.example.test npm 81 0
    [[ "$REMOVED_ID" == "" ]]
       if fail_after_proxy_mutation proxy_host_application_failed >"$2" 2>&1; then exit 1; fi
    grep -q "NPM_BOOTSTRAP_REASON=proxy_host_application_failed_proxy_hosts_restored" "$2"
    ! grep -q "NPM_BOOTSTRAP_STATUS=SUCCESS" "$2"
    [[ "$REMOVED_ID" == 8 ]]
  ' _ "$SCRIPT" "$TMP_DIR/malformed-create-unique.out" "$TMP_DIR/malformed-create-unique.count"

# A malformed create response with no unique inventory diff is fail-closed,
# explicitly incomplete, and never emits a success receipt.
for inventory_result in ambiguous no-diff; do
 PATH="$MOCK_BIN:$PATH" \
    INVENTORY_RESULT="$inventory_result" bash -c '
      source "$1"
      ENSURE_PROXY_HOSTS=1
      COUNT_FILE="$3"
      printf 0 > "$COUNT_FILE"
      proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
      api_get() {
        if [[ "$1" == /api/nginx/proxy-hosts\?per_page=200 ]]; then
          INVENTORY_READS=$(<"$COUNT_FILE")
          INVENTORY_READS=$((INVENTORY_READS + 1)); printf "%s" "$INVENTORY_READS" > "$COUNT_FILE"
           if [[ "$INVENTORY_READS" -lt 3 ]]; then printf '\''{"page":1,"per_page":200,"total":0,"data":[]}\n'\''
           elif [[ "$INVENTORY_RESULT" == ambiguous ]]; then printf '\''{"page":1,"per_page":200,"total":2,"data":[{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0},{"id":9,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0}]}\n'\''
           else printf '\''{"page":1,"per_page":200,"total":0,"data":[]}\n'\''; fi
        fi
      }
       curl() { printf '\''malformed-response\n200\n'\''; }
      init_proxy_rollback
      if ensure_proxy_host nginx nginx.example.test npm 81 0; then exit 1; fi
       if fail_after_proxy_mutation proxy_host_application_failed >"$2" 2>&1; then exit 1; fi
       grep -q "rollback_incomplete_manual_cleanup_required" "$2"
      ! grep -q "NPM_BOOTSTRAP_STATUS=SUCCESS" "$2"
    ' _ "$SCRIPT" "$TMP_DIR/malformed-create-$inventory_result.out" "$TMP_DIR/malformed-create-$inventory_result.count"
done

# A numeric create ID is trusted only when it is absent before creation and
# the reread matches the complete requested payload; stale IDs fail closed.
 PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    init_proxy_rollback
    before="$ROLLBACK_DIR/before.json"
    printf '\''[{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0}]\n'\'' >"$before"
    proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
    api_get() { printf '\''[{"id":8,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0}]\n'\''; }
    curl() { printf '\''{"id":8}\n201\n'\''; }
    if create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1; then exit 1; fi
    [[ "$ROLLBACK_INCOMPLETE" == 1 ]]
    [[ ! -s "$ROLLBACK_RECORDS" ]]
  ' _ "$SCRIPT"

# An unknown create must not prevent restoration of a known earlier mutation.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    RESTORED=0
    proxy_host_payload() { printf "%s" "{\"domain_names\":[\"unknown.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
    api_get() {
      case "$1" in
        /api/nginx/proxy-hosts/7) printf '\''{"id":7,"domain_names":["seven.example.test"],"certificate_id":0}\n'\'' ;;
        /api/nginx/proxy-hosts\?per_page=200) printf '\''{"page":1,"per_page":200,"total":0,"data":[]}\n'\'' ;;
      esac
    }
    npm_request() { [[ "$2" == /api/nginx/proxy-hosts/7 ]] && RESTORED=$((RESTORED + 1)); }
    curl() { printf '\''malformed-response\n200\n'\''; }
    init_proxy_rollback
    capture_proxy_host_state 7 1
    before="$ROLLBACK_DIR/unknown-before.json"
    printf '\''[]\n'\'' >"$before"
    if create_proxy_host nginx unknown.example.test npm 81 0 "$before" 2 >"$2" 2>&1; then exit 1; fi
    if fail_after_proxy_mutation proxy_host_application_failed >"$2" 2>&1; then exit 1; fi
    [[ "$RESTORED" == 1 ]]
    grep -q "rollback_incomplete_manual_cleanup_required" "$2"
    ! grep -q "NPM_BOOTSTRAP_STATUS=SUCCESS" "$2"
  ' _ "$SCRIPT" "$TMP_DIR/unknown-create-known-restore.out"

# Issuance failure after an earlier mutation must use the same compensating
# rollback path and emit a failure-only receipt.
NPM_TEST_SCENARIO=issuance-after-mutation PATH="$MOCK_BIN:$PATH" \
\
  bash -c '
    source "$1"
    api_get() { printf '\''{"id":7,"domain_names":["nginx.example.test"],"certificate_id":0}\n'\''; }
    npm_request() { return 1; }
    init_proxy_rollback
    capture_proxy_host_state 7 1
    if fail_after_proxy_mutation certificate_issuance_failed >"$2" 2>&1; then exit 1; fi
     grep -q "NPM_BOOTSTRAP_REASON=certificate_issuance_failed_rollback_incomplete_manual_cleanup_required" "$2"
    ! grep -q "NPM_BOOTSTRAP_STATUS=SUCCESS" "$2"
  ' _ "$SCRIPT" "$TMP_DIR/issuance-after-mutation.out"

# A newly-created host is removable only when the post-delete reread returns
# an explicit NPM 404; transport errors remain rollback-incomplete.
NPM_TEST_SCENARIO=confirmed-404 NPM_TEST_STATE="$TMP_DIR/confirmed-404.state" PATH="$MOCK_BIN:$PATH" \
\
  bash -c 'source "$1"; init_proxy_rollback; register_created_proxy_host 8; rollback_proxy_hosts' _ "$SCRIPT"
NPM_TEST_SCENARIO=ambiguous-reread NPM_TEST_STATE="$TMP_DIR/ambiguous-reread.state" PATH="$MOCK_BIN:$PATH" \
\
  bash -c 'source "$1"; init_proxy_rollback; register_created_proxy_host 8; ! rollback_proxy_hosts' _ "$SCRIPT"
for scenario in non-404-reread malformed-reread transport-delete; do
  NPM_TEST_SCENARIO="$scenario" NPM_TEST_STATE="$TMP_DIR/$scenario.state" PATH="$MOCK_BIN:$PATH" \
\
    bash -c 'source "$1"; init_proxy_rollback; register_created_proxy_host 8; ! rollback_proxy_hosts' _ "$SCRIPT"
done

# A failed restore is never reported as successful rollback.
NPM_TEST_SCENARIO=rollback-incomplete PATH="$MOCK_BIN:$PATH" \
\
  bash -c '
    source "$1"
     READS_8=0
     api_get() {
       case "$1" in
         /api/nginx/proxy-hosts/7) printf '\''{"id":7,"domain_names":["nginx.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}\n'\'' ;;
         /api/nginx/proxy-hosts/8)
           READS_8=$((READS_8 + 1))
           if [[ "$READS_8" == 1 ]]; then
             printf '\''{"id":8,"domain_names":["other.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":0,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}\n'\''
           else
             printf '\''{"id":8,"domain_names":["other.example.test"],"forward_scheme":"http","forward_host":"npm","forward_port":81,"certificate_id":99,"ssl_forced":false,"hsts_enabled":false,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":false,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}\n'\''
           fi ;;
       esac
     }
     ATTEMPTS=0
     npm_request() {
       ATTEMPTS=$((ATTEMPTS + 1))
       [[ "$2" != /api/nginx/proxy-hosts/7 ]]
     }
     init_proxy_rollback
     capture_proxy_host_state 7 1
     capture_proxy_host_state 8 2
     if fail_after_proxy_mutation proxy_host_application_failed >"$2" 2>&1; then exit 1; fi
     grep -q "NPM_BOOTSTRAP_REASON=proxy_host_application_failed_rollback_incomplete_manual_cleanup_required" "$2"
     grep -q "NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=" "$2"
     [[ "$ATTEMPTS" == 2 ]]
       diagnostic_dir="$(grep "NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=" "$2" | cut -d= -f2)"
      [[ -s "$diagnostic_dir/records" ]]
   ' _ "$SCRIPT" "$TMP_DIR/rollback-incomplete.out"

# An incomplete rollback snapshot must fail validation before any PUT and keep
# the manual-cleanup diagnostics available to the caller.
PATH="$MOCK_BIN:$PATH" \
\
  bash -c '
    source "$1"
    api_get() { printf '\''{"id":7,"domain_names":["nginx.example.test"],"certificate_id":0}\n'\''; }
    ATTEMPTS=0
    npm_request() { ATTEMPTS=$((ATTEMPTS + 1)); }
    init_proxy_rollback
    capture_proxy_host_state 7 1
    if fail_after_proxy_mutation proxy_host_application_failed >"$2" 2>&1; then exit 1; fi
    grep -q "NPM_BOOTSTRAP_REASON=proxy_host_application_failed_rollback_incomplete_manual_cleanup_required" "$2"
    grep -q "NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=" "$2"
    [[ "$ATTEMPTS" == 0 ]]
    diagnostic_dir="$(grep "NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=" "$2" | cut -d= -f2)"
    [[ -s "$diagnostic_dir/records" ]]
   ' _ "$SCRIPT" "$TMP_DIR/incomplete-snapshot.out"

# With errexit active at the call site, redacted_failure must not abort the
# failure handler before it retains the manual-cleanup directory.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    set -e
    source "$1"
    init_proxy_rollback
    mark_rollback_incomplete
    fail_after_proxy_mutation set_e_failure
  ' _ "$SCRIPT" >"$TMP_DIR/set-e-after.out" 2>&1 && {
    printf 'set -e fail_after_proxy_mutation unexpectedly succeeded\n' >&2
    exit 1
  }
grep -q 'NPM_BOOTSTRAP_REASON=set_e_failure_rollback_incomplete_manual_cleanup_required' "$TMP_DIR/set-e-after.out"
grep -q 'NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=' "$TMP_DIR/set-e-after.out"
set_e_diagnostic_dir="$(grep 'NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=' "$TMP_DIR/set-e-after.out" | cut -d= -f2)"
[[ -s "$set_e_diagnostic_dir/records" ]]

# The pre-mutation handler also completes its redacted receipt and cleanup
# before returning non-zero under errexit.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    set -e
    source "$1"
    init_proxy_rollback
    printf "%s" "$ROLLBACK_DIR" > "$2"
    fail_before_proxy_mutation set_e_pre_failure
  ' _ "$SCRIPT" "$TMP_DIR/set-e-before.dir" >"$TMP_DIR/set-e-before.out" 2>&1 && {
    printf 'set -e fail_before_proxy_mutation unexpectedly succeeded\n' >&2
    exit 1
  }
grep -q 'NPM_BOOTSTRAP_REASON=set_e_pre_failure_before_proxy_mutation' "$TMP_DIR/set-e-before.out"
set_e_before_dir="$(<"$TMP_DIR/set-e-before.dir")"
[[ ! -e "$set_e_before_dir" ]]

# A successful restore request is incomplete when the reread does not match
# the earliest snapshot.
NPM_TEST_SCENARIO=restore-mismatch PATH="$MOCK_BIN:$PATH" \
\
  bash -c '
    source "$1"
    RESTORE_MISMATCH_READ=0
    api_get() {
      if [[ "$1" == /api/nginx/proxy-hosts/7 ]]; then
        if [[ "$RESTORE_MISMATCH_READ" == 1 ]]; then
          printf '\''{"id":7,"domain_names":["nginx.example.test"],"certificate_id":99}\n'\''
        else
          printf '\''{"id":7,"domain_names":["nginx.example.test"],"certificate_id":0}\n'\''
        fi
      fi
    }
    npm_request() { RESTORE_MISMATCH_READ=1; }
    init_proxy_rollback
    capture_proxy_host_state 7 1
    if fail_after_proxy_mutation proxy_host_application_failed >"$2" 2>&1; then exit 1; fi
     grep -q "NPM_BOOTSTRAP_REASON=proxy_host_application_failed_rollback_incomplete_manual_cleanup_required" "$2"
     grep -q "NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=" "$2"
   ' _ "$SCRIPT" "$TMP_DIR/restore-mismatch.out"

# Inventory capture must consume every metadata-described page and prove the
# final item count before exposing a deletion candidate.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    init_proxy_rollback
    api_get() {
      case "$1" in
        /api/nginx/proxy-hosts\?per_page=200) jq -n '\''{page:1,per_page:200,total:201,data:[range(1;201) | {id:.}]} '\'' ;;
        /api/nginx/proxy-hosts\?page=2\&per_page=200) jq -n '\''{page:2,per_page:200,total:201,data:[{id:201}]} '\'' ;;
        *) return 1 ;;
      esac
    }
    file="$(capture_proxy_host_inventory 1)"
    [[ "$(jq length "$file")" == 201 ]]
  ' _ "$SCRIPT"

# Missing metadata, inconsistent totals, and a failed later page fail closed.
for inventory_case in missing-metadata inconsistent-metadata page-failure; do
  PATH="$MOCK_BIN:$PATH" \
    INVENTORY_CASE="$inventory_case" bash -c '
      source "$1"
      init_proxy_rollback
      api_get() {
        case "$1" in
          /api/nginx/proxy-hosts\?per_page=200)
            case "$INVENTORY_CASE" in
              missing-metadata) printf '\''[]\n'\'' ;;
              inconsistent-metadata) printf '\''{"page":1,"per_page":200,"total":201,"data":[{"id":1}]}\n'\'' ;;
              page-failure) return 1 ;;
            esac
            ;;
          /api/nginx/proxy-hosts\?page=2\&per_page=200)
            [[ "$INVENTORY_CASE" != page-failure ]] || return 1
            printf '\''{"page":2,"per_page":200,"total":201,"data":[]}\n'\''
            ;;
          *) return 1 ;;
        esac
      }
      ! capture_proxy_host_inventory 1
      [[ ! -s "$ROLLBACK_RECORDS" ]]
    ' _ "$SCRIPT"
done

# Existing-host lookup uses the complete inventory: a target on page 2 is
# found, while duplicate IDs and changing pagination metadata fail closed.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    init_proxy_rollback
    api_get() {
      case "$1" in
        /api/nginx/proxy-hosts\?per_page=200) jq -n '\''{page:1,per_page:200,total:201,data:[range(1;201) | {id:.,domain_names:(if . == 201 then ["page-two.example.test"] else [] end)}]}'\'' ;;
        /api/nginx/proxy-hosts\?page=2\&per_page=200) jq -n '\''{page:2,per_page:200,total:201,data:[{id:201,domain_names:["page-two.example.test"]}]}'\'' ;;
        *) return 1 ;;
      esac
    }
    [[ "$(find_proxy_host_id_for_domain page-two.example.test)" == 201 ]]
  ' _ "$SCRIPT"

for inventory_case in duplicate-ids changing-metadata; do
  PATH="$MOCK_BIN:$PATH" \
    INVENTORY_CASE="$inventory_case" bash -c '
      source "$1"
      init_proxy_rollback
      api_get() {
        case "$1" in
          /api/nginx/proxy-hosts\?per_page=200)
            jq -n '\''{page:1,per_page:200,total:201,data:[range(1;201) | {id:.}]}'\''
            ;;
          /api/nginx/proxy-hosts\?page=2\&per_page=200)
            if [[ "$INVENTORY_CASE" == duplicate-ids ]]; then
              jq -n '\''{page:2,per_page:200,total:201,data:[{id:200}]}'\''
            else
              jq -n '\''{page:2,per_page:200,total:202,data:[{id:201},{id:202}]}'\''
            fi
            ;;
          *) return 1 ;;
        esac
      }
      ! find_proxy_host_id_for_domain page-two.example.test
    ' _ "$SCRIPT"
done

# Invalid existing lookup IDs and invalid rollback registrations never reach a
# URL construction or a mutation.
for invalid_id in 0 -1 1.5 null malformed; do
  PATH="$MOCK_BIN:$PATH" \
    INVALID_ID="$invalid_id" bash -c '
      source "$1"
      init_proxy_rollback
      api_get() { printf '\''{"page":1,"per_page":200,"total":1,"data":[{"id":%s,"domain_names":["invalid.example.test"]}]}'\'' "$INVALID_ID"; }
      ! find_proxy_host_id_for_domain invalid.example.test
    ' _ "$SCRIPT"
done

for invalid_id in 0 -1 1.5 null malformed ''; do
  PATH="$MOCK_BIN:$PATH" \
    INVALID_ID="$invalid_id" bash -c '
      source "$1"
      init_proxy_rollback
      ! register_created_proxy_host "$INVALID_ID"
      [[ ! -s "$ROLLBACK_RECORDS" ]]
    ' _ "$SCRIPT"
done

# An incomplete existing-host inventory is never interpreted as "not found":
# ensure_proxy_host fails before create/update/delete can be invoked.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    init_proxy_rollback
    ENSURE_PROXY_HOSTS=1
    MUTATIONS=0
    api_get() { printf '\''{"page":1,"per_page":200,"total":201,"data":[{"id":1}]}'\''; }
    curl() { MUTATIONS=$((MUTATIONS + 1)); return 1; }
    ! ensure_proxy_host nginx incomplete.example.test npm 81 0
    [[ "$MUTATIONS" == 0 ]]
    [[ ! -s "$ROLLBACK_RECORDS" ]]
  ' _ "$SCRIPT"

# Only canonical positive integer IDs are accepted for create responses and
# rollback records; malformed values never reach jq or a DELETE request.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    for id in -1 0 1.5 null malformed ""; do
      if is_positive_integer_id "$id"; then exit 1; fi
    done
    for id in 1 8 200 9007199254740991; do
      is_positive_integer_id "$id"
    done
    for id in 9007199254740992 9007199254740993 999999999999999999999999999999; do
      if is_positive_integer_id "$id"; then exit 1; fi
    done
  ' _ "$SCRIPT"

# Create responses must contain a JSON number or canonical decimal string
# representation. Exponent forms and non-integers are rejected before
# registration or URL construction; a valid ID is registered only after the
# unique new inventory match is proved.
for create_id in '"03"' '"08"' '"3.0"' '"3e0"' '""' '"-8"' '" 8"' '"8 "' '8e0' '8.5' '-8' '0'; do
  PATH="$MOCK_BIN:$PATH" \
    CREATE_ID="$create_id" bash -c '
      source "$1"
      init_proxy_rollback
      before="$ROLLBACK_DIR/before.json"
      printf "[]\n" >"$before"
      proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
      api_get() {
        printf "%s\n" "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":8,\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}]}"
      }
       curl() {
         if [[ -n "${CREATE_RESPONSE:-}" ]]; then printf "%s\n201\n" "$CREATE_RESPONSE"; else printf "{\"id\":%s}\n201\n" "$CREATE_ID"; fi
       }
      if create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1; then
        exit 1
      fi
      [[ ! -s "$ROLLBACK_RECORDS" ]]
    ' _ "$SCRIPT"
done

# Canonical positive decimal strings are parsed, then still require the
# post-create inventory and payload validation before registration.
for create_response in '{"id":"8"}' '{"id":"9007199254740991"}'; do
  PATH="$MOCK_BIN:$PATH" \
    CREATE_RESPONSE="$create_response" bash -c '
      source "$1"
      init_proxy_rollback
      before="$ROLLBACK_DIR/before.json"
      printf "[]\n" >"$before"
      proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
      api_get() {
        if [[ "$CREATE_RESPONSE" == *9007199254740991* ]]; then
          printf "%s\n" "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":9007199254740991,\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}]}"
        else
          printf "%s\n" "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":8,\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}]}"
        fi
      }
      curl() { printf "%s\n201\n" "$CREATE_RESPONSE"; }
      expected_id=8
      [[ "$CREATE_RESPONSE" == *9007199254740991* ]] && expected_id=9007199254740991
      [[ "$(create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1)" == "$expected_id" ]]
      [[ "$(<"$ROLLBACK_RECORDS")" == "created|$expected_id|" ]]
    ' _ "$SCRIPT"
done

PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    init_proxy_rollback
    before="$ROLLBACK_DIR/before.json"
    printf "[]\n" >"$before"
    proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
    api_get() {
      printf "%s\n" "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":8,\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}]}"
    }
    curl() { printf "%s\n201\n" "{ \"id\" : 8 }"; }
    [[ "$(create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1)" == 8 ]]
    [[ "$(<"$ROLLBACK_RECORDS")" == "created|8|" ]]
  ' _ "$SCRIPT"

# Structural parsing rejects nested-only IDs, duplicate keys, multiple JSON
# values, strings, null, sign, zero, fraction, exponent, and malformed JSON.
for create_response in \
  '{"data":{"id":8}}' \
  '{"id":8,"id":9}' \
  '{"id":8} {"id":9}' $'null\n{"id":8}' \
  '{"id":"03"}' '{"id":"08"}' '{"id":"3.0"}' '{"id":"3e0"}' '{"id":""}' '{"id":"-8"}' '{"id":" 8"}' '{"id":"8 "}' '{"id":null}' '{"id":-8}' \
  '{"id":0}' '{"id":8.5}' '{"id":8e0}' '[]' 'null' 'malformed-response'; do
  PATH="$MOCK_BIN:$PATH" \
    CREATE_RESPONSE="$create_response" bash -c '
      source "$1"
      init_proxy_rollback
      before="$ROLLBACK_DIR/before.json"
      printf "[]\n" >"$before"
      proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
      api_get() { printf "%s\n" "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":8,\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}]}"; }
      curl() { printf "%s\n201\n" "$CREATE_RESPONSE"; }
      if [[ "$CREATE_RESPONSE" == malformed-response ]]; then
        ! extract_create_response_id "$CREATE_RESPONSE"
      else
        ! create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1
      fi
      [[ ! -s "$ROLLBACK_RECORDS" ]]
    ' _ "$SCRIPT"
done

# Rejected create responses leave only structural, sanitized diagnostics. The
# invalid-JSON case deliberately contains secret-like text to prove no content
# is copied into the diagnostic.
for diagnostic_case in valid-rejected invalid-json; do
  PATH="$MOCK_BIN:$PATH" DIAGNOSTIC_CASE="$diagnostic_case" bash -c '
    source "$1"
    init_proxy_rollback
    before="$ROLLBACK_DIR/before.json"
    printf "[]\n" >"$before"
    proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
    api_get() { printf "%s\n" "[]"; }
    if [[ "$DIAGNOSTIC_CASE" == valid-rejected ]]; then
      CREATE_RESPONSE="{\"id\":\"08\",\"secret\":\"super-secret\",\"payload\":{\"token\":\"payload-secret\"}}"
    else
      CREATE_RESPONSE="not-json super-secret payload-secret"
    fi
    curl() { printf "%s\n201\n" "$CREATE_RESPONSE"; }
    ! create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1
    diagnostic="$ROLLBACK_DIR/create-response-diagnostic-1.json"
    [[ -s "$diagnostic" ]]
    if [[ "$DIAGNOSTIC_CASE" == valid-rejected ]]; then
      jq -e ".json_valid == true and .json_top_type == \"object\" and .id_present == true and .id_type == \"string\" and .id_string_length == 2 and .id_string_canonical_decimal == false" "$diagnostic" >/dev/null
      ! grep -Eq "08|super-secret|payload-secret|secret|token" "$diagnostic"
    else
      [[ "$(<"$diagnostic")" == "{\"json_valid\":false}" ]]
      ! grep -Eq "super-secret|payload-secret|not-json|payload" "$diagnostic"
    fi
  ' _ "$SCRIPT"
done

PATH="$MOCK_BIN:$PATH" bash -c '
  source "$1"
  init_proxy_rollback
  before="$ROLLBACK_DIR/before.json"
  printf "[]\n" >"$before"
  proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
  api_get() { printf "%s\n" "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":8,\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}]}"; }
  curl() { printf "%s\n201\n" "{\"id\":8,\"meta\":{\"id\":1}}"; }
  [[ "$(create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1)" == 8 ]]
  [[ "$(<"$ROLLBACK_RECORDS")" == "created|8|" ]]
' _ "$SCRIPT"

for numeric_response in '{"id":8.5}' '{"id":8e0}'; do
  PATH="$MOCK_BIN:$PATH" CREATE_RESPONSE="$numeric_response" bash -c '
    source "$1"
    init_proxy_rollback
    before="$ROLLBACK_DIR/before.json"
    printf "[]\n" >"$before"
    proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
    api_get() { printf "%s\n" "[]"; }
    curl() { printf "%s\n201\n" "$CREATE_RESPONSE"; }
    ! create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1
    diagnostic="$ROLLBACK_DIR/create-response-diagnostic-1.json"
    jq -e ".json_valid == true and .json_top_type == \"object\" and .id_present == true and .id_type == \"number\" and .id_number_kind == \"non-integer\" and .id_token_length == 3 and .id_canonical_positive == false" "$diagnostic" >/dev/null
    ! grep -Eq "8\.5|8e0|payload|secret" "$diagnostic"
  ' _ "$SCRIPT"
done

for structural_case in duplicate nested trailing; do
  PATH="$MOCK_BIN:$PATH" STRUCTURAL_CASE="$structural_case" bash -c '
    source "$1"
    init_proxy_rollback
    before="$ROLLBACK_DIR/before.json"
    printf "[]\n" >"$before"
    proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
    api_get() { printf "%s\n" "[]"; }
    case "$STRUCTURAL_CASE" in
      duplicate) CREATE_RESPONSE="{\"id\":1,\"id\":2,\"secret\":\"fixture-secret\"}" ;;
      nested) CREATE_RESPONSE="{\"data\":{\"id\":2,\"secret\":\"fixture-secret\"}}" ;;
      trailing) CREATE_RESPONSE="{\"id\":1} {\"secret\":\"fixture-secret\"}" ;;
    esac
    curl() { printf "%s\n201\n" "$CREATE_RESPONSE"; }
    ! create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1
    diagnostic="$ROLLBACK_DIR/create-response-diagnostic-1.json"
    [[ -s "$diagnostic" ]]
    case "$STRUCTURAL_CASE" in
      duplicate)
        jq -e ".duplicate_key_detected == true and .nested_id_detected == false and .trailing_data_detected == false and .top_level_key_count == 3 and .top_level_data_present == false" "$diagnostic" >/dev/null ;;
      nested)
        jq -e ".duplicate_key_detected == false and .nested_id_detected == true and .trailing_data_detected == false and .top_level_key_count == 1 and .top_level_data_present == true" "$diagnostic" >/dev/null ;;
      trailing)
        jq -e ".duplicate_key_detected == false and .nested_id_detected == false and .trailing_data_detected == true and .top_level_key_count == 1" "$diagnostic" >/dev/null ;;
    esac
    ! grep -Eq "fixture-secret|secret|payload|\\\"id\\\"[[:space:]]*:" "$diagnostic"
  ' _ "$SCRIPT"
done

# The exact jq/JSON-safe upper bound is accepted at every JSON create-ID
# boundary, while the next value and larger values fail before registration or
# URL construction. Distinct unsafe values that jq would round together are
# rejected rather than treated as a usable ID.
for create_response in \
  '{"id":9007199254740992}' \
  '{"id":9007199254740993}' \
  '{"id":999999999999999999999999999999}'; do
  PATH="$MOCK_BIN:$PATH" \
    CREATE_RESPONSE="$create_response" bash -c '
      source "$1"
      init_proxy_rollback
      before="$ROLLBACK_DIR/before.json"
      printf "[]\n" >"$before"
      proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
      api_get() { printf "%s\n" "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":9007199254740991,\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}]}"; }
      curl() { printf "%s\n201\n" "$CREATE_RESPONSE"; }
      ! create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1
      [[ ! -s "$ROLLBACK_RECORDS" ]]
    ' _ "$SCRIPT"
done

PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    init_proxy_rollback
    before="$ROLLBACK_DIR/before.json"
    printf "[]\n" >"$before"
    proxy_host_payload() { printf "%s" "{\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}"; }
    api_get() { printf "%s\n" "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":9007199254740991,\"domain_names\":[\"nginx.example.test\"],\"forward_scheme\":\"http\",\"forward_host\":\"npm\",\"forward_port\":81,\"certificate_id\":0}]}"; }
    curl() { printf "%s\n201\n" "{\"id\":9007199254740991}"; }
    [[ "$(create_proxy_host nginx nginx.example.test npm 81 0 "$before" 1)" == 9007199254740991 ]]
    [[ "$(<"$ROLLBACK_RECORDS")" == "created|9007199254740991|" ]]
  ' _ "$SCRIPT"

# Certificate creation IDs are validated through the custom-certificate main
# path before upload/API URL construction.
for certificate_response in \
  '{"data":{"id":8}}' '{"id":8,"id":9}' '{"id":8} {"id":9}' \
  '{"id":8,"data":{"id":9}}' $'null\n{"id":8}' \
  '{"id":"03"}' '{"id":"08"}' '{"id":"3.0"}' '{"id":"3e0"}' '{"id":""}' '{"id":"-8"}' '{"id":" 8"}' '{"id":"8 "}' '{"id":null}' '{"id":-8}' \
  '{"id":0}' '{"id":8.5}' '{"id":8e0}' '[]' 'null' 'malformed-response'; do
  certificate_state="$TMP_DIR/certificate-invalid-${RANDOM}.state"
  if CERT_CREATE_RESPONSE="$certificate_response" NPM_TEST_SCENARIO=custom-invalid NPM_TEST_STATE="$certificate_state" \
    PATH="$MOCK_BIN:$PATH" \
    NPM_API_URL=http://127.0.0.1:81 NPM_CONNECT_TIMEOUT=1 NPM_OPERATION_TIMEOUT=1 \
    NPM_READY_DELAY=0 NPM_READY_ATTEMPTS=3 TLS_MODE=local BASE_DOMAIN=example.test ONLY_PREFIX=nginx \
    NPM_LOCAL_CERT_FILE="$TMP_DIR/local-nginx.crt" NPM_LOCAL_KEY_FILE="$TMP_DIR/local-nginx.key" \
    bash "$SCRIPT" >"$certificate_state.out" 2>&1; then
    printf 'Expected invalid certificate response to fail: %s\n' "$certificate_response" >&2
    exit 1
  fi
  if ! grep -q 'NPM_BOOTSTRAP_STATUS=FAILED' "$certificate_state.out"; then
    sed -n '1,120p' "$certificate_state.out" >&2
    exit 1
  fi
  if [[ -f "$certificate_state.certificate-url-calls" && "$(<"$certificate_state.certificate-url-calls")" != 0 ]]; then
    cat "$certificate_state.out" >&2
    printf 'Unexpected certificate URL calls for %s\n' "$certificate_response" >&2
    exit 1
  fi
done

# The Let's Encrypt creation caller applies the same validation before any
# certificate detail URL is queried or a proxy host is mutated.
for certificate_response in \
  '{"data":{"id":8}}' '{"id":8,"data":{"id":9}}' '{"id":8,"id":9}' '{"id":8} {"id":9}' $'null\n{"id":8}' \
  '{"id":"8"}' '{"id":"08"}' '{"id":null}' '{"id":-8}' \
  '{"id":0}' '{"id":8.5}' '{"id":8e0}' '[]' 'null' 'malformed-response'; do
  certificate_state="$TMP_DIR/le-certificate-invalid-${RANDOM}.state"
  if CERT_CREATE_RESPONSE="$certificate_response" NPM_TEST_SCENARIO=le-invalid NPM_TEST_STATE="$certificate_state" \
    PATH="$MOCK_BIN:$PATH" \
    NPM_API_URL=http://127.0.0.1:81 NPM_CONNECT_TIMEOUT=1 NPM_OPERATION_TIMEOUT=1 \
    NPM_READY_DELAY=0 NPM_READY_ATTEMPTS=3 TLS_MODE=letsencrypt BASE_DOMAIN=example.test ONLY_PREFIX=nginx \
    bash "$SCRIPT" >"$certificate_state.out" 2>&1; then
    printf 'Expected invalid ACME certificate response to fail: %s\n' "$certificate_response" >&2
    exit 1
  fi
  grep -q 'NPM_BOOTSTRAP_STATUS=FAILED' "$certificate_state.out"
  [[ ! -f "$certificate_state.certificate-url-calls" || "$(<"$certificate_state.certificate-url-calls")" == 0 ]]
done

# NPM versions that return a bounded list are accepted only when the short
# list proves that the complete inventory fits in the requested page.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    init_proxy_rollback
    api_get() {
      [[ "$1" == /api/nginx/proxy-hosts\?per_page=200 ]] || return 1
      jq -n '\''[range(1;12) | {id: ., domain_names: (if . == 11 then ["list-shaped.example.test"] else [] end)}]'\''
    }
    file="$(capture_proxy_host_inventory 1)"
    [[ "$(jq length "$file")" == 11 ]]
    [[ "$(find_proxy_host_id_for_domain list-shaped.example.test)" == 11 ]]
  ' _ "$SCRIPT"

# An exactly-full list cannot prove that no later records exist and must fail
# closed rather than being treated as a complete inventory.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    init_proxy_rollback
    api_get() { jq -n '\''[range(1;201) | {id: .}]'\''; }
    ! capture_proxy_host_inventory 1
  ' _ "$SCRIPT"

# List-shaped responses reject malformed JSON, duplicate IDs, and non-positive
# or non-integer IDs before an existing-host lookup or mutation is possible.
for list_response in \
  '[{"id":1},{"id":1}]' \
  '[{"id":0}]' '[{"id":-1}]' '[{"id":1.5}]' \
  '[{"id":"1"}]' '[{"id":1}] {"id":2}' 'malformed-response'; do
  PATH="$MOCK_BIN:$PATH" \
    LIST_RESPONSE="$list_response" bash -c '
      source "$1"
      init_proxy_rollback
      api_get() { printf "%s" "$LIST_RESPONSE"; }
      ! capture_proxy_host_inventory 1
    ' _ "$SCRIPT"
done

# List-shaped normalization uses the same canonical range as the jq envelope
# path: ordinary IDs and the exact maximum are accepted; the next value,
# huge values, and distinct values that jq would round together are rejected.
for list_response in \
  '[{"id":9007199254740992}]' \
  '[{"id":999999999999999999999999999999}]' \
  '[{"id":9007199254740992},{"id":9007199254740993}]' \
  '[{"id":1},{"id":9007199254740991}]'; do
  PATH="$MOCK_BIN:$PATH" \
    LIST_RESPONSE="$list_response" bash -c '
      source "$1"
      init_proxy_rollback
      api_get() { printf "%s" "$LIST_RESPONSE"; }
      if [[ "$LIST_RESPONSE" == *9007199254740991* && "$LIST_RESPONSE" != *9007199254740992* ]]; then
        file="$(capture_proxy_host_inventory 1)"
        [[ "$(jq length "$file")" == 2 ]]
      else
        ! capture_proxy_host_inventory 1
      fi
    ' _ "$SCRIPT"
done

# Envelope IDs are validated from their original JSON lexemes before jq sees
# them: decimal, exponent, noncanonical, and unsafe values are rejected.
for envelope_id in 1.5 8e0 08 9007199254740992 9007199254740993 999999999999999999999999999999; do
  PATH="$MOCK_BIN:$PATH" \
    ENVELOPE_ID="$envelope_id" bash -c '
      source "$1"
      init_proxy_rollback
      api_get() { printf "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":%s}]}\n" "$ENVELOPE_ID"; }
      ! capture_proxy_host_inventory 1
    ' _ "$SCRIPT"
done

# Ordinary and maximum safe canonical envelope IDs remain usable.
for envelope_id in 8 9007199254740991; do
  PATH="$MOCK_BIN:$PATH" \
    ENVELOPE_ID="$envelope_id" bash -c '
      source "$1"
      init_proxy_rollback
      api_get() { printf "{\"page\":1,\"per_page\":200,\"total\":1,\"data\":[{\"id\":%s}]}\n" "$ENVELOPE_ID"; }
      file="$(capture_proxy_host_inventory 1)"
      [[ "$(jq -r ".[0].id" "$file")" == "$ENVELOPE_ID" ]]
    ' _ "$SCRIPT"
done

# A certificate lookup never converts unsafe data or transport failure into
# "not found", which is the branch that would create a duplicate record.
for lookup_case in unsafe transport; do
  PATH="$MOCK_BIN:$PATH" \
    LOOKUP_CASE="$lookup_case" bash -c '
      source "$1"
      api_get() {
        if [[ "$LOOKUP_CASE" == unsafe ]]; then
          printf "[{\"id\":9007199254740992,\"provider\":\"other\",\"nice_name\":\"daiana-local-tls\"}]"
        else
          return 28
        fi
      }
      ! find_custom_certificate_id daiana-local-tls
  ' _ "$SCRIPT"
done

# Custom certificate lookup only falls back from an explicit null nice_name;
# non-string metadata must fail closed instead of creating a duplicate.
for invalid_nice_name in false 42 '{}' '[]'; do
  PATH="$MOCK_BIN:$PATH" \
    INVALID_NICE_NAME="$invalid_nice_name" bash -c '
      source "$1"
      api_get() {
        printf "[{\"id\":99,\"provider\":\"other\",\"nice_name\":%s,\"name\":\"daiana-local-tls\"}]" "$INVALID_NICE_NAME"
      }
      ! find_custom_certificate_id daiana-local-tls
    ' _ "$SCRIPT"
done

# A null nice_name falls back to name, and an existing valid string is reused
# directly; neither path may create a duplicate certificate.
PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    CREATE_ATTEMPTS=0
    api_get() {
      printf '\''[{"id":99,"provider":"other","nice_name":null,"name":"daiana-local-tls"}]'\''
    }
    create_custom_certificate_record() { CREATE_ATTEMPTS=$((CREATE_ATTEMPTS + 1)); return 1; }
    upload_custom_certificate() { [[ "$1" == 99 ]]; }
    [[ "$(ensure_custom_certificate)" == 99 ]]
    [[ "$CREATE_ATTEMPTS" == 0 ]]
  ' _ "$SCRIPT"

  PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    CREATE_ATTEMPTS=0
    api_get() {
      printf '\''[{"id":100,"provider":"other","nice_name":"daiana-local-tls"}]'\''
    }
    create_custom_certificate_record() { CREATE_ATTEMPTS=$((CREATE_ATTEMPTS + 1)); return 1; }
    upload_custom_certificate() { [[ "$1" == 100 ]]; }
    [[ "$(ensure_custom_certificate)" == 100 ]]
    [[ "$CREATE_ATTEMPTS" == 0 ]]
  ' _ "$SCRIPT"

# Certificate metadata verification checks the returned top-level ID before
# provider, status, domain, or expiry.
  PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    api_get() { printf "{\"id\":43,\"provider\":\"letsencrypt\",\"status\":\"issued\",\"domain_names\":[\"nginx.example.test\"],\"expires_on\":\"2099-01-01T00:00:00Z\"}"; }
     ! verify_certificate_metadata_for_domain 42 nginx.example.test
  ' _ "$SCRIPT"

  PATH="$MOCK_BIN:$PATH" \
  bash -c '
    source "$1"
    api_get() { printf "{\"id\":43,\"provider\":\"letsencrypt\",\"status\":null,\"domain_names\":[\"nginx.example.test\"],\"expires_on\":\"2099-01-01T00:00:00Z\"}"; }
    verify_certificate_metadata_for_domain 43 nginx.example.test
  ' _ "$SCRIPT"

printf 'NPM bootstrap resilience mock tests passed\n'
