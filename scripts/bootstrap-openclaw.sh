#!/usr/bin/env bash
set -euo pipefail

# syntella bootstrap
# Target: Ubuntu 22.04/24.04 on DigitalOcean

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run as a normal sudo user (not root)."
  echo "Tip: su - openclaw"
  exit 1
fi

say() { echo -e "\n==> $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
DEFAULT_MODEL_CATALOG_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/config/default-model-catalog.json"

# Auto-source local .env file if present (for curl|bash runs where exports don't carry over)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
DISCORD_TARGET="${DISCORD_TARGET:-}"
# Accept common aliases to reduce bootstrap env mistakes.
DISCORD_HUMAN_ID="${DISCORD_HUMAN_ID:-${DISCORD_USER_ID:-${DISCORD_HUMAN:-}}}"
MOONSHOT_API_KEY="${MOONSHOT_API_KEY:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
DISCORD_GUILD_ID=""
DISCORD_CHANNEL_ID=""
FRONTEND_ENABLED="${FRONTEND_ENABLED:-0}"
FRONTEND_URL=""
# Optional source IP/CIDR allowlist for the legacy nginx frontend, e.g. "203.0.113.10" or "203.0.113.0/24".
# Leave blank to expose the frontend publicly.
FRONTEND_ALLOWED_IP="${FRONTEND_ALLOWED_IP:-}"
SYNTELLA_PORTAL_API_TOKEN="${SYNTELLA_PORTAL_API_TOKEN:-}"
SYNTELLA_ENABLE_DROPLET_FRONTEND="${SYNTELLA_ENABLE_DROPLET_FRONTEND:-0}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-}"
TS_ACCEPT_DNS="${TS_ACCEPT_DNS:-true}"
TS_LOGIN_SERVER="${TS_LOGIN_SERVER:-}"
PUBLIC_IP_CACHE="${PUBLIC_IP_CACHE:-}"
# Exec approval posture for runtime command execution:
# - full: no interactive exec approvals (default for this droplet kit)
# - strict: leave host approval posture unchanged
EXEC_APPROVAL_MODE="${EXEC_APPROVAL_MODE:-full}"
SYNTELLA_EXEC_TIMEOUT_SECONDS="${SYNTELLA_EXEC_TIMEOUT_SECONDS:-60}"
SYNTELLA_EXEC_MAX_OUTPUT_BYTES="${SYNTELLA_EXEC_MAX_OUTPUT_BYTES:-16384}"
OPERATOR_BRIDGE_PORT="${OPERATOR_BRIDGE_PORT:-8787}"
OPERATOR_BRIDGE_TOKEN=""
SYNTELLA_API_PORT="${SYNTELLA_API_PORT:-8788}"
OPENCLAW_HANDSHAKE_WORKAROUND_ENABLED="${OPENCLAW_HANDSHAKE_WORKAROUND_ENABLED:-1}"
OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS="${OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS:-30000}"
SYNTELLA_API_BIND_HOST="${SYNTELLA_API_BIND_HOST:-0.0.0.0}"
SYNTELLA_PRESERVE_CUSTOMER_STATE="${SYNTELLA_PRESERVE_CUSTOMER_STATE:-1}"
TAILSCALE_HOSTNAME_EFFECTIVE=""
TAILSCALE_DNS_NAME_EFFECTIVE=""
TAILSCALE_IPV4_EFFECTIVE=""

# OPENCLAW_HOME should point to the user home base (e.g. /home/openclaw), not ~/.openclaw.
# If inherited incorrectly from the environment, normalize it before any `openclaw config` calls.
if [[ -n "${OPENCLAW_HOME:-}" && "$OPENCLAW_HOME" == */.openclaw ]]; then
  export OPENCLAW_HOME="${OPENCLAW_HOME%/.openclaw}"
fi

append_path_if_missing() {
  local rc_file="$1"
  local path_line="$2"
  [[ -f "$rc_file" ]] || touch "$rc_file"
  grep -Fq "$path_line" "$rc_file" || echo "$path_line" >> "$rc_file"
}

ensure_openclaw_on_path() {
  local local_bin="$HOME/.local/bin"
  local npm_global_bin="$HOME/.npm-global/bin"
  local path_line='export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"'

  # Persist PATH fix for future non-interactive/login shells even if openclaw is currently found.
  append_path_if_missing "$HOME/.bashrc" "$path_line"
  append_path_if_missing "$HOME/.profile" "$path_line"
  append_path_if_missing "$HOME/.zshrc" "$path_line"

  if [[ -d "$local_bin" ]] && [[ ":$PATH:" != *":$local_bin:"* ]]; then
    export PATH="$local_bin:$PATH"
    hash -r || true
  fi

  if [[ -d "$npm_global_bin" ]] && [[ ":$PATH:" != *":$npm_global_bin:"* ]]; then
    export PATH="$npm_global_bin:$PATH"
    hash -r || true
  fi

  command -v openclaw >/dev/null 2>&1
}

resolve_openclaw_real_bin() {
  local candidate=""

  for candidate in "$HOME/.npm-global/bin/openclaw" "/usr/local/bin/openclaw"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v npm >/dev/null 2>&1; then
    local npm_prefix
    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
    candidate="${npm_prefix%/}/bin/openclaw"
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  candidate="$(command -v openclaw 2>/dev/null || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

resolve_openclaw_cli_bin() {
  local candidate=""

  for candidate in "$HOME/.local/bin/openclaw"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  resolve_openclaw_real_bin
}

render_template() {
  local src="$1"
  local dst="$2"
  sed \
    -e "s|__DISCORD_GUILD_ID__|${DISCORD_GUILD_ID}|g" \
    -e "s|__DISCORD_CHANNEL_ID__|${DISCORD_CHANNEL_ID}|g" \
    -e "s|__DISCORD_HUMAN_ID__|${DISCORD_HUMAN_ID}|g" \
    -e "s|__OPERATOR_BRIDGE_PORT__|${OPERATOR_BRIDGE_PORT}|g" \
    -e "s|__OPERATOR_BRIDGE_TOKEN__|${OPERATOR_BRIDGE_TOKEN}|g" \
    "$src" > "$dst"
}

should_preserve_state() {
  [[ "$SYNTELLA_PRESERVE_CUSTOMER_STATE" == "1" ]]
}

copy_managed_file() {
  local src="$1"
  local dst="$2"
  local mode="${3:-managed}"
  if [[ "$mode" == "preserve" ]] && should_preserve_state && [[ -e "$dst" ]]; then
    return 0
  fi
  cp "$src" "$dst"
}

render_managed_template() {
  local src="$1"
  local dst="$2"
  local mode="${3:-managed}"
  if [[ "$mode" == "preserve" ]] && should_preserve_state && [[ -e "$dst" ]]; then
    return 0
  fi
  render_template "$src" "$dst"
}

assert_templates_exist() {
  local required=(  
    "$TEMPLATE_DIR/workspace/AGENTS.SYNTELLA.md.tmpl"
    "$TEMPLATE_DIR/workspace/AGENTS.SPAWNED.md.tmpl"
    "$TEMPLATE_DIR/workspace/SOUL.md"
    "$TEMPLATE_DIR/workspace/USER.md"
    "$TEMPLATE_DIR/workspace/MEMORY.md"
    "$TEMPLATE_DIR/workspace/TEAM.md"
    "$TEMPLATE_DIR/frontend/index.html"
    "$TEMPLATE_DIR/frontend/admin.html"
    "$TEMPLATE_DIR/frontend/styles.css"
    "$TEMPLATE_DIR/frontend/admin.css"
    "$TEMPLATE_DIR/frontend/app.js"
    "$TEMPLATE_DIR/frontend/admin.js"
    "$TEMPLATE_DIR/frontend/admin-core.js"
    "$TEMPLATE_DIR/frontend/admin-work.js"
    "$TEMPLATE_DIR/frontend/admin-models.js"
    "$TEMPLATE_DIR/frontend/admin-integrations.js"
    "$TEMPLATE_DIR/frontend/admin-budget.js"
    "$TEMPLATE_DIR/frontend/admin-team.js"
    "$TEMPLATE_DIR/frontend/README.md"
    "$TEMPLATE_DIR/workspace/extensions/tasks/openclaw.plugin.json"
    "$TEMPLATE_DIR/workspace/extensions/tasks/index.ts"
    "$TEMPLATE_DIR/workspace/extensions/tasks/tasks_db.py"
    "$TEMPLATE_DIR/workspace/extensions/reports/openclaw.plugin.json"
    "$TEMPLATE_DIR/workspace/extensions/reports/index.ts"
    "$TEMPLATE_DIR/workspace/extensions/reports/reports_db.py"
    "$TEMPLATE_DIR/workspace/extensions/ghost/openclaw.plugin.json"
    "$TEMPLATE_DIR/workspace/extensions/ghost/index.ts"
    "$TEMPLATE_DIR/workspace/extensions/search-console/openclaw.plugin.json"
    "$TEMPLATE_DIR/workspace/extensions/search-console/index.ts"
    "$TEMPLATE_DIR/workspace/extensions/search-console/search_console.py"
    "$TEMPLATE_DIR/workspace/extensions/analytics/openclaw.plugin.json"
    "$TEMPLATE_DIR/workspace/extensions/analytics/index.ts"
    "$TEMPLATE_DIR/workspace/extensions/analytics/status.py"
    "$TEMPLATE_DIR/operator-bridge/syntella-spawn-agent.sh.tmpl"
    "$TEMPLATE_DIR/operator-bridge/server.py"
  )
  local f
  for f in "${required[@]}"; do
    [[ -f "$f" ]] || { echo "Missing template file: $f"; exit 1; }
  done
  if [[ ! -f "$TEMPLATE_DIR/workspace/extensions/ghost/ghost.py" && ! -f "$TEMPLATE_DIR/workspace/extensions/ghost/status.py" ]]; then
    echo "Missing Ghost helper template file: expected ghost.py or status.py in $TEMPLATE_DIR/workspace/extensions/ghost"
    exit 1
  fi
}

install_tailscale() {
  say "Ensuring Tailscale is installed"
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sudo sh
  fi

  sudo systemctl enable --now tailscaled >/dev/null 2>&1 || true
}

tailscale_status_json() {
  sudo tailscale status --json 2>/dev/null || true
}

tailscale_is_connected() {
  local status_json
  status_json="$(tailscale_status_json)"
  [[ -n "$status_json" ]] || return 1

  STATUS_JSON="$status_json" python3 - <<'PY'
import json
import os

try:
    payload = json.loads(os.environ["STATUS_JSON"])
except Exception:
    raise SystemExit(1)

state = str(payload.get("BackendState") or "")
self_node = payload.get("Self") or {}
online = self_node.get("Online")
raise SystemExit(0 if state == "Running" and online is not False else 1)
PY
}

persist_tailscale_metadata() {
  local status_json
  status_json="$(tailscale_status_json)"
  if [[ -z "$status_json" ]]; then
    echo "Could not read Tailscale status output."
    exit 1
  fi

  local env_dir="/etc/openclaw"
  local env_file="$env_dir/tailscale.env"
  local parsed
  parsed="$(
    STATUS_JSON="$status_json" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["STATUS_JSON"])
self_node = payload.get("Self") or {}
dns_name = str(self_node.get("DNSName") or "").rstrip(".")
host_name = str(self_node.get("HostName") or "")
ips = self_node.get("TailscaleIPs") or []
ipv4 = next((item for item in ips if "." in str(item)), "")
print(f"TAILSCALE_HOSTNAME_EFFECTIVE={host_name}")
print(f"TAILSCALE_DNS_NAME_EFFECTIVE={dns_name}")
print(f"TAILSCALE_IPV4_EFFECTIVE={ipv4}")
PY
  )"

  TAILSCALE_HOSTNAME_EFFECTIVE="$(printf '%s\n' "$parsed" | sed -n 's/^TAILSCALE_HOSTNAME_EFFECTIVE=//p')"
  TAILSCALE_DNS_NAME_EFFECTIVE="$(printf '%s\n' "$parsed" | sed -n 's/^TAILSCALE_DNS_NAME_EFFECTIVE=//p')"
  TAILSCALE_IPV4_EFFECTIVE="$(printf '%s\n' "$parsed" | sed -n 's/^TAILSCALE_IPV4_EFFECTIVE=//p')"

  sudo install -d -m 750 -o root -g openclaw "$env_dir"
  sudo tee "$env_file" >/dev/null <<EOF
TAILSCALE_HOSTNAME_EFFECTIVE="${TAILSCALE_HOSTNAME_EFFECTIVE}"
TAILSCALE_DNS_NAME_EFFECTIVE="${TAILSCALE_DNS_NAME_EFFECTIVE}"
TAILSCALE_IPV4_EFFECTIVE="${TAILSCALE_IPV4_EFFECTIVE}"
EOF
  sudo chown root:openclaw "$env_file"
  sudo chmod 640 "$env_file"
}

