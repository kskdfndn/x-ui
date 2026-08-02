#!/bin/bash
set -u

CONFIG_FILE="/etc/x-ui/config.json"
LOG() { echo "[panel-bootstrap] $*"; }

PANEL_BASE_PATH=$(jq -r '.xui.web_base_path' "$CONFIG_FILE")
PANEL_INTERNAL="http://127.0.0.1:$(jq -r '.xui.internal_port' "$CONFIG_FILE")${PANEL_BASE_PATH}"
PANEL_USER="${XUI_USERNAME:-$(jq -r '.xui.default_username' "$CONFIG_FILE")}"
PANEL_PASS="${XUI_PASSWORD:-$(jq -r '.xui.default_password' "$CONFIG_FILE")}"
API_TOKEN="${XUI_API_TOKEN:-}"

DIRECT_ENABLED=$(jq -r '.direct.enabled // true' "$CONFIG_FILE")
DIRECT_PORT=$(jq -r '.direct.port // 8080' "$CONFIG_FILE")
DIRECT_PATH=$(jq -r '.direct.path // "/direct"' "$CONFIG_FILE")
DIRECT_TAG=$(jq -r '.direct.tag // "direct-inbound"' "$CONFIG_FILE")

COOKIE_JAR="/tmp/xui-cookies.txt"
CSRF_TOKEN=""

XUI_BIN="/usr/local/x-ui/x-ui"

detect_domain() {
    if [ -n "${PUBLIC_DOMAIN:-}" ]; then
        echo "$PUBLIC_DOMAIN"
    elif [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
        echo "$RAILWAY_PUBLIC_DOMAIN"
    elif [ -n "${RAILWAY_STATIC_URL:-}" ]; then
        echo "$RAILWAY_STATIC_URL" | sed -E 's~^https?://~~'
    else
        NGINX_PUBLIC_PORT=$(jq -r '.server.public_port // 3000' "$CONFIG_FILE")
        echo "localhost:${NGINX_PUBLIC_PORT}"
    fi
}

DOMAIN="$(detect_domain)"
LOG "Detected public domain: $DOMAIN"

wait_for_panel() {
    for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w "%{http_code}" "${PANEL_INTERNAL}/login")
        if [ "$code" != "000" ]; then
            LOG "Panel is responding (http $code)."
            return 0
        fi
        sleep 2
    done
    LOG "❌ Panel never responded. Aborting."
    return 1
}

login() {
    if [ -n "$API_TOKEN" ]; then
        LOG "✅ Using XUI_API_TOKEN (Bearer auth)."
        return 0
    fi

    csrf_resp=$(curl -s -c "$COOKIE_JAR" "${PANEL_INTERNAL}/csrf-token")
    CSRF_TOKEN=$(echo "$csrf_resp" | jq -r '.obj // .token // empty' 2>/dev/null)

    json_data=$(jq -n --arg u "$PANEL_USER" --arg p "$PANEL_PASS" '{username:$u,password:$p}')
    if [ -n "$CSRF_TOKEN" ]; then
        resp=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -H "Content-Type: application/json" -H "X-CSRF-Token: ${CSRF_TOKEN}" \
            -X POST "${PANEL_INTERNAL}/login" -d "$json_data")
    else
        resp=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -H "Content-Type: application/json" \
            -X POST "${PANEL_INTERNAL}/login" -d "$json_data")
    fi

    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" != "true" ]; then
        LOG "❌ Login failed. Response: '${resp}'"
        return 1
    fi
    LOG "✅ Logged into panel API."
    return 0
}

api_post() {
    local path="$1" data="$2"
    if [ -n "$API_TOKEN" ]; then
        curl -s -H "Content-Type: application/json" -H "Authorization: Bearer ${API_TOKEN}" \
            -X POST "${PANEL_INTERNAL}${path}" -d "$data"
    elif [ -n "$CSRF_TOKEN" ]; then
        curl -s -b "$COOKIE_JAR" -H "Content-Type: application/json" \
            -H "X-CSRF-Token: ${CSRF_TOKEN}" -X POST "${PANEL_INTERNAL}${path}" -d "$data"
    else
        curl -s -b "$COOKIE_JAR" -H "Content-Type: application/json" \
            -X POST "${PANEL_INTERNAL}${path}" -d "$data"
    fi
}

