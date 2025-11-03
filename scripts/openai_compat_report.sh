#!/usr/bin/env bash

set -euo pipefail

# OpenAI Chat Completions streaming compatibility checks using curl + jq

HOST=${HOST:-"http://localhost:1337"}

# Resolve repo root based on the location of this script; default results dir under repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${0}}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR=${OUT_DIR:-"$REPO_ROOT/results"}
mkdir -p "$OUT_DIR"

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    echo "Please install it (e.g., brew install $1) and re-run." >&2
    exit 1
  fi
}

need curl
need jq

emoji_ok='✅'
emoji_warn='⚠️'
emoji_bad='❌'

log() { printf "%s %s\n" "$1" "$2"; }

get_first_model() {
  # Query models and pick either user-provided MODEL, or 'foundation', else the first one
  local models_json
  models_json=$(curl -sS "$HOST/v1/models" || curl -sS "$HOST/models" || true)
  if [[ -z "$models_json" ]]; then
    echo ""; return
  fi
  local ids
  ids=$(jq -r '.data[]?.id // empty' <<<"$models_json")
  if [[ -n "${MODEL:-}" ]]; then
    echo "$MODEL"; return
  fi
  if grep -qx "foundation" <<<"$ids"; then
    echo "foundation"; return
  fi
  if [[ -n "$ids" ]]; then
    head -n1 <<<"$ids"
    return
  fi
  echo ""
}

filter_sse_to_jsonl() {
  # Args: <sse_body_file> <jsonl_out>
  # Extract `data: ` lines, drop [DONE], keep only valid JSON chunks as jsonl
  local sse_body="$1"
  local jsonl_out="$2"
  awk '/^data: /{print substr($0,7)}' "$sse_body" \
    | jq -Rrc 'select(. != "[DONE]") | try fromjson catch empty' > "$jsonl_out" || true
}

has_any_content_delta() {
  # Args: <jsonl_file>
  jq -e 'map(.choices[0].delta.content // empty) | join("") | length > 0' \
    <<<"$(jq -s '.' "$1")" >/dev/null 2>&1
}

last_finish_reason() {
  # Args: <jsonl_file>
  jq -r '.[-1].choices[0].finish_reason // empty' <<<"$(jq -s '.' "$1")"
}

first_role() {
  # Args: <jsonl_file>
  jq -r '.[0].choices[0].delta.role // empty' <<<"$(jq -s '.' "$1")"
}

has_tool_calls_delta() {
  # Args: <jsonl_file>
  jq -e 'map( .choices[0].delta.tool_calls[0] // empty ) | any' \
    <<<"$(jq -s '.' "$1")" >/dev/null 2>&1
}

has_tool_call_id_and_name() {
  # Args: <jsonl_file>
  jq -e 'map( .choices[0].delta.tool_calls[0] // empty )
          | map( ( .id != null ) and ( .function.name != null ) )
          | any' <<<"$(jq -s '.' "$1")" >/dev/null 2>&1
}

has_tool_call_arguments_any() {
  # Args: <jsonl_file>
  jq -e 'map( .choices[0].delta.tool_calls[0].function.arguments // empty )
          | map( (.|type) == "string" and (.|length) > 0 )
          | any' <<<"$(jq -s '.' "$1")" >/dev/null 2>&1
}

http_content_type_includes() {
  # Args: <headers_file> <needle>
  grep -i '^content-type:' "$1" | grep -qi "$2"
}

http_status_ok() {
  # Args: <headers_file>
  head -n1 "$1" | grep -qE 'HTTP/1\.[01] 200|HTTP/2 200'
}

text_streaming_test() {
  local model="$1"
  local hdrs="$TMP_DIR/text_headers.txt"
  local body="$TMP_DIR/text_body.txt"
  local jsonl="$TMP_DIR/text_chunks.jsonl"

  local payload
  payload=$(jq -nc --arg m "$model" '{model:$m, messages:[{role:"user", content:"Say hello in one short sentence."}], stream:true, temperature:0.2, max_tokens:64}')
  printf '%s\n' "$payload" > "$OUT_DIR/text_stream_request.json"

  curl -sS -N \
    -D "$hdrs" \
    -H 'Accept: text/event-stream' \
    -H 'Content-Type: application/json' \
    -X POST "$HOST/v1/chat/completions" \
    -d "$payload" \
    > "$body"

  # Basic checks
  local ok=true
  http_status_ok "$hdrs" || ok=false
  http_content_type_includes "$hdrs" 'text/event-stream' || ok=false
  grep -q '^data: \[DONE\]$' "$body" || ok=false

  # Chunk checks
  filter_sse_to_jsonl "$body" "$jsonl"
  [[ -s "$jsonl" ]] || ok=false
  # object type for all chunks
  jq -e 'all( .object == "chat.completion.chunk" )' <<<"$(jq -s '.' "$jsonl")" >/dev/null 2>&1 || ok=false
  # first delta has role: assistant
  [[ "$(first_role "$jsonl")" == "assistant" ]] || ok=false
  # content present somewhere
  has_any_content_delta "$jsonl" || ok=false
  # final finish_reason == stop
  [[ "$(last_finish_reason "$jsonl")" == "stop" ]] || ok=false

  if $ok; then
    log "$emoji_ok" "Text streaming conformance"
    echo "text_streaming=pass" > "$TMP_DIR/text_result.ini"
  else
    log "$emoji_bad" "Text streaming conformance"
    echo "text_streaming=fail" > "$TMP_DIR/text_result.ini"
  fi

  # Save artifacts
  cp "$hdrs" "$OUT_DIR/text_stream_headers.txt" || true
  cp "$body" "$OUT_DIR/text_stream_raw.txt" || true
  cp "$jsonl" "$OUT_DIR/text_stream_chunks.jsonl" || true
}