join_tailscale_tailnet() {
  install_tailscale

  if tailscale_is_connected; then
    say "Tailscale already connected; recording current tailnet metadata"
    persist_tailscale_metadata
    return 0
  fi

  if [[ -z "$TS_AUTHKEY" || -z "$TS_HOSTNAME" ]]; then
    echo "TS_AUTHKEY and TS_HOSTNAME are required to join the tailnet."
    exit 1
  fi

  say "Joining Tailscale tailnet"
  local tailscale_args=(
    up
    "--authkey=${TS_AUTHKEY}"
    "--hostname=${TS_HOSTNAME}"
    "--accept-dns=${TS_ACCEPT_DNS}"
    "--reset"
  )
  if [[ -n "$TS_LOGIN_SERVER" ]]; then
    tailscale_args+=("--login-server=${TS_LOGIN_SERVER}")
  fi

  sudo tailscale "${tailscale_args[@]}"
  persist_tailscale_metadata
}

install_syntella_api_firewall() {
  local firewall_script="/usr/local/bin/syntella-api-firewall"
  local service_file="/etc/systemd/system/syntella-api-firewall.service"

  sudo apt-get install -y iptables >/dev/null 2>&1 || true

  sudo tee "$firewall_script" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/openclaw/syntella-api.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
fi

PORT="${SYNTELLA_DEV_PORT:-8788}"
CHAIN="SYNTELLA_API_GUARD"

iptables -N "$CHAIN" 2>/dev/null || true
iptables -F "$CHAIN"
iptables -A "$CHAIN" -i lo -j RETURN
iptables -A "$CHAIN" -i tailscale0 -j RETURN
iptables -A "$CHAIN" -j DROP

iptables -C INPUT -p tcp --dport "$PORT" -j "$CHAIN" 2>/dev/null \
  || iptables -I INPUT -p tcp --dport "$PORT" -j "$CHAIN"
EOF

  sudo chmod 755 "$firewall_script"

  sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=Syntella API firewall guard
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
ExecStart=${firewall_script}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  sudo chmod 644 "$service_file"
  sudo systemctl daemon-reload
  sudo systemctl enable --now syntella-api-firewall >/dev/null 2>&1 || true
}

install_syntella_api() {
  local api_dir="$HOME/.openclaw/syntella-api"
  local env_dir="/etc/openclaw"
  local env_file="$env_dir/syntella-api.env"
  local api_py="$api_dir/local-dev-server.py"
  local service_file="/etc/systemd/system/syntella-api.service"

  mkdir -p "$api_dir"
  sudo install -d -m 750 -o root -g openclaw "$env_dir"

  cp "$SCRIPT_DIR/local-dev-server.py" "$api_py"
  chmod 755 "$api_py"

  sudo tee "$env_file" >/dev/null <<EOF
SYNTELLA_DEV_PORT=${SYNTELLA_API_PORT}
SYNTELLA_API_BIND_HOST=${SYNTELLA_API_BIND_HOST}
SYNTELLA_WORKSPACE=${HOME}/.openclaw/workspace
OPENCLAW_STATE_DIR=${HOME}/.openclaw
SYNTELLA_OPERATOR_BRIDGE_URL=http://127.0.0.1:${OPERATOR_BRIDGE_PORT}
SYNTELLA_PORTAL_API_TOKEN=${SYNTELLA_PORTAL_API_TOKEN}
SYNTELLA_ENABLE_DROPLET_FRONTEND=${SYNTELLA_ENABLE_DROPLET_FRONTEND}
EOF
  sudo chown root:openclaw "$env_file"
  sudo chmod 640 "$env_file"

  # Stop any existing systemd service
  sudo systemctl stop syntella-api 2>/dev/null || true

  # Create systemd service file
  sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=Syntella API Server
After=network.target

[Service]
Type=simple
User=openclaw
WorkingDirectory=$api_dir
EnvironmentFile=$env_file
EnvironmentFile=-/etc/openclaw/openclaw.env
ExecStart=/usr/bin/python3 $api_py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=syntella-api

[Install]
WantedBy=multi-user.target
EOF

  sudo chmod 644 "$service_file"

  # Reload systemd and enable/start service
  sudo systemctl daemon-reload
  sudo systemctl enable --now syntella-api

  # Wait for service to be healthy (up to 15 seconds)
  local waited=0
  while (( waited < 15 )); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${SYNTELLA_API_PORT}/health" >/dev/null 2>&1; then
      echo "Syntella API started (systemd service, port=${SYNTELLA_API_PORT})"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "Warning: Syntella API did not respond to health check within 15s."
  echo "Check status: sudo systemctl status syntella-api"
  echo "Check logs: sudo journalctl -u syntella-api -n 50"
  echo "Health check: curl http://127.0.0.1:${SYNTELLA_API_PORT}/health"
}