api_get() {
    if [ -n "$API_TOKEN" ]; then
        curl -s -H "Authorization: Bearer ${API_TOKEN}" "${PANEL_INTERNAL}$1"
    else
        curl -s -b "$COOKIE_JAR" "${PANEL_INTERNAL}$1"
    fi
}

inbound_id_by_tag() {
    local tag="$1"
    api_get "/panel/api/inbounds/list/slim" | jq -r --arg t "$tag" '.obj[]? | select(.tag==$t) | .id' 2>/dev/null | head -n1
}

delete_inbound() {
    local tag="$1"
    local id
    id=$(inbound_id_by_tag "$tag")
    if [ -n "$id" ] && [ "$id" != "null" ]; then
        LOG "🗑️ Deleting inbound: ${tag} (ID: ${id})"
        resp=$(api_post "/panel/api/inbounds/del/$id" "{}")
        ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
        if [ "$ok" = "true" ]; then
            LOG "✅ Inbound ${tag} deleted."
            return 0
        else
            LOG "❌ Failed to delete inbound ${tag}: $resp"
            return 1
        fi
    fi
    return 0
}

create_inbound() {
    local tag="$1" label="$2" port="$3" path="$4" protocol="$5"

    local settings streamSettings sniffing
    settings=$(jq -n '{clients: [], decryption: "none", fallbacks: []}')
    streamSettings=$(jq -n --arg path "$path" '{network: "ws", security: "none", wsSettings: {path: $path, headers: {}}}')
    sniffing='{"enabled":true,"destOverride":["http","tls"],"metadataOnly":false,"routeOnly":false}'

    local body
    body=$(jq -n \
        --arg remark "${label}" \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson settings "$settings" \
        --argjson streamSettings "$streamSettings" \
        --argjson sniffing "$sniffing" \
        --arg protocol "$protocol" '{
            up: 0, down: 0, total: 0, remark: $remark, enable: true, expiryTime: 0,
            listen: "0.0.0.0", port: $port, protocol: $protocol,
            settings: $settings, streamSettings: $streamSettings, sniffing: $sniffing, tag: $tag
        }')

    resp=$(api_post "/panel/api/inbounds/add" "$body")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        LOG "✅ Inbound created: ${label} (port ${port}, path ${path})"
        return 0
    else
        LOG "❌ Inbound for ${label} failed: $resp"
        return 1
    fi
}

LOG "Waiting for panel to be ready..."
wait_for_panel || exit 1

sleep 2
LOG "Logging in..."
login || exit 1

sleep 1

LOG "Creating direct inbound (non-Tor)..."
delete_inbound "$DIRECT_TAG"
create_inbound "$DIRECT_TAG" "Direct" "$DIRECT_PORT" "$DIRECT_PATH" "vless"

COUNTRY_COUNT=$(jq '.tor.countries | length' "$CONFIG_FILE")

for i in $(seq 0 $((COUNTRY_COUNT - 1))); do
    CODE=$(jq -r ".tor.countries[$i].code" "$CONFIG_FILE")
    LABEL=$(jq -r ".tor.countries[$i].label" "$CONFIG_FILE")
    INBOUND_PORT=$(jq -r ".tor.countries[$i].inbound_port" "$CONFIG_FILE")
    PATH_WS=$(jq -r ".tor.countries[$i].path" "$CONFIG_FILE")
    TAG="tor-${CODE}"

    STATUS_FILE="/var/www/tor-status/${CODE}.json"
    if [ ! -f "$STATUS_FILE" ]; then
        LOG "⏭️ Skipping ${CODE} — no status file yet"
        continue
    fi

    VERIFIED=$(jq -r '.verified // false' "$STATUS_FILE")
    if [ "$VERIFIED" != "true" ]; then
        LOG "⏭️ Skipping ${CODE} — not verified"
        continue
    fi

    LOG "Creating inbound for ${LABEL} (${CODE})..."
    delete_inbound "$TAG"
    create_inbound "$TAG" "${LABEL} (Tor)" "$INBOUND_PORT" "$PATH_WS" "vless"
done

LOG "✅ All inbounds created. Panel bootstrap complete."
