#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
CUSTOM_DIR="/opt/frappe/custom-apps"
COMMON_SITE_CONFIG="$BENCH_DIR/sites/common_site_config.json"
NPM_GLOBAL="/home/frappe/.npm-global"

# Always-install apps (hardcoded, not controlled by env)
ALWAYS_APPS=(
  "https://github.com/defendicon/POS-Awesome-V15.git#15.23.1"
  "https://github.com/frappe/hrms.git#v16.4.3"
  "https://github.com/frappe/crm.git#main"
  "https://github.com/frappe/print_designer.git#main"
  "https://github.com/The-Commit-Company/raven#develop"
)
cd "$BENCH_DIR"

ensure_node_tooling() {
  # Prefer nvm-managed Node if available
  if [ -s "/home/frappe/.nvm/nvm.sh" ]; then
    # Avoid nvm prefix conflicts if a legacy .npmrc exists
    if [ -f "/home/frappe/.npmrc" ] && grep -q '^prefix=' "/home/frappe/.npmrc"; then
      rm -f "/home/frappe/.npmrc"
    fi
    . "/home/frappe/.nvm/nvm.sh"
    nvm use --silent node >/dev/null 2>&1 || nvm use --silent default >/dev/null 2>&1 || true
  fi

  if ! command -v npm >/dev/null 2>&1; then
    return 0
  fi

  if command -v corepack >/dev/null 2>&1; then
    corepack enable >/dev/null 2>&1 || true
    corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
    corepack prepare yarn@1.22.22 --activate >/dev/null 2>&1 || true
  fi

  if ! command -v pnpm >/dev/null 2>&1; then
    npm install -g pnpm >/dev/null 2>&1 || true
  fi
  if ! command -v yarn >/dev/null 2>&1; then
    npm install -g yarn >/dev/null 2>&1 || true
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

  local repo_name
  repo_name="$(basename "$url")"
  repo_name="${repo_name%.git}"

  # Skip if app already present (handle POS Awesome repo naming)
  if [ "$repo_name" = "POS-Awesome-V15" ] && [ -d "apps/posawesome" ]; then
    echo "[custom-apps] posawesome already present, skipping"
    return 0
  fi
  if [ -d "apps/$repo_name" ]; then
    echo "[custom-apps] $repo_name already present, skipping"
    return 0
  fi

  if [ -n "$branch" ]; then
    echo "[custom-apps] Installing from URL: $url (branch: $branch)"
    bench get-app --branch "$branch" "$url"
  else
    echo "[custom-apps] Installing from URL: $url"
    bench get-app "$url"
  fi
}

patch_posawesome_profile_js() {
  local file="$BENCH_DIR/apps/posawesome/posawesome/posawesome/api/pos_profile.js"
  if [ ! -f "$file" ]; then
    return 0
  fi

  python - <<'PY' "$file"
import re, sys
path = sys.argv[1]
src = open(path, "r", encoding="utf-8").read()

# Guard child-table set_query calls that can throw when the field is missing
def guard_child_table(src_text, fieldname):
    if f"fields_dict?.{fieldname}" in src_text:
        return src_text
    pattern = (
        r'\n\t\tfrm\.set_query\("account", "'
        + fieldname +
        r'", function \(doc\) \{[\s\S]*?\n\t\t\}\);\n'
    )
    m = re.search(pattern, src_text)
    if not m:
        return src_text
    block = m.group(0)
    guard = (
        f"\t\tconst {fieldname}_field = frm.fields_dict?.{fieldname};\n"
        f"\t\tif ({fieldname}_field && {fieldname}_field.grid) {{\n"
        f"{block}"
        f"\t\t}}\n"
    )
    return src_text.replace(block, guard, 1)

src2 = guard_child_table(src, "posa_allowed_expense_accounts")
src3 = guard_child_table(src2, "posa_allowed_source_accounts")

if src3 != src:
    with open(path, "w", encoding="utf-8") as f:
        f.write(src3)
PY
}

patch_crm_demo_data() {
  local file="$BENCH_DIR/apps/crm/crm/demo/api.py"
  if [ ! -f "$file" ]; then
    return 0
  fi

  python - <<'PY' "$file"
import re, sys
path = sys.argv[1]
src = open(path, "r", encoding="utf-8").read()

# Insert a guard to skip CRM demo data unless setup_demo is explicitly enabled
if "setup_demo" in src and "crm_demo_data" in src and "create_demo_data" in src:
    # Already patched or customized
    sys.exit(0)

pattern = r"def create_demo_data\\(_args: dict \\| None = None\\):\\n"
replacement = (
    "def create_demo_data(_args: dict | None = None):\\n"
    "\\tif not (getattr(frappe.flags, \\\"setup_demo\\\", False) or frappe.conf.get(\\\"crm_demo_data\\\")):\\n"
    "\\t\\treturn\\n"
)

new_src, n = re.subn(pattern, replacement, src, count=1)
if n == 0:
    sys.exit(0)

with open(path, "w", encoding="utf-8") as f:
    f.write(new_src)
PY
}

patch_crm_setup_hook() {
  local file="$BENCH_DIR/apps/crm/crm/hooks.py"
  if [ ! -f "$file" ]; then
    return 0
  fi

  python - <<'PY' "$file"
import re, sys
path = sys.argv[1]
src = open(path, "r", encoding="utf-8").read()

# Disable CRM demo data hook during setup wizard
pattern = r"^setup_wizard_complete\\s*=\\s*\\\"crm\\.demo\\.api\\.create_demo_data\\\"\\s*$"
replacement = "setup_wizard_complete = \"\""

new_src, n = re.subn(pattern, replacement, src, flags=re.M)
if n == 0:
    # already patched or different line; do nothing
    sys.exit(0)

with open(path, "w", encoding="utf-8") as f:
    f.write(new_src)
PY
}

patch_raven_user_image() {
  local file="$BENCH_DIR/apps/raven/raven/raven/doctype/raven_user/raven_user.py"
  if [ ! -f "$file" ]; then
    return 0
  fi

  python - <<'PY' "$file"
import re, sys
path = sys.argv[1]
src = open(path, "r", encoding="utf-8").read()

if "get_url" in src and "user_image.startswith" in src:
    sys.exit(0)

pattern = r"(def update_photo_from_user\\(self\\):[\\s\\S]*?\\n\\t\\tuser_image = frappe\\.db\\.get_value\\(\"User\", self\\.user, \"user_image\"\\)\\n)"
replacement = (
    "\\1"
    "\\t\\tif user_image and not user_image.startswith((\"http://\", \"https://\")):\\n"
    "\\t\\t\\tfrom frappe.utils import get_url\\n"
    "\\t\\t\\tuser_image = get_url(user_image)\\n"
)

new_src, n = re.subn(pattern, replacement, src, count=1)
if n == 0:
    sys.exit(0)

with open(path, "w", encoding="utf-8") as f:
    f.write(new_src)
PY
}

# Install apps that must always be present
ensure_node_tooling
for url in "${ALWAYS_APPS[@]}"; do
  install_app_from_url "$url"
done

# Apply local compatibility patch for POS Awesome if present
patch_posawesome_profile_js
patch_crm_demo_data
patch_crm_setup_hook
patch_raven_user_image

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
