#!/usr/bin/env bash
# Redeploy semua project yang tercatat di deployed-urls.txt (untuk push update code) — MODE PARALEL.
#
# Membaca baris format:
#   <project-name> | <deployment-url> | <relay-endpoint>
# Lalu untuk tiap project menjalankan (paralel):
#   vercel deploy --prod --yes --force --project <project-name>
# TIDAK membuat project baru, TIDAK mengubah deployed-urls.txt
# (kecuali UPDATE_URLS=1 untuk refresh kolom URL).
#
# Usage:
#   chmod +x redeploy-vercel.sh
#   ./redeploy-vercel.sh                                    # paralel, default 10 job
#   MAX_JOBS=5 ./redeploy-vercel.sh                         # batasi 5 paralel
#   MAX_JOBS=0 ./redeploy-vercel.sh                         # tanpa batas = semua langsung
#   ./redeploy-vercel.sh my-urls.txt                        # file lain
#   SCOPE=my-team ./redeploy-vercel.sh
#   UPDATE_URLS=1 ./redeploy-vercel.sh                      # refresh kolom URL + backup .bak-*
#   MAX_JOBS=10 UPDATE_URLS=1 ./redeploy-vercel.sh
#   # atau pakai token: VERCEL_TOKEN=xxx MAX_JOBS=10 ./redeploy-vercel.sh
set -euo pipefail

INFILE="${1:-deployed-urls.txt}"
SCOPE="${SCOPE:-}"
UPDATE_URLS="${UPDATE_URLS:-0}"
MAX_JOBS="${MAX_JOBS:-10}"

EXTRA_ARGS=()
if [[ -n "$SCOPE" ]]; then EXTRA_ARGS+=(--scope "$SCOPE"); fi
if [[ -n "${VERCEL_TOKEN:-}" ]]; then EXTRA_ARGS+=(--token "$VERCEL_TOKEN"); fi

if [[ ! -f "$INFILE" ]]; then
  echo "File tidak ditemukan: $INFILE" >&2
  exit 1
fi

if ! command -v vercel >/dev/null 2>&1; then
  echo "Vercel CLI tidak ditemukan. Install dulu: npm i -g vercel" >&2
  exit 1
fi

echo "Vercel CLI: $(vercel --version 2>&1 | head -n 1)"

if ! vercel whoami "${EXTRA_ARGS[@]}" --no-color 2>&1; then
  echo "Belum login ke Vercel. Jalankan: vercel login (atau set VERCEL_TOKEN)" >&2
  exit 1
fi

