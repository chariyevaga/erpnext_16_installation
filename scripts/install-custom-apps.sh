#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
CUSTOM_DIR="/opt/frappe/custom-apps"
COMMON_SITE_CONFIG="$BENCH_DIR/sites/common_site_config.json"
NPM_GLOBAL="/home/frappe/.npm-global"

# Always-install apps (hardcoded, not controlled by env)
ALWAYS_APPS=(
  "https://github.com/frappe/hrms#version-16"
  "https://github.com/frappe/crm#develop"
  "https://github.com/frappe/chat#main"
  "https://github.com/frappe/print_designer#develop"
)

cd "$BENCH_DIR"

ensure_node_tooling() {
  mkdir -p "$NPM_GLOBAL"
  npm config set prefix "$NPM_GLOBAL" >/dev/null 2>&1 || true
  export PATH="$NPM_GLOBAL/bin:$PATH"

  if command -v corepack >/dev/null 2>&1; then
    corepack enable >/dev/null 2>&1 || true
    corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
  fi

  if ! command -v pnpm >/dev/null 2>&1; then
    npm install -g pnpm >/dev/null 2>&1 || true
  fi
}

ensure_common_site_config() {
  if [ ! -f "$COMMON_SITE_CONFIG" ]; then
    echo "{ \"socketio_port\": 9000 }" > "$COMMON_SITE_CONFIG"
    return 0
  fi

  if ! grep -q '"socketio_port"' "$COMMON_SITE_CONFIG"; then
    tmp="$(mktemp)"
    python - <<'PY' "$COMMON_SITE_CONFIG" "$tmp"
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r") as f:
    data = json.load(f)
data.setdefault("socketio_port", 9000)
with open(dst, "w") as f:
    json.dump(data, f, indent=1, sort_keys=True)
PY
    mv "$tmp" "$COMMON_SITE_CONFIG"
  fi
}

install_app_from_path() {
  local app_path="$1"
  local app_name
  app_name="$(basename "$app_path")"

  if [ -d "apps/$app_name" ]; then
    echo "[custom-apps] $app_name already present, skipping"
    return 0
  fi

  echo "[custom-apps] Installing $app_name from $app_path"
  bench get-app --skip-branch "$app_path"
}

install_app_from_url() {
  local app_url="$1"
  if [ -z "$app_url" ]; then
    return 0
  fi

  ensure_common_site_config

  local url="$app_url"
  local branch=""

  # Support URL#branch syntax for specifying branch
  if [[ "$app_url" == *"#"* ]]; then
    url="${app_url%%#*}"
    branch="${app_url##*#}"
  fi

  if [ -n "$branch" ]; then
    echo "[custom-apps] Installing from URL: $url (branch: $branch)"
    bench get-app --branch "$branch" "$url"
  else
    echo "[custom-apps] Installing from URL: $url"
    bench get-app "$url"
  fi
}

# Install apps that must always be present
ensure_node_tooling
for url in "${ALWAYS_APPS[@]}"; do
  install_app_from_url "$url"
done

# Install apps from local directories (if any)
if [ -d "$CUSTOM_DIR" ]; then
  for app_path in "$CUSTOM_DIR"/*; do
    if [ -d "$app_path" ]; then
      install_app_from_path "$app_path"
    fi
  done
fi

# Install apps from build arg CUSTOM_APPS (comma-separated URLs)
if [ -n "${CUSTOM_APPS:-}" ]; then
  IFS=',' read -r -a urls <<< "$CUSTOM_APPS"
  for url in "${urls[@]}"; do
    install_app_from_url "${url// /}"
  done
fi