ensure_node_and_npm() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    return 0
  fi

  say "Installing Node.js 22 + npm"
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y nodejs
}

install_openclaw_cli() {
  if command -v openclaw >/dev/null 2>&1; then
    return 0
  fi

  say "Installing OpenClaw CLI via npm (without optional native deps)"
  mkdir -p "$HOME/.npm-global"
  npm config set prefix "$HOME/.npm-global"

  # Skip optional deps (e.g. @discordjs/opus) to avoid native build failures on fresh droplets.
  npm install -g --omit=optional openclaw@latest

  ensure_openclaw_on_path || true
}

say "Installing base packages"
sudo apt-get update -y
sudo apt-get install -y curl git ca-certificates gnupg lsb-release iproute2 procps lsof python3 make g++ build-essential pkg-config
ensure_node_and_npm
install_openclaw_cli

if ! ensure_openclaw_on_path; then
  echo "OpenClaw appears installed but is not on PATH; attempting direct binary resolution..."
fi

OPENCLAW_REAL_BIN="$(resolve_openclaw_real_bin || true)"
if [[ -z "$OPENCLAW_REAL_BIN" ]]; then
  echo "OpenClaw installed but executable could not be resolved."
  echo "Checked: command -v openclaw, ~/.npm-global/bin/openclaw, /usr/local/bin/openclaw"
  echo "Try: export PATH=\"$HOME/.npm-global/bin:$PATH\""
  echo "Then re-run this script."
  exit 1
fi
OPENCLAW_BIN="$OPENCLAW_REAL_BIN"
oc() { "$OPENCLAW_BIN" "$@"; }

say "Pre-creating OpenClaw state dirs to avoid first-run prompts"
mkdir -p "$HOME/.openclaw"
chmod 700 "$HOME/.openclaw" || true
mkdir -p "$HOME/.openclaw/agents/main/sessions"
mkdir -p "$HOME/.openclaw/devices"
mkdir -p "$HOME/.openclaw/credentials"
mkdir -p "$HOME/.openclaw/workspace"
chmod 700 "$HOME/.openclaw/devices" "$HOME/.openclaw/credentials" || true

harden_openclaw_state_permissions() {
  chmod 700 "$HOME/.openclaw" "$HOME/.openclaw/devices" "$HOME/.openclaw/credentials" 2>/dev/null || true
  find "$HOME/.openclaw/devices" -maxdepth 1 -type f -exec chmod 600 {} \; 2>/dev/null || true
  find "$HOME/.openclaw/credentials" -maxdepth 1 -type f -exec chmod 600 {} \; 2>/dev/null || true
  find "$HOME/.openclaw/agents" -path '*/agent/auth-profiles.json' -exec chmod 600 {} \; 2>/dev/null || true
  find "$HOME/.openclaw/agents" -path '*/agent/auth.json' -exec chmod 600 {} \; 2>/dev/null || true
}

ensure_gateway_token() {
  local config_file="$HOME/.openclaw/openclaw.json"
  local token=""

  token="$(python3 - "$config_file" <<'PY'
import json, os, sys
config_path = sys.argv[1]
if not os.path.exists(config_path):
    raise SystemExit(0)
try:
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    raise SystemExit(0)
gateway = cfg.get("gateway")
auth = gateway.get("auth") if isinstance(gateway, dict) else None
token = auth.get("token") if isinstance(auth, dict) else ""
if token:
    print(token)
PY
)"
  if [[ -n "$token" ]]; then
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    token="$(openssl rand -hex 24)"
  elif command -v python3 >/dev/null 2>&1; then
    token="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
)"
  else
    token="$(date +%s)-$RANDOM-$RANDOM"
  fi

  python3 - "$config_file" "$token" <<'PY'
import json, os, sys
config_path, token = sys.argv[1:3]
cfg = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
gateway = cfg.setdefault("gateway", {})
auth = gateway.get("auth")
if not isinstance(auth, dict):
    auth = {}
auth["token"] = token
gateway["auth"] = auth
with open(config_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

read_gateway_token() {
  local config_file="$HOME/.openclaw/openclaw.json"

  python3 - "$config_file" <<'PY'
import json
import os
import sys

config_path = sys.argv[1]
cfg = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}

gateway = cfg.get("gateway")
auth = gateway.get("auth") if isinstance(gateway, dict) else None
token = auth.get("token") if isinstance(auth, dict) else ""
if token == "${OPENCLAW_GATEWAY_TOKEN}":
    token = os.environ.get("OPENCLAW_GATEWAY_TOKEN", "")
if token:
    print(token)
PY
}

install_openclaw_cli_wrapper() {
  local real_bin="${OPENCLAW_REAL_BIN:-$OPENCLAW_BIN}"
  local wrapper_dir="$HOME/.local/bin"
  local wrapper_path="$wrapper_dir/openclaw"

  mkdir -p "$wrapper_dir"

  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

REAL_BIN="${real_bin}"
if [[ ! -x "\$REAL_BIN" ]]; then
  echo "OpenClaw binary not found at \$REAL_BIN" >&2
  exit 1
fi

if [[ -f /etc/openclaw/openclaw.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /etc/openclaw/openclaw.env
  set +a
fi

if [[ -f "\$HOME/.openclaw/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "\$HOME/.openclaw/.env"
  set +a
fi

export OPENCLAW_HOME="\${OPENCLAW_HOME:-\$HOME}"

if [[ -z "\${OPENCLAW_GATEWAY_TOKEN:-}" && -f "\$OPENCLAW_HOME/.openclaw/openclaw.json" ]]; then
  OPENCLAW_GATEWAY_TOKEN="\$(python3 - "\$OPENCLAW_HOME/.openclaw/openclaw.json" <<'PY'
import json
import os
import sys

config_path = sys.argv[1]
cfg = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}

gateway = cfg.get("gateway")
auth = gateway.get("auth") if isinstance(gateway, dict) else None
token = auth.get("token") if isinstance(auth, dict) else ""
if token == "\${OPENCLAW_GATEWAY_TOKEN}":
    token = os.environ.get("OPENCLAW_GATEWAY_TOKEN", "")
if token:
    print(token)
PY
)"
  export OPENCLAW_GATEWAY_TOKEN
fi

exec "\$REAL_BIN" "\$@"
EOF

  chmod 755 "$wrapper_path"

  if [[ ":$PATH:" != *":$wrapper_dir:"* ]]; then
    export PATH="$wrapper_dir:$PATH"
    hash -r || true
  fi
}

install_openclaw_cli_wrapper
OPENCLAW_BIN="$(resolve_openclaw_cli_bin || true)"
if [[ -z "$OPENCLAW_BIN" ]]; then
  echo "OpenClaw wrapper installation completed but the CLI path could not be resolved."
  exit 1
fi

parse_discord_target() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr -d '[:space:]')"
  cleaned="${cleaned#guild:}"
  cleaned="${cleaned#guild=}"
  cleaned="${cleaned#g:}"

  local guild=""
  local channel=""

  if [[ "$cleaned" == *"/"* ]]; then
    guild="${cleaned%%/*}"
    channel="${cleaned##*/}"
    channel="${channel#channel:}"
    channel="${channel#channel=}"
    channel="${channel#c:}"
  elif [[ "$cleaned" == *":"* ]]; then
    guild="${cleaned%%:*}"
    channel="${cleaned##*:}"
  fi

  if [[ -z "$guild" || -z "$channel" || ! "$guild" =~ ^[0-9]+$ || ! "$channel" =~ ^[0-9]+$ ]]; then
    echo "Invalid DISCORD_TARGET: '$raw'"
    echo "Expected one of:"
    echo "  DISCORD_TARGET=\"<guildId>/<channelId>\""
    echo "  DISCORD_TARGET=\"<guildId>:<channelId>\""
    echo "  DISCORD_TARGET=\"guild:<guildId>/channel:<channelId>\""
    exit 1
  fi

  DISCORD_GUILD_ID="$guild"
  DISCORD_CHANNEL_ID="$channel"
}

