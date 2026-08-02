#!/bin/bash
set -u

echo "🚀 Starting X-UI + Tor + nginx reverse proxy..."

CONFIG_FILE="/etc/x-ui/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ config.json not found at $CONFIG_FILE"
    exit 1
fi

SETUP_STATUS_DIR="/var/www/tor-status"
mkdir -p "$SETUP_STATUS_DIR"

NGINX_PORT=$(jq -r '.server.public_port // 3000' "$CONFIG_FILE")
export NGINX_PORT

ROTATE_SECONDS=$(jq -r '.tor.rotate_seconds' "$CONFIG_FILE")
XUI_INTERNAL_PORT=$(jq -r '.xui.internal_port' "$CONFIG_FILE")
XUI_WEB_BASE_PATH=$(jq -r '.xui.web_base_path' "$CONFIG_FILE")
BOOTSTRAP_TIMEOUT=$(jq -r '.tor.bootstrap_timeout // 240' "$CONFIG_FILE")
VERIFY_MAX_RETRIES=$(jq -r '.tor.verify_max_retries // 15' "$CONFIG_FILE")
VERIFY_RETRY_SLEEP=$(jq -r '.tor.verify_retry_sleep // 4' "$CONFIG_FILE")
CIRCUIT_SETTLE_SLEEP=$(jq -r '.tor.circuit_settle_sleep // 6' "$CONFIG_FILE")
PARALLEL_BOOTSTRAP=$(jq -r '.tor.parallel_bootstrap // true' "$CONFIG_FILE")
PARALLEL_VERIFY=$(jq -r '.tor.parallel_verify // true' "$CONFIG_FILE")

EXCLUDE_COUNTRIES=$(jq -r '.tor.exclude_countries | map("{\(.)}") | join(",")' "$CONFIG_FILE")

DIRECT_ENABLED=$(jq -r '.direct.enabled // true' "$CONFIG_FILE")
DIRECT_PORT=$(jq -r '.direct.port // 8080' "$CONFIG_FILE")
DIRECT_PATH=$(jq -r '.direct.path // "/direct"' "$CONFIG_FILE")
DIRECT_TAG=$(jq -r '.direct.tag // "direct-inbound"' "$CONFIG_FILE")

mapfile -t GEOIP_PROVIDERS < <(jq -r '.tor.verification.geoip_providers[]? // empty' "$CONFIG_FILE")
if [ "${#GEOIP_PROVIDERS[@]}" -eq 0 ]; then
    GEOIP_PROVIDERS=("ip-api.com" "ipinfo.io" "ipwho.is" "ipapi.co")
fi

mapfile -t IP_ECHO_URLS < <(jq -r '.tor.verification.test_urls[]? // empty' "$CONFIG_FILE")
if [ "${#IP_ECHO_URLS[@]}" -eq 0 ]; then
    IP_ECHO_URLS=("https://api.ipify.org" "https://icanhazip.com")
fi

cd /usr/local/x-ui || { echo "❌ /usr/local/x-ui not found"; exit 1; }

pkill -f xray 2>/dev/null || true
pkill -f tor 2>/dev/null || true
sleep 3

echo "🔧 Applying panel settings via x-ui CLI..."
./x-ui setting -port "$XUI_INTERNAL_PORT" -webBasePath "$XUI_WEB_BASE_PATH" || echo "⚠️ x-ui setting failed, continuing"

echo "🔧 Generating per-country Tor instances from config.json..."
mkdir -p /var/log/tor /etc/tor/instances /var/lib/tor-instances /tmp/tor-verify

COUNTRY_COUNT=$(jq '.tor.countries | length' "$CONFIG_FILE")

