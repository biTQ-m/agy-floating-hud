#!/usr/bin/env bash
set -euo pipefail

PLUGIN_NAME="agy-floating-hud"
TARGET_DIR="${HOME}/.gemini/config/plugins/${PLUGIN_NAME}"
DATA_DIR="${HOME}/.gemini/antigravity/plugin_data/${PLUGIN_NAME}"

usage() {
  cat <<EOF
Usage: ./install.sh [OPTIONS]

Build and install AGY Floating HUD for Antigravity 2.0 Desktop (macOS).

Options:
  --link         Symlink ${TARGET_DIR} to this directory (default)
  --copy         Copy plugin files into ${TARGET_DIR}
  --rebuild      Force recompiling macos/AgyFloatingHud.app
  --no-launch    Do not auto-start AgyFloatingHud.app immediately after install
  --uninstall    Stop helper and remove ${TARGET_DIR}
  -h, --help     Show this help message
EOF
}

MODE="link"
REBUILD=0
AUTO_LAUNCH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --link)
      MODE="link"
      shift
      ;;
    --copy)
      MODE="copy"
      shift
      ;;
    --rebuild)
      REBUILD=1
      shift
      ;;
    --no-launch)
      AUTO_LAUNCH=0
      shift
      ;;
    --uninstall)
      pkill -x AgyFloatingHud 2>/dev/null || true
      rm -rf "${TARGET_DIR}"
      echo "Stopped AgyFloatingHud and removed ${TARGET_DIR}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "${SCRIPT_DIR}/install.sh" "${SCRIPT_DIR}/hooks/hud_tracker.py"

# Build native macOS Floating HUD app bundle
if [[ "$(uname -s)" == "Darwin" ]]; then
  HUD_SRC="${SCRIPT_DIR}/macos/AgyFloatingHud.swift"
  HUD_APP="${SCRIPT_DIR}/macos/AgyFloatingHud.app"
  HUD_BIN="${HUD_APP}/Contents/MacOS/AgyFloatingHud"
  HUD_PLIST="${HUD_APP}/Contents/Info.plist"

  if [[ "${REBUILD}" == "1" || ! -x "${HUD_BIN}" || "${HUD_SRC}" -nt "${HUD_BIN}" ]]; then
    echo "Compiling native macOS Dynamic Capsule HUD (AgyFloatingHud.app)..."
    mkdir -p "${HUD_APP}/Contents/MacOS"
    cat > "${HUD_PLIST}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AgyFloatingHud</string>
  <key>CFBundleIdentifier</key>
  <string>com.biTQm.agy-floating-hud</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AGY Floating HUD</string>
  <key>CFBundleDisplayName</key>
  <string>AGY Floating HUD</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
    pkill -x AgyFloatingHud 2>/dev/null || true
    swiftc -swift-version 5 -parse-as-library -O \
      -lsqlite3 -framework Cocoa -framework AppKit -framework SwiftUI \
      "${HUD_SRC}" -o "${HUD_BIN}"
    codesign --force --deep --sign - "${HUD_APP}" >/dev/null 2>&1 || true
    echo "Built & signed ${HUD_APP}"
  fi
fi

mkdir -p "${HOME}/.gemini/config/plugins" "${DATA_DIR}"
rm -rf "${TARGET_DIR}"

if [[ "${MODE}" == "copy" ]]; then
  mkdir -p "${TARGET_DIR}"
  rsync -a --exclude '.git' --exclude '.DS_Store' --exclude '__pycache__' "${SCRIPT_DIR}/" "${TARGET_DIR}/"
  chmod +x "${TARGET_DIR}/install.sh" "${TARGET_DIR}/hooks/hud_tracker.py"
  echo "Copied ${SCRIPT_DIR} -> ${TARGET_DIR}"
else
  ln -s "${SCRIPT_DIR}" "${TARGET_DIR}"
  echo "Linked ${TARGET_DIR} -> ${SCRIPT_DIR}"
fi

if [[ "${AUTO_LAUNCH}" == "1" && "$(uname -s)" == "Darwin" ]]; then
  SIDECAR_LOG="${HOME}/.gemini/antigravity/sidecar_data/${PLUGIN_NAME}/floating_hud/logs/sidecar.log"
  if [[ -f "${SIDECAR_LOG}" ]]; then
    LAST_PORT="$(grep -Eo '127\.0\.0\.1:[0-9]+' "${SIDECAR_LOG}" | tail -n 1 | cut -d: -f2 || true)"
    if [[ -n "${LAST_PORT}" ]]; then
      SIDECAR_PID="$(lsof -ti tcp:"${LAST_PORT}" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
      if [[ -n "${SIDECAR_PID}" ]]; then
        kill -TERM "${SIDECAR_PID}" 2>/dev/null || true
      fi
    fi
  fi

  ACTIVE_APP="${TARGET_DIR}/macos/AgyFloatingHud.app"
  if [[ -d "${ACTIVE_APP}" ]]; then
    pkill -x AgyFloatingHud 2>/dev/null || true
    sleep 0.2
    open -g -a "${ACTIVE_APP}"
    echo "Launched AGY Floating HUD on desktop (check top-right capsule & macOS menu bar icon)."
  fi
fi