require_discord_inputs() {
  if [[ -z "$DISCORD_BOT_TOKEN" ]]; then
    echo "Missing DISCORD_BOT_TOKEN."
    echo "Export DISCORD_BOT_TOKEN before running this script."
    exit 1
  fi

  if [[ -z "$DISCORD_TARGET" ]]; then
    echo "Missing DISCORD_TARGET."
    echo "Example: DISCORD_TARGET=\"123456789012345678/987654321098765432\""
    exit 1
  fi

  # Normalize Discord user id (accept raw id, <@id>, <@!id>, or aliases).
  DISCORD_HUMAN_ID="$(echo "${DISCORD_HUMAN_ID}" | tr -cd '0-9')"
  if [[ -z "$DISCORD_HUMAN_ID" || ! "$DISCORD_HUMAN_ID" =~ ^[0-9]+$ ]]; then
    echo "Missing or invalid DISCORD_HUMAN_ID."
    echo "Example: DISCORD_HUMAN_ID=\"123456789012345678\""
    echo "(Aliases accepted: DISCORD_USER_ID, DISCORD_HUMAN)"
    exit 1
  fi

  parse_discord_target "$DISCORD_TARGET"
}

require_portal_and_tailnet_inputs() {
  if [[ -z "$SYNTELLA_PORTAL_API_TOKEN" ]]; then
    echo "Missing SYNTELLA_PORTAL_API_TOKEN."
    echo "Export SYNTELLA_PORTAL_API_TOKEN before running this script."
    exit 1
  fi

  if ! tailscale_is_connected; then
    if [[ -z "$TS_AUTHKEY" ]]; then
      echo "Missing TS_AUTHKEY."
      echo "Export TS_AUTHKEY before running this script so the droplet can join the tailnet."
      exit 1
    fi

    if [[ -z "$TS_HOSTNAME" ]]; then
      echo "Missing TS_HOSTNAME."
      echo "Example: TS_HOSTNAME=\"syntella-example-client\""
      exit 1
    fi
  fi
}

configure_discord_channel() {
  local config_file="$HOME/.openclaw/openclaw.json"

  python3 - "$config_file" "$DISCORD_BOT_TOKEN" "$DISCORD_GUILD_ID" "$DISCORD_CHANNEL_ID" "$DISCORD_HUMAN_ID" <<'PY'
import json
import os
import sys

config_path, token, guild_id, channel_id, human_id = sys.argv[1:6]

cfg = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}

channels = cfg.setdefault("channels", {})
discord = channels.setdefault("discord", {})
discord["enabled"] = True
discord["allowFrom"] = [str(human_id)]
discord["dmPolicy"] = "allowlist"
dm_cfg = discord.get("dm")
if not isinstance(dm_cfg, dict):
    dm_cfg = {}
dm_cfg["enabled"] = True
dm_cfg["groupEnabled"] = False
discord["dm"] = dm_cfg

accounts = discord.get("accounts")
if not isinstance(accounts, dict):
    accounts = {}

default_account = accounts.get("default")
if not isinstance(default_account, dict):
    default_account = {}
default_account["name"] = "Syntella"
default_account["token"] = token
default_account["allowBots"] = True
default_account["groupPolicy"] = "allowlist"
default_account["guilds"] = {
    guild_id: {
        "requireMention": False,
        "channels": {
            channel_id: {"allow": True, "requireMention": False}
        },
    }
}
default_account["intents"] = {
    "presence": False,
    "guildMembers": False,
}
accounts["default"] = default_account
discord["accounts"] = accounts

# Remove legacy single-account keys once the default account is populated.
for legacy_key in ("token", "groupPolicy", "allowBots", "guilds", "intents"):
    discord.pop(legacy_key, None)

agents = cfg.setdefault("agents", {})
entries = agents.get("list")
if not isinstance(entries, list):
    entries = []
main_entry = None
for item in entries:
    if isinstance(item, dict) and item.get("id") == "main":
        main_entry = item
        break
if main_entry is None:
    main_entry = {"id": "main"}
    entries.insert(0, main_entry)
main_entry["name"] = "Syntella"
main_entry["workspace"] = os.path.expanduser("~/.openclaw/workspace/syntella")
main_entry["agentDir"] = os.path.expanduser("~/.openclaw/agents/main/agent")
identity = main_entry.get("identity")
if not isinstance(identity, dict):
    identity = {}
identity["name"] = "Syntella"
main_entry["identity"] = identity
group_chat = main_entry.get("groupChat")
if not isinstance(group_chat, dict):
    group_chat = {}
group_chat["mentionPatterns"] = ["syntella", "main", "chief autonomy officer", "cao"]
main_entry["groupChat"] = group_chat
tools_cfg = main_entry.get("tools")
if not isinstance(tools_cfg, dict):
    tools_cfg = {}
tools_cfg["profile"] = "full"
main_entry["tools"] = tools_cfg
agents["list"] = entries

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

seed_workspace_context_files() {
  local ws_root="$HOME/.openclaw/workspace"
  local ws_tmpl="$TEMPLATE_DIR/workspace"
  local syntella_ws="$ws_root/syntella"
  local shared_ws="$ws_root/shared"
  local template_extensions_root="$ws_root/templates/extensions"
  mkdir -p "$syntella_ws" "$syntella_ws/memory" "$shared_ws"
  mkdir -p "$template_extensions_root"

  render_managed_template "$ws_tmpl/AGENTS.SYNTELLA.md.tmpl" "$syntella_ws/AGENTS.md" preserve
  render_managed_template "$ws_tmpl/AGENTS.SPAWNED.md.tmpl" "$ws_root/AGENTS.SPAWNED.md" managed
  render_managed_template "$ws_tmpl/HEARTBEAT.MAIN.md.tmpl" "$syntella_ws/HEARTBEAT.md" preserve
  copy_managed_file "$ws_tmpl/SOUL.md" "$syntella_ws/SOUL.md" preserve
  copy_managed_file "$ws_tmpl/USER.md" "$shared_ws/USER.md" preserve
  copy_managed_file "$ws_tmpl/MEMORY.md" "$syntella_ws/MEMORY.md" preserve
  copy_managed_file "$ws_tmpl/TEAM.md" "$shared_ws/TEAM.md" preserve
  copy_managed_file "$ws_tmpl/TASKS.md" "$shared_ws/TASKS.md" preserve
  rm -rf \
    "$syntella_ws/.openclaw/extensions/tasks" \
    "$syntella_ws/.openclaw/extensions/reports" \
    "$syntella_ws/.openclaw/extensions/syntella-tasks" \
    "$syntella_ws/.openclaw/extensions/syntella-reports" \
    "$template_extensions_root/tasks" \
    "$template_extensions_root/reports" \
    "$template_extensions_root/syntella-tasks" \
    "$template_extensions_root/syntella-reports" \
    "$template_extensions_root/ghost" \
    "$template_extensions_root/search-console" \
    "$template_extensions_root/analytics" \
    "$template_extensions_root/syntella-ghost" \
    "$template_extensions_root/syntella-search-console" \
    "$template_extensions_root/syntella-analytics" \
    "$template_extensions_root/seo"
  cp -R "$ws_tmpl/extensions/tasks" "$template_extensions_root/syntella-tasks"
  cp -R "$ws_tmpl/extensions/reports" "$template_extensions_root/syntella-reports"
  cp -R "$ws_tmpl/extensions/ghost" "$template_extensions_root/syntella-ghost"
  cp -R "$ws_tmpl/extensions/search-console" "$template_extensions_root/syntella-search-console"
  cp -R "$ws_tmpl/extensions/analytics" "$template_extensions_root/syntella-analytics"
  cp -R "$ws_tmpl/extensions/seo" "$template_extensions_root/seo"

  local today yesterday
  today="$(date +%F)"
  yesterday="$(date -d 'yesterday' +%F 2>/dev/null || date -v-1d +%F 2>/dev/null || true)"

  [[ -f "$syntella_ws/memory/${today}.md" ]] || echo "# ${today}" >"$syntella_ws/memory/${today}.md"
  if [[ -n "$yesterday" ]]; then
    [[ -f "$syntella_ws/memory/${yesterday}.md" ]] || echo "# ${yesterday}" >"$syntella_ws/memory/${yesterday}.md"
  fi
}
setup_openclaw_env_file() {
  local env_dir="/etc/openclaw"
  local env_file="${env_dir}/openclaw.env"
  local gateway_token

  gateway_token="$(read_gateway_token)"

  if ! getent group openclaw >/dev/null 2>&1; then
    sudo groupadd --system openclaw >/dev/null 2>&1 || true
  fi
  sudo install -d -m 750 -o root -g openclaw "$env_dir"
  sudo tee "$env_file" >/dev/null <<EOF
# Shared OpenClaw runtime environment
# Source this file before starting OpenClaw-related processes.
MOONSHOT_API_KEY="${MOONSHOT_API_KEY}"
OPENAI_API_KEY="${OPENAI_API_KEY}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
OPENCLAW_GATEWAY_TOKEN="${gateway_token}"
OPENCLAW_HOME="${HOME}"
VITEST="${OPENCLAW_HANDSHAKE_WORKAROUND_ENABLED}"
OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS="${OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS}"
SYNTELLA_PORTAL_API_TOKEN="${SYNTELLA_PORTAL_API_TOKEN}"
SYNTELLA_ENABLE_DROPLET_FRONTEND="${SYNTELLA_ENABLE_DROPLET_FRONTEND}"
EOF
  sudo chown root:openclaw "$env_file"
  sudo chmod 640 "$env_file"

  local source_line='[[ -f /etc/openclaw/openclaw.env ]] && set -a && source /etc/openclaw/openclaw.env && set +a'
  append_path_if_missing "$HOME/.bashrc" "$source_line"
  append_path_if_missing "$HOME/.profile" "$source_line"
  append_path_if_missing "$HOME/.zshrc" "$source_line"

  # Ensure current shell and any child processes for this bootstrap can read the same env.
  set -a
  # shellcheck disable=SC1091
  source "$env_file"
  set +a
}

