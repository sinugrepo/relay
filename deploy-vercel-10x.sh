#!/usr/bin/env bash
# Deploy project ini Nx ke Vercel sebagai project yang BERBEDA.
#
# Tiap iterasi deploy ke project name yang berbeda via:
#   vercel deploy --prod --yes --force --project <nama-unik>
#
# Usage:
#   chmod +x deploy-vercel-10x.sh
#   ./deploy-vercel-10x.sh                    # prefix=relay, count=10
#   ./deploy-vercel-10x.sh opencode-relay 10  # prefix + count custom
#   SCOPE=my-team ./deploy-vercel-10x.sh      # deploy ke team tertentu
#   # atau pakai token: VERCEL_TOKEN=xxx ./deploy-vercel-10x.sh
#
# Output: deployed-urls.txt
#   <project-name> | <deployment-url> | <deployment-url>/api/relay
set -euo pipefail

PREFIX="${1:-relay}"
COUNT="${2:-10}"
SCOPE="${SCOPE:-}"
OUTFILE="deployed-urls.txt"

EXTRA_ARGS=()
if [[ -n "$SCOPE" ]]; then EXTRA_ARGS+=(--scope "$SCOPE"); fi
if [[ -n "${VERCEL_TOKEN:-}" ]]; then EXTRA_ARGS+=(--token "$VERCEL_TOKEN"); fi

if ! command -v vercel >/dev/null 2>&1; then
  echo "Vercel CLI tidak ditemukan. Install dulu: npm i -g vercel" >&2
  exit 1
fi

echo "Vercel CLI: $(vercel --version 2>&1 | head -n 1)"

if ! vercel whoami "${EXTRA_ARGS[@]}" --no-color 2>&1; then
  echo "Belum login ke Vercel. Jalankan: vercel login (atau set VERCEL_TOKEN)" >&2
  exit 1
fi

# normalisasi prefix -> slug valid
PREFIX="$(echo "$PREFIX" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
if [[ -z "$PREFIX" ]]; then PREFIX="relay"; fi

{
  echo "# deployed-urls.txt - hasil deploy $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# format: <project-name> | <deployment-url> | <relay-endpoint>"
} > "$OUTFILE"

success=0
failed=0

for ((i = 1; i <= COUNT; i++)); do
  num="$(printf '%02d' "$i")"
  rand="$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 4 || true)"
  name="${PREFIX}-${num}-${rand}"

  echo ""
  echo "[$i/$COUNT] Deploy project: $name ..."

  # (a) buat project eksplisit. Catatan: `project add` TIDAK mengenal
  # flag --yes (langsung error) jadi jangan tambahkan.
  # Error "already exists" tidak masalah -> lanjut deploy.
  if ! add_out="$(vercel project add "$name" "${EXTRA_ARGS[@]}" --no-color 2>&1)"; then
    echo "  (project add) $(echo "$add_out" | head -n 3 | tr '\n' ' ')"
    if echo "$add_out" | grep -qiE 'already exists|already claimed'; then
      echo "  (project sudah ada, lanjut deploy)"
    else
      echo "  GAGAL membuat project, lewati."
      echo "# FAILED $name :: project add gagal: $(echo "$add_out" | tr '\n' ' ' | cut -c1-300)" >> "$OUTFILE"
      failed=$((failed + 1))
      continue
    fi
  else
    echo "  (project add) $(echo "$add_out" | head -n 2 | tr '\n' ' ')"
  fi

  # (b) deploy ke project tsb
  set +e
  out="$(vercel deploy --prod --yes --force --project "$name" "${EXTRA_ARGS[@]}" --no-color 2>&1)"
  code=$?
  set -e

  url="$(echo "$out" | grep -oE 'https://[^[:space:]]+' | sed -E 's/[.,)]+$//' | tail -n 1 || true)"

  if [[ $code -ne 0 || -z "$url" ]]; then
    echo "  GAGAL."
    echo "$out" | tail -n 20
    echo "# FAILED $name :: $(echo "$out" | tr '\n' ' ' | cut -c1-300)" >> "$OUTFILE"
    failed=$((failed + 1))
  else
    echo "  OK: $url"
    echo "  Relay: $url/api/relay"
    echo "$name | $url | $url/api/relay" >> "$OUTFILE"
    success=$((success + 1))
  fi

  if [[ $i -lt $COUNT ]]; then sleep 3; fi
done

echo ""
echo "Selesai. Sukses: $success, Gagal: $failed. Daftar: $OUTFILE"
[[ $failed -gt 0 ]] && exit 2 || true