rm -f /var/www/tor-status/*.json

get_country_from_ip() {
    local ip="$1"
    local country=""

    for provider in "${GEOIP_PROVIDERS[@]}"; do
        case "$provider" in
            ip-api.com)
                country=$(curl -s --max-time 4 --connect-timeout 3 \
                    "http://ip-api.com/json/${ip}?fields=countryCode" 2>/dev/null \
                    | jq -r '.countryCode // empty' 2>/dev/null)
                ;;
            ipinfo.io)
                country=$(curl -s --max-time 4 --connect-timeout 3 \
                    "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '"[:space:]')
                ;;
            ipwho.is)
                country=$(curl -s --max-time 4 --connect-timeout 3 \
                    "https://ipwho.is/${ip}?fields=country_code,success" 2>/dev/null \
                    | jq -r 'select(.success == true) | .country_code // empty' 2>/dev/null)
                ;;
            ipapi.co)
                country=$(curl -s --max-time 4 --connect-timeout 3 \
                    "https://ipapi.co/${ip}/country/" 2>/dev/null | tr -d '[:space:]')
                ;;
            *)
                continue
                ;;
        esac

        country=$(echo "$country" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z')

        if [ -n "$country" ] && [ "$country" != "null" ] && [ "${#country}" -eq 2 ]; then
            echo "$country"
            return 0
        fi
    done

    echo ""
    return 1
}

force_new_circuit() {
    local code="$1" socks_port="$2" control_port="$3"
    local cookie_file="/var/lib/tor-instances/${code}/control_auth_cookie"

    [ -f "$cookie_file" ] || { echo "⚠️ [${code}] Cookie file not found"; return 1; }

    local hex
    hex=$(od -An -tx1 "$cookie_file" 2>/dev/null | tr -d ' \n')
    [ -n "$hex" ] || { echo "⚠️ [${code}] Could not read control cookie"; return 1; }

    {
        printf 'AUTHENTICATE %s\r\n' "$hex"
        printf 'SIGNAL NEWNYM\r\n'
        printf 'QUIT\r\n'
    } | timeout 8 socat - "TCP:127.0.0.1:${control_port}" 2>/dev/null

    return 0
}

verify_tor_exit() {
    local code="$1" socks_port="$2" expected_code="$3"
    local retry=0

    echo "🔍 [${code}] Verifying exit country on SOCKS port ${socks_port}..."

    while [ $retry -lt "$VERIFY_MAX_RETRIES" ]; do
        local exit_ip=""

        for url in "${IP_ECHO_URLS[@]}"; do
            exit_ip=$(curl -s --max-time 8 --connect-timeout 4 \
                --socks5-hostname "127.0.0.1:${socks_port}" "$url" 2>/dev/null \
                | head -1 | tr -d '[:space:]')
            if [[ "$exit_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                break
            fi
            exit_ip=""
        done

        if [ -z "$exit_ip" ]; then
            retry=$((retry + 1))
            echo "⚠️ [${code}] Attempt ${retry}/${VERIFY_MAX_RETRIES}: no exit IP yet, forcing new circuit"
            force_new_circuit "$code" "$socks_port" "$4"
            sleep "$VERIFY_RETRY_SLEEP"
            continue
        fi

        local actual_country
        actual_country=$(get_country_from_ip "$exit_ip")

        if [ -z "$actual_country" ]; then
            retry=$((retry + 1))
            echo "⚠️ [${code}] Attempt ${retry}/${VERIFY_MAX_RETRIES}: exit IP ${exit_ip} — country lookup failed"
            sleep "$VERIFY_RETRY_SLEEP"
            continue
        fi

        if [ "$actual_country" = "$expected_code" ]; then
            echo "✅ [${code}] Verified — exit ${exit_ip} is in ${expected_code}"
            return 0
        fi

        retry=$((retry + 1))
        echo "❌ [${code}] Attempt ${retry}/${VERIFY_MAX_RETRIES}: exit ${exit_ip} resolved to '${actual_country}', expected '${expected_code}' — forcing new circuit"
        force_new_circuit "$code" "$socks_port" "$4"
        sleep "$VERIFY_RETRY_SLEEP"
    done

    echo "❌ [${code}] Failed to find a ${expected_code} exit after ${VERIFY_MAX_RETRIES} attempts"
    return 1
}

check_tor_running() {
    local code="$1"
    local pid_file="/var/run/tor-${code}.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    return 1
}

update_setup_status() {
    local verified_count=0 total_count=0
    for f in /var/www/tor-status/*.json; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in all.json|setup-progress.json) continue ;; esac
        total_count=$((total_count + 1))
        jq -e '.verified == true' "$f" >/dev/null 2>&1 && verified_count=$((verified_count + 1))
    done

    local now complete="false"
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ "$total_count" -gt 0 ] && [ "$verified_count" -eq "$total_count" ]; then
        complete="true"
    fi

    printf '{"total":%d,"verified":%d,"complete":%s,"timestamp":"%s"}\n' \
        "$total_count" "$verified_count" "$complete" "$now" > /var/www/tor-status/setup-progress.json
}

write_status_json() {
    local code="$1" exit_ip="$2" verified="$3" reason="${4:-}"
    local reachable now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    [ "$verified" = "true" ] && reachable="true" || reachable="false"

    if [ -n "$reason" ]; then
        printf '{"country":"%s","exit_ip":"%s","reachable":%s,"verified":%s,"checked_at":"%s","reason":"%s"}\n' \
            "$code" "$exit_ip" "$reachable" "$verified" "$now" "$reason" > "/var/www/tor-status/${code}.json"
    else
        printf '{"country":"%s","exit_ip":"%s","reachable":%s,"verified":%s,"checked_at":"%s"}\n' \
            "$code" "$exit_ip" "$reachable" "$verified" "$now" > "/var/www/tor-status/${code}.json"
    fi
}

start_tor_instance() {
    local code="$1" socks_port="$2" control_port="$3"
    local datadir="/var/lib/tor-instances/${code}"
    local logdir="/var/log/tor/${code}"
    local conf="/etc/tor/instances/torrc.${code}"
    local pid_file="/var/run/tor-${code}.pid"

    mkdir -p "$datadir" "$logdir"
    chmod 700 "$datadir"

    cat > "$conf" <<EOF
User root
DataDirectory ${datadir}
PidFile ${pid_file}
SocksPort 127.0.0.1:${socks_port}
ControlPort 127.0.0.1:${control_port}
CookieAuthentication 1
CookieAuthFile ${datadir}/control_auth_cookie
ExitNodes {${code}}
StrictNodes 1
GeoIPExcludeUnknown 1
EnforceDistinctSubnets 1
NumEntryGuards 8
NumDirectoryGuards 6
CircuitBuildTimeout 90
KeepalivePeriod 600
NewCircuitPeriod 120
MaxCircuitDirtiness 120
ExcludeExitNodes ${EXCLUDE_COUNTRIES}
ExcludeNodes ${EXCLUDE_COUNTRIES}
ExitPolicy reject *:*
Log notice file ${logdir}/notices.log
Log warn file ${logdir}/warnings.log
LogTimeGranularity 1
SafeSocks 1
WarnUnsafeSocks 1
DisableNetwork 0
EOF

    echo "▶️ [${code}] Launching Tor instance on SOCKS ${socks_port} / Control ${control_port}..."
    tor -f "$conf" > "${logdir}-stdout.log" 2>&1 &
    local tor_pid=$!
    echo "$tor_pid" > "$pid_file"
    sleep 2

    if ! kill -0 "$tor_pid" 2>/dev/null; then
        echo "❌ [${code}] Tor failed to start"
        return 1
    fi
    return 0
}

wait_for_bootstrap() {
    local i="$1" code="$2" socks_port="$3" control_port="$4"
    local logfile="/var/log/tor/${code}/notices.log"
    local elapsed=0 bootstrapped=false

    if ! check_tor_running "$code"; then
        echo "❌ [${code}] process not running, restarting..."
        start_tor_instance "$code" "$socks_port" "$control_port"
        sleep 2
    fi

    while [ $elapsed -lt "$BOOTSTRAP_TIMEOUT" ]; do
        if grep -q "Bootstrapped 100%" "$logfile" 2>/dev/null; then
            echo "✅ [${code}] bootstrapped."
            bootstrapped=true
            break
        fi
        sleep 3
        elapsed=$((elapsed + 3))

        if ! check_tor_running "$code"; then
            echo "⚠️ [${code}] died during bootstrap, restarting..."
            start_tor_instance "$code" "$socks_port" "$control_port"
            sleep 2
        fi
    done

    if [ "$bootstrapped" = false ]; then
        echo "❌ [${code}] did not bootstrap within ${BOOTSTRAP_TIMEOUT}s."
        write_status_json "$code" "unknown" "false" "bootstrap_timeout"
        update_setup_status
        return 1
    fi

    echo "⏳ [${code}] Bootstrapped — settling ${CIRCUIT_SETTLE_SLEEP}s before verification..."
    sleep "$CIRCUIT_SETTLE_SLEEP"

    if verify_tor_exit "$code" "$socks_port" "$code" "$control_port"; then
        local exit_ip
        exit_ip=$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:${socks_port}" https://api.ipify.org 2>/dev/null)
        write_status_json "$code" "${exit_ip:-unknown}" "true"
    else
        write_status_json "$code" "unknown" "false" "wrong_country"
    fi
    update_setup_status
}

declare -A SOCKS_PORT_OF CONTROL_PORT_OF

for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
    CODE=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
    SOCKS_PORT=$(jq -r ".tor.countries[$i].port" "$CONFIG_FILE")
    CONTROL_PORT=$(jq -r ".tor.countries[$i].control_port" "$CONFIG_FILE")
    SOCKS_PORT_OF[$CODE]="$SOCKS_PORT"
    CONTROL_PORT_OF[$CODE]="$CONTROL_PORT"

    start_tor_instance "$CODE" "$SOCKS_PORT" "$CONTROL_PORT"
    if [ $? -ne 0 ]; then
        write_status_json "$CODE" "unknown" "false" "failed_to_start"
    fi
done

echo "⏳ Waiting for Tor instances to bootstrap + verify exit country..."

if [ "$PARALLEL_BOOTSTRAP" = "true" ]; then
    PIDS=()
    for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
        CODE=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
        wait_for_bootstrap "$i" "$CODE" "${SOCKS_PORT_OF[$CODE]}" "${CONTROL_PORT_OF[$CODE]}" &
        PIDS+=($!)
        sleep 1
    done
    for pid in "${PIDS[@]}"; do
        wait "$pid"
    done
else
    for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
        CODE=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
        wait_for_bootstrap "$i" "$CODE" "${SOCKS_PORT_OF[$CODE]}" "${CONTROL_PORT_OF[$CODE]}"
    done
fi

write_status_summary() {
    local all_file="/var/www/tor-status/all.json"
    local tmp_file
    tmp_file=$(mktemp)
    {
        printf '['
        local first=1
        for f in /var/www/tor-status/*.json; do
            [ -f "$f" ] || continue
            case "$(basename "$f")" in all.json|setup-progress.json) continue ;; esac
            if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
            tr -d '\n' < "$f"
        done
        printf ']'
    } > "$tmp_file"
    mv "$tmp_file" "$all_file"
}
write_status_summary

VERIFIED_CODES=()
for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
    CODE=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
    if jq -e '.verified == true' "/var/www/tor-status/${CODE}.json" >/dev/null 2>&1; then
        VERIFIED_CODES+=("$CODE")
    fi
done
echo "✅ Verified countries: ${VERIFIED_CODES[*]:-none}"

rotate_and_verify() {
    local code="$1" socks_port="$2" control_port="$3"
    local status_file="/var/www/tor-status/${code}.json"
    local cookie_file="/var/lib/tor-instances/${code}/control_auth_cookie"

    [ "$(jq -r '.verified // false' "$status_file" 2>/dev/null)" = "true" ] || return 1
    [ -f "$cookie_file" ] || return 1
    check_tor_running "$code" || return 1

    force_new_circuit "$code" "$socks_port" "$control_port"
    sleep "$CIRCUIT_SETTLE_SLEEP"

    local exit_ip="" attempt=0
    while [ $attempt -lt 4 ]; do
        exit_ip=$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:${socks_port}" https://api.ipify.org 2>/dev/null)
        [[ "$exit_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        attempt=$((attempt + 1))
        sleep 3
    done
    [ -n "$exit_ip" ] || return 1

    local actual_country
    actual_country=$(get_country_from_ip "$exit_ip")

    if [ "$actual_country" = "$code" ]; then
        write_status_json "$code" "$exit_ip" "true"
        return 0
    fi

    force_new_circuit "$code" "$socks_port" "$control_port"
    sleep "$CIRCUIT_SETTLE_SLEEP"
    local retry_ip
    retry_ip=$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:${socks_port}" https://api.ipify.org 2>/dev/null)
    if [[ "$retry_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        actual_country=$(get_country_from_ip "$retry_ip")
        if [ "$actual_country" = "$code" ]; then
            write_status_json "$code" "$retry_ip" "true"
            return 0
        fi
    fi

    write_status_json "$code" "${retry_ip:-$exit_ip}" "false" "wrong_country_after_rotation"
    return 1
}

echo "▶️ Starting automatic IP rotator (every ${ROTATE_SECONDS}s)..."

(
    while true; do
        sleep "$ROTATE_SECONDS"
        for code in "${VERIFIED_CODES[@]}"; do
            rotate_and_verify "$code" "${SOCKS_PORT_OF[$code]}" "${CONTROL_PORT_OF[$code]}" &
            sleep 2
        done
        wait
        write_status_summary
        update_setup_status
    done
) > /var/log/tor/rotate.log 2>&1 &

echo "🔧 Building nginx.conf for port: ${NGINX_PORT}"

TOR_LOCATIONS=""
for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
    CODE=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
    PATH_WS=$(jq -r ".tor.countries[$i].path" "$CONFIG_FILE")
    INBOUND_PORT=$(jq -r ".tor.countries[$i].inbound_port" "$CONFIG_FILE")

    is_verified="false"
    for v in "${VERIFIED_CODES[@]}"; do
        [ "$v" = "$CODE" ] && is_verified="true" && break
    done
    [ "$is_verified" = "true" ] || continue

    TOR_LOCATIONS="${TOR_LOCATIONS}
          location ${PATH_WS} {
              proxy_pass http://127.0.0.1:${INBOUND_PORT};
              proxy_http_version 1.1;
              proxy_set_header Upgrade \$http_upgrade;
              proxy_set_header Connection \$connection_upgrade;
              proxy_set_header Host \$host;
              proxy_set_header X-Real-IP \$remote_addr;
              proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto \$scheme;
              proxy_buffering off;
              proxy_request_buffering off;
              proxy_read_timeout 3600s;
              proxy_send_timeout 3600s;
          }
"
done

envsubst '${NGINX_PORT}' < /etc/nginx/nginx.conf.template > /tmp/nginx.conf.stage1
awk -v repl="$TOR_LOCATIONS" '{gsub(/__TOR_LOCATIONS__/, repl); print}' /tmp/nginx.conf.stage1 > /etc/nginx/nginx.conf
rm -f /tmp/nginx.conf.stage1

echo "▶️ Starting x-ui in background..."
./x-ui &
sleep 5

if [ -x /panel-bootstrap.sh ]; then
    echo "▶️ Launching panel-bootstrap.sh (background)..."
    /panel-bootstrap.sh 2>&1 | tee /var/log/panel-bootstrap.log &
fi

echo "▶️ Validating nginx config..."
if ! nginx -t; then
    echo "❌ nginx config test FAILED."
    cat /etc/nginx/nginx.conf
    exit 1
fi

echo "▶️ Starting nginx in foreground on port ${NGINX_PORT}..."
echo "============================================================"
echo "🌐 DEFAULT: Direct (Non-Tor) — served through nginx on port ${NGINX_PORT}"
echo "🔒 Verified countries: ${VERIFIED_CODES[*]:-none}"
echo "📡 Direct path: ${DIRECT_PATH}"
echo "📊 Panel: /managepanel"
echo "============================================================"

VERIFIED_COUNT=${#VERIFIED_CODES[@]}
echo "✅ ${VERIFIED_COUNT}/${COUNTRY_COUNT} country exits verified"

exec nginx -g "daemon off;"