setup_openclaw_global_dotenv() {
  local dotenv_file="$HOME/.openclaw/.env"
  local gateway_token
  gateway_token="$(read_gateway_token)"
  mkdir -p "$HOME/.openclaw"
  cat >"$dotenv_file" <<EOF
# OpenClaw daemon-level environment fallback.
# Gateway reads this even when it does not inherit shell env.
MOONSHOT_API_KEY="${MOONSHOT_API_KEY}"
OPENAI_API_KEY="${OPENAI_API_KEY}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
OPENCLAW_GATEWAY_TOKEN="${gateway_token}"
VITEST="${OPENCLAW_HANDSHAKE_WORKAROUND_ENABLED}"
OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS="${OPENCLAW_TEST_HANDSHAKE_TIMEOUT_MS}"
EOF
  chmod 600 "$dotenv_file"
}

install_syntella_exec_wrapper() {
  local wrapper_path="/usr/local/bin/syntella-exec"
  local log_file="$HOME/.openclaw/logs/syntella-exec.log"

  sudo install -d -m 755 -o root -g root /usr/local/bin
  mkdir -p "$HOME/.openclaw/logs"

  sudo tee "$wrapper_path" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail

TIMEOUT_SECONDS="${SYNTELLA_EXEC_TIMEOUT_SECONDS}"
MAX_OUTPUT_BYTES="${SYNTELLA_EXEC_MAX_OUTPUT_BYTES}"
LOG_FILE="${log_file}"

if [[ "\$#" -lt 1 ]]; then
  echo "usage: syntella-exec '<command>'" >&2
  exit 2
fi

mkdir -p "\$(dirname "\$LOG_FILE")"
chmod 700 "\$(dirname "\$LOG_FILE")" 2>/dev/null || true

ts="\$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '[%s] cmd=%q\n' "\$ts" "\$*" >> "\$LOG_FILE"

set +e
output="\$(timeout "\$TIMEOUT_SECONDS" bash -lc "\$*" 2>&1)"
status="\$?"
set -e

if [[ "\${#output}" -gt "\$MAX_OUTPUT_BYTES" ]]; then
  output="\${output:0:\$MAX_OUTPUT_BYTES}\n...[truncated to \$MAX_OUTPUT_BYTES bytes]"
fi

printf '%s\n' "\$output"
printf 'exit_code=%s\n' "\$status"
exit "\$status"
EOF

  sudo chmod 755 "$wrapper_path"
}

install_operator_bridge() {
  local bridge_dir="$HOME/.openclaw/operator-bridge"
  local bridge_py="$bridge_dir/server.py"
  local native_helper_py="$bridge_dir/openclaw_native_agent.py"
  local spawn_sh="/usr/local/bin/syntella-spawn-agent"
  local env_dir="/etc/openclaw"
  local env_file="$env_dir/operator-bridge.env"

  # Reuse an existing token so the bridge identity is stable across re-runs.
  OPERATOR_BRIDGE_TOKEN=""
  if [[ -f "$env_file" ]]; then
    OPERATOR_BRIDGE_TOKEN="$(grep '^OPERATOR_BRIDGE_TOKEN=' "$env_file" 2>/dev/null | cut -d= -f2- | tr -d '"[:space:]' || true)"
  fi
  if [[ -z "$OPERATOR_BRIDGE_TOKEN" ]]; then
    OPERATOR_BRIDGE_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
  fi

  sudo install -d -m 750 -o root -g openclaw "$env_dir"
  sudo tee "$env_file" >/dev/null <<EOF
OPERATOR_BRIDGE_TOKEN="${OPERATOR_BRIDGE_TOKEN}"
OPERATOR_BRIDGE_PORT="${OPERATOR_BRIDGE_PORT}"
EOF
  sudo chown root:openclaw "$env_file"
  sudo chmod 640 "$env_file"

  # Validate Discord vars are set before rendering spawn template.
  if [[ -z "${DISCORD_HUMAN_ID:-}" || -z "${DISCORD_GUILD_ID:-}" || -z "${DISCORD_CHANNEL_ID:-}" ]]; then
    echo "ERROR: Discord variables not set for spawn template rendering."
    echo "HUMAN_ID='${DISCORD_HUMAN_ID:-}' GUILD_ID='${DISCORD_GUILD_ID:-}' CHANNEL_ID='${DISCORD_CHANNEL_ID:-}'"
    exit 1
  fi

  render_template "$TEMPLATE_DIR/operator-bridge/syntella-spawn-agent.sh.tmpl" "$HOME/.openclaw/syntella-spawn-agent.sh"

  # Verify placeholders were actually substituted.
  if grep -q '__DISCORD_' "$HOME/.openclaw/syntella-spawn-agent.sh"; then
    echo "ERROR: Spawn script still contains unsubstituted placeholders:"
    grep '__DISCORD_' "$HOME/.openclaw/syntella-spawn-agent.sh" | head -5
    exit 1
  fi

  sudo install -m 755 "$HOME/.openclaw/syntella-spawn-agent.sh" "$spawn_sh"

  mkdir -p "$bridge_dir"
  render_template "$TEMPLATE_DIR/operator-bridge/server.py" "$bridge_py"
  cp "$SCRIPT_DIR/openclaw_native_agent.py" "$native_helper_py"
  chmod 700 "$bridge_py"
  chmod 700 "$native_helper_py"

  # Gracefully stop existing bridge before restarting.
  pkill -f "operator-bridge/server.py" >/dev/null 2>&1 || true
  sleep 1
  # Force-kill if still alive.
  pkill -9 -f "operator-bridge/server.py" >/dev/null 2>&1 || true

  mkdir -p "$HOME/.openclaw/logs"
  nohup bash -lc "set -a; source '$env_file'; set +a; exec python3 '$bridge_py'" > "$HOME/.openclaw/logs/operator-bridge.log" 2>&1 &
  local bridge_pid=$!

  # Wait for bridge to be healthy (up to 10 seconds).
  local waited=0
  while (( waited < 10 )); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${OPERATOR_BRIDGE_PORT}/health" >/dev/null 2>&1; then
      echo "Operator bridge started (pid=$bridge_pid, port=${OPERATOR_BRIDGE_PORT})"
      return 0
    fi
    # Check if process died.
    if ! kill -0 "$bridge_pid" 2>/dev/null; then
      echo "ERROR: Operator bridge process died during startup."
      tail -n 20 "$HOME/.openclaw/logs/operator-bridge.log" 2>/dev/null || true
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "Warning: operator bridge did not respond to health check within 10s (pid=$bridge_pid)."
  echo "It may still be starting. Check: curl http://127.0.0.1:${OPERATOR_BRIDGE_PORT}/health"
}

