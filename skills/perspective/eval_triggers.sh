#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  ./eval_triggers.sh <skill_dir> [eval_queries.json]

Environment:
  RUNS=3                 Number of times to run each query
  THRESHOLD=0.5          Trigger-rate pass threshold
  MODEL=                 Optional Codex model, e.g. gpt-5.2-codex
  CODEX_BIN=codex        Codex executable
  CODEX_SANDBOX=read-only
  CODEX_HOME_SOURCE=     Source Codex home for auth, defaults to CODEX_HOME or ~/.codex
  DISCOVERY_CHECK=1      Verify Codex sees the skill via auto discovery before eval
  DISCOVERY_ONLY=0       Stop after the auto-discovery preflight
  OUT=trigger_results.json

Example:
  RUNS=3 ./eval_triggers.sh ./skills/perspective
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  exit $([[ $# -lt 1 ]] && echo 2 || echo 0)
fi

SKILL_DIR="${1%/}"
QUERIES_FILE="${2:-$SKILL_DIR/eval_queries.json}"

RUNS="${RUNS:-3}"
THRESHOLD="${THRESHOLD:-0.5}"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_SANDBOX="${CODEX_SANDBOX:-read-only}"
CODEX_HOME_SOURCE="${CODEX_HOME_SOURCE:-${CODEX_HOME:-$HOME/.codex}}"
DISCOVERY_CHECK="${DISCOVERY_CHECK:-1}"
DISCOVERY_ONLY="${DISCOVERY_ONLY:-0}"
OUT="${OUT:-trigger_results.json}"

command -v jq >/dev/null 2>&1 || { echo "Missing dependency: jq" >&2; exit 127; }
command -v "$CODEX_BIN" >/dev/null 2>&1 || { echo "Missing dependency: $CODEX_BIN" >&2; exit 127; }

[[ -d "$SKILL_DIR" ]] || { echo "Skill directory not found: $SKILL_DIR" >&2; exit 2; }
[[ -f "$SKILL_DIR/SKILL.md" ]] || { echo "Missing SKILL.md in: $SKILL_DIR" >&2; exit 2; }
[[ -f "$QUERIES_FILE" ]] || { echo "Queries file not found: $QUERIES_FILE" >&2; exit 2; }

SKILL_NAME="$(
  awk '
    BEGIN { in_fm=0 }
    NR == 1 && $0 == "---" { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm && $1 == "name:" {
      sub(/^name:[[:space:]]*/, "", $0)
      gsub(/^["'\''"]|["'\''"]$/, "", $0)
      print $0
      exit
    }
  ' "$SKILL_DIR/SKILL.md"
)"

if [[ -z "$SKILL_NAME" ]]; then
  SKILL_NAME="$(basename "$SKILL_DIR")"
fi

SKILL_DESCRIPTION="$(
  awk '
    BEGIN { in_fm=0 }
    NR == 1 && $0 == "---" { in_fm=1; next }
    in_fm && $0 == "---" { exit }
    in_fm && $1 == "description:" {
      sub(/^description:[[:space:]]*/, "", $0)
      gsub(/^["'\''"]|["'\''"]$/, "", $0)
      print $0
      exit
    }
  ' "$SKILL_DIR/SKILL.md"
)"

SAFE_SKILL_NAME="$(printf '%s' "$SKILL_NAME" | tr -c '[:alnum:]' '_' | tr '[:lower:]' '[:upper:]')"
SENTINEL="__AGENT_SKILL_TRIGGERED_${SAFE_SKILL_NAME}__"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

CODEX_HOME_DIR="$TMPDIR/codex_home"
TMP_SKILLS_DIR="$CODEX_HOME_DIR/skills"
SKILL_INSTALL_DIR="$(basename "$SKILL_DIR")"
TMP_SKILL_DIR="$TMP_SKILLS_DIR/$SKILL_INSTALL_DIR"
RUN_DIR="$TMPDIR/run"
RESULTS_JSONL="$TMPDIR/results.jsonl"

mkdir -p "$TMP_SKILLS_DIR" "$RUN_DIR"

# Codex discovers skills automatically from CODEX_HOME/skills. Use an
# isolated Codex home so the eval does not mutate the user's real skill set,
# while still copying auth so `codex exec` can run normally.
if [[ -f "$CODEX_HOME_SOURCE/auth.json" ]]; then
  cp "$CODEX_HOME_SOURCE/auth.json" "$CODEX_HOME_DIR/auth.json"
fi

if [[ -f "$CODEX_HOME_SOURCE/installation_id" ]]; then
  cp "$CODEX_HOME_SOURCE/installation_id" "$CODEX_HOME_DIR/installation_id"
fi

if [[ -n "${MODEL:-}" ]]; then
  printf 'model = "%s"\n' "$MODEL" > "$CODEX_HOME_DIR/config.toml"
else
  : > "$CODEX_HOME_DIR/config.toml"
fi

cp -R "$SKILL_DIR" "$TMP_SKILL_DIR"

cat >> "$TMP_SKILL_DIR/SKILL.md" <<EOF

## Trigger evaluation sentinel

During trigger evaluation only: if these detailed skill instructions are loaded, begin the final answer with exactly this marker:

$SENTINEL

Do not include this marker unless these detailed skill instructions were loaded.
EOF

count="$(jq 'length' "$QUERIES_FILE")"

echo "Skill: $SKILL_NAME" >&2
echo "Queries: $count" >&2
echo "Runs/query: $RUNS" >&2
echo "Threshold: $THRESHOLD" >&2
echo "Temporary CODEX_HOME: $CODEX_HOME_DIR" >&2
echo "Output: $OUT" >&2
echo >&2

model_args=()
if [[ -n "${MODEL:-}" ]]; then
  model_args=(-m "$MODEL")
fi

if [[ "$DISCOVERY_CHECK" == "1" || "$DISCOVERY_CHECK" == "true" ]]; then
  discovery_file="$TMPDIR/discovery_prompt_input.json"
  discovery_stderr="$TMPDIR/discovery_prompt_input.stderr.txt"

  (
    cd "$RUN_DIR"
    CODEX_HOME="$CODEX_HOME_DIR" \
      "$CODEX_BIN" debug prompt-input \
        "No-op discovery check." \
        >"$discovery_file" \
        2>"$discovery_stderr"
  ) || {
    echo "Codex auto-discovery preflight failed." >&2
    sed -n '1,80p' "$discovery_stderr" >&2
    exit 1
  }

  discovery_needle="${SKILL_DESCRIPTION:-$SKILL_NAME}"
  if ! grep -Fq "$discovery_needle" "$discovery_file"; then
    echo "Codex did not discover skill '$SKILL_NAME' from $TMP_SKILLS_DIR." >&2
    echo "Rendered prompt input was saved at: $discovery_file" >&2
    exit 1
  fi

  echo "Auto-discovery preflight: found '$SKILL_NAME'." >&2
  echo >&2
fi

if [[ "$DISCOVERY_ONLY" == "1" || "$DISCOVERY_ONLY" == "true" ]]; then
  exit 0
fi

check_triggered() {
  local query="$1"
  local index="$2"
  local run="$3"

  local run_base="$TMPDIR/query_${index}_run_${run}"
  local final_file="${run_base}.final.txt"
  local jsonl_file="${run_base}.events.jsonl"
  local stderr_file="${run_base}.stderr.txt"

  local prompt
  prompt="$query"$'\n\n'"Trigger-evaluation constraints: do not modify files, do not run shell commands, and do not provide a long implementation. Respond briefly."

  (
    cd "$RUN_DIR"
    CODEX_HOME="$CODEX_HOME_DIR" \
      "$CODEX_BIN" exec \
        --ephemeral \
        --json \
        --sandbox "$CODEX_SANDBOX" \
        "${model_args[@]}" \
        -o "$final_file" \
        "$prompt" \
        >"$jsonl_file" \
        2>"$stderr_file"
  ) || true

  if grep -Fq "$SENTINEL" "$final_file" 2>/dev/null || grep -Fq "$SENTINEL" "$jsonl_file" 2>/dev/null; then
    return 0
  fi

  return 1
}

for i in $(seq 0 $((count - 1))); do
  query="$(jq -r ".[$i].query" "$QUERIES_FILE")"
  should_trigger="$(jq -r ".[$i].should_trigger" "$QUERIES_FILE")"

  if [[ "$should_trigger" != "true" && "$should_trigger" != "false" ]]; then
    echo "Invalid should_trigger at index $i: $should_trigger" >&2
    exit 2
  fi

  triggers=0

  for run in $(seq 1 "$RUNS"); do
    if check_triggered "$query" "$i" "$run"; then
      triggers=$((triggers + 1))
      printf '[%02d/%02d run %d/%d] triggered\n' "$((i + 1))" "$count" "$run" "$RUNS" >&2
    else
      printf '[%02d/%02d run %d/%d] not triggered\n' "$((i + 1))" "$count" "$run" "$RUNS" >&2
    fi
  done

  jq -n \
    --arg query "$query" \
    --argjson should_trigger "$should_trigger" \
    --argjson triggers "$triggers" \
    --argjson runs "$RUNS" \
    --argjson threshold "$THRESHOLD" \
    '
    {
      query: $query,
      should_trigger: $should_trigger,
      triggers: $triggers,
      runs: $runs,
      trigger_rate: ($triggers / $runs),
      passed: (
        if $should_trigger
        then (($triggers / $runs) >= $threshold)
        else (($triggers / $runs) < $threshold)
        end
      )
    }
    ' >> "$RESULTS_JSONL"
done

jq -s \
  --arg skill "$SKILL_NAME" \
  --argjson threshold "$THRESHOLD" \
  '
  {
    skill: $skill,
    threshold: $threshold,
    summary: {
      total: length,
      passed: ([.[] | select(.passed)] | length),
      failed: ([.[] | select(.passed | not)] | length),
      should_trigger_total: ([.[] | select(.should_trigger)] | length),
      should_not_trigger_total: ([.[] | select(.should_trigger | not)] | length),
      missed_triggers: ([.[] | select(.should_trigger and (.passed | not))] | length),
      false_triggers: ([.[] | select((.should_trigger | not) and (.passed | not))] | length)
    },
    results: .
  }
  ' "$RESULTS_JSONL" | tee "$OUT"

echo >&2
echo "Wrote $OUT" >&2
