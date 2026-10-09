#!/usr/bin/env bash
# End-to-end test of the app against a real File Browser server.
#
# Builds the server from this repository, seeds a scratch root, starts it
# (plus a basic-auth reverse proxy in front of it) and runs
# integration_test/app_test.dart. The app runs as a Linux desktop build under
# Xvfb, because the cloud CI box has no Android emulator; the Dart code and
# every HTTP call are the same as on Android. See README.md for running the
# same test on an Android emulator instead.
#
# Set FB_E2E_SHOTS to a directory to also save screenshots of the main
# screens there.
#
# Needs: Go, Flutter (see .flutter-version), Python 3, and for the Linux
# build clang, cmake, ninja, libgtk-3-dev, libsecret-1-dev and xvfb.
set -euo pipefail

APP_DIR=$(cd "$(dirname "$0")/../.." && pwd)
REPO_DIR=$(cd "$APP_DIR/.." && pwd)
WORK=$(mktemp -d)
PORT=${FB_E2E_PORT:-18080}
PROXY_PORT=${FB_E2E_PROXY_PORT:-18081}
ADMIN_PASS=admin-password-123
VIEWER_PASS=viewer-password-123
PROXY_USER=gate
PROXY_PASS=gate-password
DEVICE=${FB_E2E_DEVICE:-linux}
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== Building File Browser"
# The web UI is not needed; an empty dist satisfies the embed directive.
if [ ! -e "$REPO_DIR/frontend/dist/index.html" ]; then
  mkdir -p "$REPO_DIR/frontend/dist"
  echo '<!doctype html><title>File Browser</title>' > "$REPO_DIR/frontend/dist/index.html"
fi
(cd "$REPO_DIR" && go build -o "$WORK/filebrowser" .)

echo "== Seeding $WORK/root"
root="$WORK/root"
mkdir -p "$root/photos" "$root/projects/app"
printf '# Readme\n\nSeeded by the e2e test.\n' > "$root/readme.md"
printf 'secret\n' > "$root/.hidden"
printf 'zzz\n' > "$root/zz-last.txt"
head -c 4096 /dev/urandom > "$root/projects/app/data.bin"
python3 - "$root/photos" <<'PY'
import struct, sys, zlib
def png(path, rgb):
    w = h = 64
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
png(sys.argv[1] + "/red.png", (220, 30, 30))
png(sys.argv[1] + "/blue.png", (30, 30, 220))
PY

db="$WORK/fb.db"
fb() { "$WORK/filebrowser" -d "$db" "$@" >/dev/null; }
# A short token lifetime makes the server ask for renewal on every response,
# so the renewal path is exercised too.
fb config init --address 127.0.0.1 --port "$PORT" --root "$root" --tokenExpirationTime 50m
fb users add admin "$ADMIN_PASS" --perm.admin
fb users add viewer "$VIEWER_PASS" --perm.create=false --perm.rename=false \
  --perm.modify=false --perm.delete=false --perm.share=false

echo "== Starting server on :$PORT and proxy on :$PROXY_PORT"
"$WORK/filebrowser" -d "$db" > "$WORK/server.log" 2>&1 &
pids+=($!)
python3 "$APP_DIR/test/e2e/basic_auth_proxy.py" "$PROXY_PORT" "http://127.0.0.1:$PORT" "$PROXY_USER" "$PROXY_PASS" &
pids+=($!)
for _ in $(seq 50); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
  sleep 0.2
done

cd "$APP_DIR"
if [ "$DEVICE" = linux ] && [ ! -d linux ]; then
  # The Linux runner is only for this test; it is not committed.
  flutter create --platforms=linux --org org.buetow --project-name filebrowser_android . >/dev/null
  # flutter create adds a counter-app sample test; it does not apply here.
  git ls-files --error-unmatch test/widget_test.dart >/dev/null 2>&1 || rm -f test/widget_test.dart
fi

host=127.0.0.1
# An Android emulator reaches the host's loopback as 10.0.2.2.
[ "$DEVICE" != linux ] && host=10.0.2.2

run=(flutter test integration_test/app_test.dart -d "$DEVICE"
  --dart-define=FB_E2E_URL="http://$host:$PORT"
  --dart-define=FB_E2E_PROXY_URL="http://$host:$PROXY_PORT"
  --dart-define=FB_E2E_ADMIN_PASS="$ADMIN_PASS"
  --dart-define=FB_E2E_VIEWER_PASS="$VIEWER_PASS"
  --dart-define=FB_E2E_PROXY_USER="$PROXY_USER"
  --dart-define=FB_E2E_PROXY_PASS="$PROXY_PASS"
  --dart-define=FB_E2E_SHOTS="${FB_E2E_SHOTS:-}")
echo "== ${run[*]}"
if [ "$DEVICE" = linux ] && [ -z "${DISPLAY:-}" ]; then
  xvfb-run -a -s "-screen 0 1080x1920x24" "${run[@]}"
else
  "${run[@]}"
fi