configure_exec_approvals_for_autonomous_spawning() {
  if [[ "$EXEC_APPROVAL_MODE" != "full" ]]; then
    echo "Leaving exec approvals unchanged (EXEC_APPROVAL_MODE=${EXEC_APPROVAL_MODE})."
    return 0
  fi

  local approvals_file="$HOME/.openclaw/exec-approvals.bootstrap.json"
  cat >"$approvals_file" <<'EOF'
{
  "version": 1,
  "defaults": {
    "security": "full",
    "ask": "off",
    "askFallback": "full",
    "autoAllowSkills": true
  },
  "agents": {}
}
EOF

  if oc approvals set --gateway --file "$approvals_file" >/dev/null 2>&1 \
    || oc approvals set --file "$approvals_file" >/dev/null 2>&1; then
    echo "Configured exec approvals for autonomous spawning (security=full, ask=off)."
  else
    echo "Warning: failed to set exec approvals automatically; provisioning may still require manual approval."
  fi
}

verify_exec_approvals() {
  if [[ "$EXEC_APPROVAL_MODE" != "full" ]]; then
    return 0
  fi

  local raw ask
  raw="$(oc approvals get --gateway 2>/dev/null || oc approvals get 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    echo "Warning: could not read approvals config for verification."
    return 0
  fi

  ask="$(python3 - <<'PY' "$raw"
import json, sys
try:
  data=json.loads(sys.argv[1])
except Exception:
  print("")
  raise SystemExit(0)
print((data.get("defaults") or {}).get("ask", ""))
PY
)"

  if [[ "$ask" == "off" ]]; then
    echo "Verified exec approvals: defaults.ask=off"
  else
    echo "Warning: approvals defaults.ask is '${ask:-<unset>}' (expected 'off')."
  fi
}

verify_discord_dm_allowlist() {
  local config_file="$HOME/.openclaw/openclaw.json"
  local verification
  verification="$(
    python3 - "$config_file" "$DISCORD_HUMAN_ID" <<'PY'
import json
import os
import sys

config_path, expected_human_id = sys.argv[1:3]

try:
    with open(config_path, "r", encoding="utf-8") as handle:
        cfg = json.load(handle)
except Exception as exc:
    print(f"config_read_error:{exc}")
    sys.exit(1)

channels = cfg.get("channels")
if not isinstance(channels, dict):
    print("channels_missing")
    sys.exit(1)

discord = channels.get("discord")
if not isinstance(discord, dict):
    print("discord_missing")
    sys.exit(1)

dm_cfg = discord.get("dm")
if not isinstance(dm_cfg, dict) or dm_cfg.get("enabled") is not True:
    print("dm_enabled_false")
    sys.exit(1)

if str(discord.get("dmPolicy") or "").strip() != "allowlist":
    print("dm_policy_invalid")
    sys.exit(1)

allow_from = discord.get("allowFrom")
if not isinstance(allow_from, list) or expected_human_id not in {str(item) for item in allow_from}:
    print("allow_from_mismatch")
    sys.exit(1)

print("ok")
PY
  )" || true

  [[ "$verification" == "ok" ]] || {
    echo "Error: Discord DM allowlist verification failed (${verification:-unknown_error})"
    exit 1
  }

  echo "Verified Discord DM allowlist (owner=${DISCORD_HUMAN_ID})."
}

apply_openclaw_baseline_config() {
  local config_file="$HOME/.openclaw/openclaw.json"

  python3 - "$config_file" "$DISCORD_CHANNEL_ID" "$DEFAULT_MODEL_CATALOG_PATH" <<'PY'
import json
import os
import sys

config_path, channel_id, catalog_path = sys.argv[1:4]
cfg = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}

gateway = cfg.setdefault("gateway", {})
gateway["mode"] = "local"
gateway["bind"] = "loopback"
auth = gateway.get("auth")
if not isinstance(auth, dict):
    auth = {}
auth["mode"] = "token"
gateway["auth"] = auth
gateway["trustedProxies"] = ["127.0.0.1"]

catalog = {}
try:
    with open(catalog_path, "r", encoding="utf-8") as f:
        loaded_catalog = json.load(f)
    if isinstance(loaded_catalog, dict):
        catalog = loaded_catalog
except Exception:
    catalog = {}

catalog_providers = catalog.get("providers") if isinstance(catalog.get("providers"), dict) else {}

models_cfg = cfg.setdefault("models", {})
providers = models_cfg.setdefault("providers", {})
available_model_keys = set()

for provider_name, provider_defaults in catalog_providers.items():
    if not isinstance(provider_defaults, dict):
        continue
    provider_cfg = providers.get(provider_name)
    if not isinstance(provider_cfg, dict):
        provider_cfg = {}

    for key in ("displayName", "description", "authType", "connectLabel"):
        if key in provider_cfg:
            del provider_cfg[key]

    for field, source_field in (
        ("baseUrl", "baseUrl"),
        ("api", "api"),
    ):
        value = provider_defaults.get(source_field)
        if value and not provider_cfg.get(field):
            provider_cfg[field] = value

    env_key = str(provider_defaults.get("envKey") or "").strip()
    env_value = os.environ.get(env_key, "").strip() if env_key else ""
    if env_value:
        provider_cfg["apiKey"] = env_value

    existing_models = provider_cfg.get("models")
    if not isinstance(existing_models, list):
        existing_models = []
    existing_by_id = {}
    for model in existing_models:
        if not isinstance(model, dict):
            continue
        model_id = str(model.get("id") or "").strip()
        if model_id:
            existing_by_id[model_id] = model

    merged_models = []
    seen = set()
    for default_model in provider_defaults.get("models") or []:
        if not isinstance(default_model, dict):
            continue
        model_id = str(default_model.get("id") or "").strip()
        if not model_id:
            continue
        existing = existing_by_id.get(model_id, {})
        merged = dict(existing)
        for key, value in default_model.items():
            if key == "cost" and isinstance(value, dict):
                existing_cost = merged.get("cost")
                merged_cost = dict(existing_cost) if isinstance(existing_cost, dict) else {}
                for cost_key, cost_value in value.items():
                    if cost_key not in merged_cost or merged_cost.get(cost_key) in (None, ""):
                        merged_cost[cost_key] = cost_value
                merged["cost"] = merged_cost
                continue
            if key not in merged or merged.get(key) in (None, "", [], {}):
                merged[key] = value
        merged["id"] = model_id
        merged_models.append(merged)
        seen.add(model_id)
        available_model_keys.add(f"{provider_name}/{model_id}")

    for model in existing_models:
        if not isinstance(model, dict):
            continue
        model_id = str(model.get("id") or "").strip()
        if not model_id or model_id in seen:
            continue
        merged_models.append(model)
        available_model_keys.add(f"{provider_name}/{model_id}")

    provider_cfg["models"] = merged_models
    providers[provider_name] = provider_cfg

models_cfg["providers"] = providers

agents = cfg.setdefault("agents", {})
defs = agents.setdefault("defaults", {})
model = defs.get("model")
if not isinstance(model, dict):
    model = {}
preferred_model = (
    ("openai/gpt-5-mini" if os.environ.get("OPENAI_API_KEY", "").strip() else "")
    or ("anthropic/claude-sonnet-4-6" if os.environ.get("ANTHROPIC_API_KEY", "").strip() else "")
    or ("moonshot/kimi-k2.5" if os.environ.get("MOONSHOT_API_KEY", "").strip() else "")
    or str(catalog.get("defaultPrimaryModel") or "openai/gpt-5-mini")
)
current_primary = str(model.get("primary") or "").strip()
if not current_primary or current_primary not in available_model_keys:
    model["primary"] = preferred_model
defs["model"] = model
defs["workspace"] = os.path.expanduser("~/.openclaw/workspace/syntella")
sandbox = defs.get("sandbox")
if not isinstance(sandbox, dict):
    sandbox = {}
sandbox["mode"] = "off"
sandbox["workspaceAccess"] = "rw"
defs["sandbox"] = sandbox
heartbeat = defs.get("heartbeat")
if not isinstance(heartbeat, dict):
    heartbeat = {}
heartbeat["every"] = "15m"
heartbeat["target"] = "discord"
heartbeat["to"] = channel_id
defs["heartbeat"] = heartbeat

tools = cfg.setdefault("tools", {})
allow = tools.get("allow")
if not isinstance(allow, list):
    allow = []
for tool in ["tasks", "reports"]:
    if tool not in allow:
        allow.append(tool)