tool_call_streaming_test() {
  local model="$1"
  local hdrs="$TMP_DIR/tool_headers.txt"
  local body="$TMP_DIR/tool_body.txt"
  local jsonl="$TMP_DIR/tool_chunks.jsonl"

  # Define a simple function tool
  local tools
  tools='[{"type":"function","function":{"name":"get_weather","description":"Get weather by city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'

  local payload
  payload=$(jq -nc --arg m "$model" --argjson t "$tools" '{model:$m, messages:[{role:"user", content:"Using tools if available, get weather for city=San Francisco."}], tools:$t, tool_choice:"auto", stream:true, temperature:0.0, max_tokens:64}')
  printf '%s\n' "$payload" > "$OUT_DIR/tool_stream_request.json"

  curl -sS -N \
    -D "$hdrs" \
    -H 'Accept: text/event-stream' \
    -H 'Content-Type: application/json' \
    -X POST "$HOST/v1/chat/completions" \
    -d "$payload" \
    > "$body"

  # Basic checks
  local supported=false
  local compliant=false

  http_status_ok "$hdrs" || true
  http_content_type_includes "$hdrs" 'text/event-stream' || true
  grep -q '^data: \[DONE\]$' "$body" || true

  filter_sse_to_jsonl "$body" "$jsonl"
  if [[ -s "$jsonl" ]] && has_tool_calls_delta "$jsonl"; then
    supported=true
    # minimal conformance checks for OpenAI-style tool call streaming
    if has_tool_call_id_and_name "$jsonl" \
       && has_tool_call_arguments_any "$jsonl" \
       && [[ "$(last_finish_reason "$jsonl")" == "tool_calls" ]]; then
      compliant=true
    fi
  fi

  if $supported && $compliant; then
    log "$emoji_ok" "Tool calling streaming (OpenAI-style deltas)"
    echo "tool_streaming=pass" > "$TMP_DIR/tool_result.ini"
  elif $supported && ! $compliant; then
    log "$emoji_warn" "Tool calling streaming present but not fully compliant"
    echo "tool_streaming=partial" > "$TMP_DIR/tool_result.ini"
  else
    log "$emoji_warn" "Tool calling streaming not observed (likely unsupported by current model)"
    echo "tool_streaming=unsupported" > "$TMP_DIR/tool_result.ini"
  fi

  # Save artifacts
  cp "$hdrs" "$OUT_DIR/tool_stream_headers.txt" || true
  cp "$body" "$OUT_DIR/tool_stream_raw.txt" || true
  cp "$jsonl" "$OUT_DIR/tool_stream_chunks.jsonl" || true
}

write_report() {
  local model="$1"
  local text_status tool_status
  text_status=$(cut -d= -f2 < "$TMP_DIR/text_result.ini")
  tool_status=$(cut -d= -f2 < "$TMP_DIR/tool_result.ini" 2>/dev/null || echo "unsupported")

  local report="$OUT_DIR/openai_compat_report.md"
  {
    echo "## OpenAI Chat Completions Streaming Compatibility"
    echo "- **Server**: $HOST"
    echo "- **Model**: \
$(printf "
\`%s\`
" "$model")"
    echo ""
    echo "### Results"
    echo "| Area | Status | Notes |"
    echo "|---|---:|---|"
    case "$text_status" in
      pass) echo "| Text generation (SSE) | ✅ | Headers, SSE framing, role, finish_reason=stop |";;
      *)    echo "| Text generation (SSE) | ❌ | See artifacts in results/ |";;
    esac
    case "$tool_status" in
      pass)      echo "| Tool calling (SSE deltas) | ✅ | id/name/arguments; finish_reason=tool_calls |";;
      partial)   echo "| Tool calling (SSE deltas) | ⚠️ | Present but schema incomplete |";;
      unsupported) echo "| Tool calling (SSE deltas) | ⚠️ | Not observed; model likely lacks tool support |";;
      *)         echo "| Tool calling (SSE deltas) | ❌ | Error; see artifacts |";;
    esac
    echo ""
    echo "### Artifacts"
    echo "- \
\`results/text_stream_headers.txt\`, \
\`results/text_stream_raw.txt\`, \
\`results/text_stream_chunks.jsonl\`"
    echo "- \
\`results/tool_stream_headers.txt\`, \
\`results/tool_stream_raw.txt\`, \
\`results/tool_stream_chunks.jsonl\`"
  } > "$report"

  echo ""; echo "Report written to: $report"
}

main() {
  local model
  model=$(get_first_model)
  if [[ -z "$model" ]]; then
    echo "Could not determine a model from $HOST/v1/models. Set MODEL=... and retry." >&2
    exit 2
  fi
  echo "Using model: $model"

  text_streaming_test "$model"
  tool_call_streaming_test "$model" || true
  write_report "$model"
}

main "$@"