# Parse project names: skip komentar/kosong/FAILED, ambil kolom 1 sebelum '|'
mapfile -t PROJECTS < <(awk -F'|' '{
  gsub(/^[ \t]+|[ \t]+$/, "", $0);
  if ($0 == "" || $0 ~ /^#/) next;
  gsub(/^[ \t]+|[ \t]+$/, "", $1);
  if ($1 == "" || $1 ~ /^#/) next;
  print $1
}' "$INFILE")

if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  echo "Tidak ada project valid di $INFILE" >&2
  exit 1
fi

N=${#PROJECTS[@]}

# Normalisasi MAX_JOBS: 0 / negatif / non-angka -> semua langsung (N)
if ! [[ "$MAX_JOBS" =~ ^-?[0-9]+$ ]]; then
  echo "MAX_JOBS tidak valid: $MAX_JOBS (pakai default 10)" >&2
  MAX_JOBS=10
fi
if [[ "$MAX_JOBS" -le 0 || "$MAX_JOBS" -gt "$N" ]]; then
  MAX_JOBS=$N
fi

echo "Ditemukan $N project di $INFILE"
echo "Mode paralel: $MAX_JOBS job sekaligus (semua langsung jika MAX_JOBS=$N)"

LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/vercel-redeploy-XXXXXX")"
echo "Log per-project: $LOGDIR"

# Satu job redeploy. Selalu exit 0 agar 'set -e' + 'wait' tidak abort.
# Status asli ditulis ke $LOGDIR/<name>.code (0=sukses), URL ke .url
redeploy_one() {
  local name="$1" idx="$2" total="$3"
  local log="$LOGDIR/${name}.log"
  local code=0 url=""

  echo "[$idx/$total] START: $name"

  set +e
  vercel deploy --prod --yes --force --project "$name" "${EXTRA_ARGS[@]}" --no-color >"$log" 2>&1
  code=$?
  set -e

  url="$(grep -oE 'https://[^[:space:]]+' "$log" | sed -E 's/[.,)]+$//' | tail -n 1 || true)"

  if [[ $code -ne 0 || -z "$url" ]]; then
    echo "$code" > "$LOGDIR/${name}.code"
    : > "$LOGDIR/${name}.url" 2>/dev/null || true
    echo "[$idx/$total] GAGAL: $name (lihat $log)"
  else
    echo "0" > "$LOGDIR/${name}.code"
    echo "$url" > "$LOGDIR/${name}.url"
    echo "[$idx/$total] OK: $name -> $url"
    echo "[$idx/$total] Relay: $url/api/relay"
  fi
}

# --- Luncurkan semua job dengan batas konkurensi ---
running=0
i=0
for name in "${PROJECTS[@]}"; do
  i=$((i + 1))
  redeploy_one "$name" "$i" "$N" &
  running=$((running + 1))
  if [[ $running -ge $MAX_JOBS ]]; then
    set +e
    if wait -n 2>/dev/null; then
      running=$((running - 1))
    else
      # Fallback bash lama tanpa 'wait -n': tunggu satu job via jobs polling
      set -e
      while [[ $(jobs -r | wc -l) -ge $MAX_JOBS ]]; do sleep 1; done
      running=$(jobs -r | wc -l || true)
      set +e
    fi
    set -e
  fi
done

# Tunggu sisa job
set +e
wait
set -e

# --- Rangkuman ---
echo ""
echo "================ HASIL ================"
success=0
failed=0
declare -A NEWURLS=()
for name in "${PROJECTS[@]}"; do
  code="$(cat "$LOGDIR/${name}.code" 2>/dev/null || echo 1)"
  url="$(cat "$LOGDIR/${name}.url" 2>/dev/null || true)"
  if [[ "$code" == "0" && -n "$url" ]]; then
    printf '  OK    %-25s %s\n' "$name" "$url"
    NEWURLS["$name"]="$url"
    success=$((success + 1))
  else
    printf '  GAGAL %-25s (log: %s.log)\n' "$name" "$LOGDIR/${name}"
    failed=$((failed + 1))
  fi
done
echo "======================================="
echo "Selesai. Sukses: $success, Gagal: $failed. Log: $LOGDIR"

if [[ $failed -gt 0 ]]; then
  echo ""
  echo "--- Tail log yang gagal (15 baris terakhir) ---"
  for name in "${PROJECTS[@]}"; do
    code="$(cat "$LOGDIR/${name}.code" 2>/dev/null || echo 1)"
    if [[ "$code" != "0" ]]; then
      echo ">>> $name:"
      tail -n 15 "$LOGDIR/${name}.log" 2>/dev/null | sed 's/^/    /' || true
    fi
  done
fi

# Opsional: refresh kolom URL (backup dulu)
if [[ "$UPDATE_URLS" == "1" && $success -gt 0 ]]; then
  backup="${INFILE}.bak-$(date '+%Y%m%d-%H%M%S')"
  cp "$INFILE" "$backup"
  echo "Backup: $backup"
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(echo "$line" | sed -E 's/^[ \t]+//; s/[ \t]+$//')"
    if [[ -z "$trimmed" || "$trimmed" == \#* ]]; then
      echo "$line" >> "$tmp"
      continue
    fi
    pname="$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')"
    if [[ -n "${NEWURLS[$pname]:-}" ]]; then
      u="${NEWURLS[$pname]}"
      echo "$pname | $u | $u/api/relay" >> "$tmp"
    else
      echo "$line" >> "$tmp"
    fi
  done < "$INFILE"
  mv "$tmp" "$INFILE"
  echo "URL diperbarui di: $INFILE"
fi

[[ $failed -gt 0 ]] && exit 2 || true