tools["allow"] = allow

exec_cfg = tools.get("exec")
if not isinstance(exec_cfg, dict):
    exec_cfg = {}
exec_cfg["host"] = "gateway"
exec_cfg["security"] = "full"
exec_cfg["ask"] = "off"
apply_patch = exec_cfg.get("applyPatch")
if not isinstance(apply_patch, dict):
    apply_patch = {}
apply_patch["workspaceOnly"] = False
exec_cfg["applyPatch"] = apply_patch
tools["exec"] = exec_cfg

fs_cfg = tools.get("fs")
if not isinstance(fs_cfg, dict):
    fs_cfg = {}
fs_cfg["workspaceOnly"] = False
tools["fs"] = fs_cfg

plugins = cfg.setdefault("plugins", {})
load = plugins.get("load")
if not isinstance(load, dict):
    load = {}
paths = load.get("paths")
if not isinstance(paths, list):
    paths = []
for path in [
    os.path.expanduser("~/.openclaw/workspace/templates/extensions/syntella-tasks"),
    os.path.expanduser("~/.openclaw/workspace/templates/extensions/syntella-reports"),
]:
    if path not in paths:
        paths.append(path)
load["paths"] = paths
plugins["load"] = load

plugin_allow = plugins.get("allow")
if not isinstance(plugin_allow, list):
    plugin_allow = []
for plugin in ["syntella-tasks", "syntella-reports"]:
    if plugin not in plugin_allow:
        plugin_allow.append(plugin)
plugins["allow"] = plugin_allow

entries = plugins.get("entries")
if not isinstance(entries, dict):
    entries = {}
for plugin in ["syntella-tasks", "syntella-reports"]:
    entry = entries.get(plugin)
    if not isinstance(entry, dict):
        entry = {}
    entry["enabled"] = True
    entries[plugin] = entry
plugins["entries"] = entries

bindings = cfg.get("bindings")
if not isinstance(bindings, list):
    bindings = []
main_binding = {
    "agentId": "main",
    "match": {
        "channel": "discord",
        "accountId": "default",
    },
}
for item in bindings:
    if isinstance(item, dict) and item.get("agentId") == "main":
        item.clear()
        item.update(main_binding)
        break
else:
    bindings.append(main_binding)
cfg["bindings"] = bindings

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

configure_openclaw_runtime() {
  harden_openclaw_state_permissions

  if should_preserve_state; then
    say "Writing workspace root context files (preserve customer state mode)"
  else
    say "Writing workspace root context files (overwrite mode)"
  fi
  seed_workspace_context_files

  say "Ensuring OpenClaw gateway baseline config"
  ensure_gateway_token

  say "Configuring model provider (shared env file + defaults)"
  setup_openclaw_env_file
  setup_openclaw_global_dotenv
  join_tailscale_tailnet
  install_syntella_exec_wrapper
  install_operator_bridge
  install_syntella_api
  install_syntella_api_firewall

  apply_openclaw_baseline_config

  say "Configuring Discord channel allowlist"
  configure_discord_channel
  verify_discord_dm_allowlist
}

detect_public_ip() {
  if [[ -n "$PUBLIC_IP_CACHE" ]]; then
    printf '%s\n' "$PUBLIC_IP_CACHE"
    return 0
  fi

  # Prefer cloud metadata (most reliable on DigitalOcean).
  PUBLIC_IP_CACHE="$(
    curl -fsS --max-time 2 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null \
    || curl -fsS --max-time 3 ifconfig.me 2>/dev/null \
    || curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null \
    || true
  )"
  printf '%s\n' "$PUBLIC_IP_CACHE"
}

setup_frontend_workspace() {
  if [[ "$FRONTEND_ENABLED" != "1" ]]; then
    return 0
  fi

  say "Setting up admin and project frontend directories (nginx)"
  sudo apt-get install -y nginx

  local admin_dir="$HOME/.openclaw/workspace/admin"
  local project_dir="$HOME/.openclaw/workspace/project"
  mkdir -p "$admin_dir" "$project_dir"

  # Syntella-owned admin surface: safe to replace on every update.
  local admin_asset
  for admin_asset in admin.html admin.css admin.js admin-core.js admin-work.js admin-models.js admin-integrations.js admin-budget.js admin-team.js README.md; do
    cp "$TEMPLATE_DIR/frontend/$admin_asset" "$admin_dir/$admin_asset"
  done

  # Customer-owned project space: create once, then preserve across updates.
  if [[ ! -f "$project_dir/index.html" ]]; then
    cat > "$project_dir/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Project Workspace</title>
  <style>
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 24px;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f6f4ef;
      color: #1a2940;
    }
    main {
      width: min(92vw, 720px);
      padding: 32px;
      border: 1px solid rgba(26, 41, 64, 0.1);
      border-radius: 24px;
      background: rgba(255, 255, 255, 0.7);
      box-shadow: 0 20px 60px rgba(32, 44, 74, 0.08);
    }
    h1 { margin-top: 0; font-size: 2rem; }
    p { line-height: 1.7; color: rgba(26, 41, 64, 0.76); }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  </style>
</head>
<body>
  <main>
    <h1>Project workspace ready</h1>
    <p>
      This directory is reserved for the customer's own website, frontend assets,
      reports, and project files.
    </p>
    <p>
      Syntella's admin lives separately at <code>/admin</code> and can be updated
      without overwriting the contents of this workspace.
    </p>
  </main>
</body>
</html>
EOF
  fi

  if [[ ! -f "$project_dir/README.md" ]]; then
    cat > "$project_dir/README.md" <<'EOF'
# Project Workspace

This directory belongs to the customer/project.

Use it for:

- website/frontend files
- generated reports
- client assets
- project-specific documents

Syntella updates should preserve this directory.
EOF
  fi

  local frontend_access_rules=""
  if [[ -n "$FRONTEND_ALLOWED_IP" ]]; then
    frontend_access_rules="$(cat <<EOF
    allow 127.0.0.1;
    allow ${FRONTEND_ALLOWED_IP};
    deny all;
EOF
)"
  fi

  # Apply nginx config for the legacy project frontend and local API proxy.
  sudo tee /etc/nginx/nginx.conf >/dev/null <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 768; }

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  sendfile on;
  access_log /var/log/nginx/access.log;

  server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

