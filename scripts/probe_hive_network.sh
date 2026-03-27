#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-eu}"
case "$REGION" in
  eu|us|uk|au) ;;
  *)
    echo "Region must be one of: eu, us, uk, au" >&2
    exit 1
    ;;
esac

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/outputs"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
CSV="$OUT_DIR/network-probe-$REGION-$TS.csv"
TXT="$OUT_DIR/network-probe-$REGION-$TS.txt"

case "$REGION" in
  eu)
    HIVE_HOST="eu.hive.papercut.com"
    POCKET_HOST="eu.pocket.papercut.com"
    PMITC_HOST="eu.pmitc.papercut.com"
    CLOUDNODE_HOST="cloudnode.eu.pmitc.papercut.com"
    SEND_HOST="eu.send.papercut.com"
    ;;
  us)
    HIVE_HOST="hive.papercut.com"
    POCKET_HOST="pocket.papercut.com"
    PMITC_HOST="pmitc.papercut.com"
    CLOUDNODE_HOST="cloudnode.pmitc.papercut.com"
    SEND_HOST="send.papercut.com"
    ;;
  uk)
    HIVE_HOST="uk.hive.papercut.com"
    POCKET_HOST="uk.pocket.papercut.com"
    PMITC_HOST="uk.pmitc.papercut.com"
    CLOUDNODE_HOST="cloudnode.uk.pmitc.papercut.com"
    SEND_HOST="uk.send.papercut.com"
    ;;
  au)
    HIVE_HOST="au.hive.papercut.com"
    POCKET_HOST="au.pocket.papercut.com"
    PMITC_HOST="au.pmitc.papercut.com"
    CLOUDNODE_HOST="cloudnode.au.pmitc.papercut.com"
    SEND_HOST="au.send.papercut.com"
    ;;
esac

HOSTS=(
  "$HIVE_HOST"
  "$POCKET_HOST"
  "$PMITC_HOST"
  "$CLOUDNODE_HOST"
  "update.pmitc.papercut.com"
  "regions.pmitc.papercut.com"
  "mqtt.notifications.cloud.papercut.com"
  "mqtt2.notifications.cloud.papercut.com"
  "mqtt3.notifications.cloud.papercut.com"
  "pkg.cloud.papercut.com"
  "$SEND_HOST"
  "login.papercut.com"
  "storage.googleapis.com"
  "securetoken.googleapis.com"
  "identitytoolkit.googleapis.com"
  "www.googleapis.com"
)

printf 'host,expected_protocol,dns_ok,tls_ok,http_code,remote_ip,error\n' > "$CSV"

for host in "${HOSTS[@]}"; do
  expected_protocol="https"
  case "$host" in
    mqtt.notifications.cloud.papercut.com|mqtt2.notifications.cloud.papercut.com|mqtt3.notifications.cloud.papercut.com)
      expected_protocol="mqtt_tls"
      ;;
  esac

  dns_ok="no"
  tls_ok="no"
  http_code=""
  remote_ip=""
  error=""

  if getent ahosts "$host" >/dev/null 2>&1; then
    dns_ok="yes"
  else
    error="dns_failed"
  fi

  if [[ "$dns_ok" == "yes" ]]; then
    if timeout 8 openssl s_client -connect "$host:443" -servername "$host" </dev/null >/tmp/pc_ssl_$$.txt 2>/tmp/pc_ssl_err_$$.txt; then
      if grep -q "Verify return code: 0 (ok)" /tmp/pc_ssl_$$.txt; then
        tls_ok="yes"
      else
        tls_ok="partial"
      fi
    else
      tls_ok="no"
      error="tls_connect_failed"
    fi
    rm -f /tmp/pc_ssl_$$.txt /tmp/pc_ssl_err_$$.txt
  fi

  if [[ "$dns_ok" == "yes" && "$expected_protocol" == "https" ]]; then
    curl_out="$(curl -sS -o /dev/null -m 10 -w '%{http_code} %{remote_ip}' "https://$host" 2>/tmp/pc_curl_err_$$.txt || true)"
    if [[ -n "$curl_out" ]]; then
      http_code="$(printf '%s' "$curl_out" | awk '{print $1}')"
      remote_ip="$(printf '%s' "$curl_out" | awk '{print $2}')"
    fi
    if [[ -z "$error" ]] && [[ "$http_code" == "000" || -z "$http_code" ]]; then
      error="https_probe_failed"
    fi
    rm -f /tmp/pc_curl_err_$$.txt
  elif [[ "$expected_protocol" == "mqtt_tls" ]]; then
    http_code="n/a"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$host" "$expected_protocol" "$dns_ok" "$tls_ok" "$http_code" "$remote_ip" "$error" >> "$CSV"
done

{
  echo "=== Hive Network Probe ==="
  echo "timestamp_utc=$TS"
  echo "region=$REGION"
  echo
  echo "CSV=$CSV"
  echo
  cat "$CSV"
} | tee "$TXT"

echo "Wrote: $CSV"
echo "Wrote: $TXT"