${frontend_access_rules}

    root ${project_dir};
    index index.html;

    location = /admin {
      default_type text/html;
      alias ${admin_dir}/admin.html;
    }

    location ~ ^/(admin\.css|admin\.js|admin-core\.js|admin-work\.js|admin-models\.js|admin-integrations\.js|admin-budget\.js|admin-team\.js)$ {
      alias ${admin_dir}\$uri;
    }

    location /api/ {
      proxy_pass http://127.0.0.1:${SYNTELLA_API_PORT};
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_connect_timeout 10s;
      proxy_send_timeout 300s;
      proxy_read_timeout 300s;
      send_timeout 300s;
    }

    location / {
      try_files \$uri \$uri/ /index.html;
    }
  }
}
EOF

  sudo chmod 755 "$HOME" "$HOME/.openclaw" "$HOME/.openclaw/workspace" "$admin_dir" "$project_dir"
  sudo chmod 644 "$admin_dir"/*
  sudo chmod 644 "$project_dir"/*

  sudo nginx -t
  sudo systemctl enable --now nginx >/dev/null 2>&1 || true
  sudo systemctl restart nginx >/dev/null 2>&1 || sudo service nginx restart >/dev/null 2>&1 || true
  sleep 2

  local public_ip
  public_ip="$(detect_public_ip)"

  # Validation: local loopback checks (public checks are expected to fail for non-allowlisted IPs).
  local marker local_ok api_ok
  marker="oc-bootstrap-marker-$(date +%s)-$RANDOM"
  # Remove any markers left by previous runs before appending a fresh one.
  sed -i '/<!-- oc-bootstrap-marker-/d' "$admin_dir/admin.html" 2>/dev/null || true
  echo "<!-- ${marker} -->" >> "$admin_dir/admin.html"

  local_ok=0
  api_ok=0

  if curl -fsS --max-time 3 http://127.0.0.1/admin 2>/dev/null | grep -q "$marker"; then
    local_ok=1
  fi

  if curl -fsS --max-time 3 http://127.0.0.1/api/health >/dev/null 2>&1; then
    api_ok=1
  fi

  if [[ "$local_ok" == "1" && "$api_ok" == "1" && -n "$public_ip" ]]; then
    FRONTEND_URL="http://${public_ip}"
    echo "Frontend validation passed (loopback static + API proxy)."
  else
    FRONTEND_URL=""
    echo "Warning: frontend validation failed (local_ok=${local_ok}, api_ok=${api_ok})."
    echo "Debug commands:"
    echo "  curl -s http://127.0.0.1 | head -n 20"
    echo "  curl -s http://127.0.0.1/api/health"
  fi
}

send_discord_api_message() {
  local message="$1"
  python3 - "$DISCORD_BOT_TOKEN" "$DISCORD_CHANNEL_ID" "$message" <<'PY'
import json
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

token, channel_id, message = sys.argv[1:4]
payload = json.dumps({"content": message}).encode("utf-8")
request = Request(
    f"https://discord.com/api/v10/channels/{channel_id}/messages",
    data=payload,
    headers={
        "Authorization": f"Bot {token}",
        "Content-Type": "application/json",
        "User-Agent": "syntella-bootstrap/1.0",
    },
    method="POST",
)
try:
    with urlopen(request, timeout=15) as response:
        body = response.read().decode("utf-8")
        parsed = json.loads(body) if body else {}
        if response.status < 200 or response.status >= 300:
            raise RuntimeError(f"Discord API returned status {response.status}")
        print(parsed.get("id", "ok"))
except HTTPError as exc:
    detail = exc.read().decode("utf-8", errors="replace")
    raise SystemExit(f"discord_http_error:{exc.code}:{detail}")
except URLError as exc:
    raise SystemExit(f"discord_url_error:{exc.reason}")
PY
}

send_discord_boot_ping() {
  local ts msg host ip
  ts="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  host="$(hostname 2>/dev/null || echo unknown-host)"
  ip="$(detect_public_ip)"

  if [[ -n "$FRONTEND_URL" ]]; then
    msg="✅ OpenClaw bootstrap complete (${ts}) on ${host}${ip:+ (${ip})}. Discord route is live. Frontend: ${FRONTEND_URL} (admin: ${FRONTEND_URL}/admin, allowlist: ${FRONTEND_ALLOWED_IP})"
  else
    msg="✅ OpenClaw bootstrap complete (${ts}) on ${host}${ip:+ (${ip})}. Discord route is live. Private Syntella API is available over Tailscale on port ${SYNTELLA_API_PORT}."
  fi

  local attempt
  for attempt in 1 2 3 4 5 6; do
    if send_discord_api_message "$msg" >/dev/null 2>&1; then
      echo "Sent Discord startup ping to channel:${DISCORD_CHANNEL_ID} via Discord API"
      return 0
    fi
    if oc message send --channel discord --target "channel:${DISCORD_CHANNEL_ID}" --message "$msg" >/dev/null 2>&1; then
      echo "Sent Discord startup ping to channel:${DISCORD_CHANNEL_ID} via OpenClaw"
      return 0
    fi
    sleep 3
  done

  echo "Warning: failed to send Discord startup ping after retries."
  echo "Check bot token, guild/channel IDs, bot permissions, and outbound HTTPS access."
  return 1
}

is_gateway_listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ':18789' && return 0
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi

  # Best-effort active connect test (bash built-in)
  (echo >/dev/tcp/127.0.0.1/18789) >/dev/null 2>&1 && return 0

  pgrep -f "openclaw gateway|openclaw-gateway" >/dev/null 2>&1
}

stop_gateway_processes() {
  pkill -f "openclaw gateway" >/dev/null 2>&1 || true
  pkill -f "openclaw-gateway" >/dev/null 2>&1 || true

  if command -v lsof >/dev/null 2>&1; then
    local pids
    pids="$(lsof -tiTCP:18789 -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      kill $pids >/dev/null 2>&1 || true
    fi
  fi
}

start_gateway() {
  local log_file="$HOME/.openclaw/logs/gateway.log"
  mkdir -p "$HOME/.openclaw/logs"

  # Always restart to pick up any config changes applied before this call.
  oc gateway stop >/dev/null 2>&1 || true
  stop_gateway_processes
  sleep 1

  # Remove stale lock files
  find "$HOME/.openclaw" "/tmp" -name 'gateway.*.lock' -delete 2>/dev/null || true

  echo "Starting gateway..."

  nohup "$OPENCLAW_BIN" gateway --port 18789 >"$log_file" 2>&1 &

  # Wait up to 30s for gateway to bind
  local waited=0
  while (( waited < 30 )); do
    if is_gateway_listening; then
      echo "Gateway started successfully."
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "Gateway failed to start within 30s. Check logs: $log_file"
  echo "Resolved openclaw binary: $OPENCLAW_BIN"
  echo "Resolved openclaw real binary: ${OPENCLAW_REAL_BIN:-<not-found>}"
  ls -l "$OPENCLAW_BIN" 2>/dev/null || true
  pgrep -af "openclaw gateway|openclaw-gateway" || true
  return 1
}

ensure_local_cli_gateway_access() {
  local repair_output=""

  if oc devices list --json >/dev/null 2>&1; then
    echo "Local OpenClaw CLI pairing is healthy."
    return 0
  fi

  echo "Attempting to repair local OpenClaw CLI pairing..."

  # Trigger a local client connect so the gateway can create a pending request if needed.
  oc status >/dev/null 2>&1 || true

  repair_output="$(oc devices approve --latest --json 2>&1 || true)"

  if oc devices list --json >/dev/null 2>&1; then
    echo "Local OpenClaw CLI pairing repaired."
    return 0
  fi

  echo "Warning: local OpenClaw CLI pairing is still unavailable."
  if [[ -n "$repair_output" ]]; then
    echo "$repair_output"
  fi
  echo "Try manually: openclaw devices approve --latest"
  return 1
}

print_summary() {
  echo
  echo "----------------------------------------"
  echo "Bootstrap complete."
  echo
  echo "Tailnet access configured."
  echo "- Tailscale hostname: ${TAILSCALE_HOSTNAME_EFFECTIVE:-unknown}"
  echo "- MagicDNS name:      ${TAILSCALE_DNS_NAME_EFFECTIVE:-unknown}"
  echo "- Tailscale IPv4:     ${TAILSCALE_IPV4_EFFECTIVE:-unknown}"
  echo "- API base URL:       http://${TAILSCALE_HOSTNAME_EFFECTIVE:-unknown}:${SYNTELLA_API_PORT}"
  echo "- API exposure:       ${SYNTELLA_API_BIND_HOST} (firewalled to loopback + tailscale0)"
  echo
  echo "Discord mode configured."
  echo "- Guild ID:   ${DISCORD_GUILD_ID}"
  echo "- Channel ID: ${DISCORD_CHANNEL_ID}"
  echo "- DM policy:  allowlist (human only: ${DISCORD_HUMAN_ID})"
  echo "- Group mode: allowlist (configured guild/channel; non-bot humans restricted to configured human)"
  echo "- Operator bridge API (localhost): http://127.0.0.1:${OPERATOR_BRIDGE_PORT}"
  if [[ -n "$FRONTEND_URL" ]]; then
    echo "- Frontend: ${FRONTEND_URL}"
    echo "- Admin page: ${FRONTEND_URL}/admin"
    if [[ -n "$FRONTEND_ALLOWED_IP" ]]; then
      echo "- Frontend allowlist: ${FRONTEND_ALLOWED_IP}"
    else
      echo "- Frontend allowlist: public"
    fi
  else
    echo "- Frontend: disabled"
  fi
  echo
  echo "Gateway is loopback-only (no public OpenClaw dashboard access configured)."
  echo "Use Discord as your primary interface."
  echo "Use the main Syntella site over the tailnet for portal access."
  echo "----------------------------------------"
}

main() {
  assert_templates_exist
  require_discord_inputs
  require_portal_and_tailnet_inputs
  configure_openclaw_runtime

  say "Starting/restarting gateway service"
  if ! start_gateway; then
    echo "Warning: gateway startup reported failure; continuing with diagnostics."
  fi

  configure_exec_approvals_for_autonomous_spawning
  verify_exec_approvals

  setup_frontend_workspace

  say "Checking gateway health"
  if is_gateway_listening; then
    echo "Gateway is listening on port 18789"
    ensure_local_cli_gateway_access || true
    harden_openclaw_state_permissions
    say "Sending Discord startup ping"
    send_discord_boot_ping || true
  else
    echo "Gateway not listening on port 18789"
    echo "The private Syntella API and droplet runtime can still be inspected while gateway troubleshooting continues."
  fi

  print_summary
}

main "$@"
