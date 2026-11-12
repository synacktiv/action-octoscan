#!/usr/bin/env bash
# Tests of entrypoint.sh with a fake "gh" (the releases of octoscan) and a fake octoscan that records its arguments.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # name, condition result
  if [ "$2" = "ok" ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

mkdir -p "$TMP/stub" "$TMP/ws"

# the fake octoscan: records its arguments one per line, exits with $FAKE_RC
cat >"$TMP/octoscan.sh" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "octoscan version vTEST"; exit 0; fi
printf '%s\n' "$@" >"$ARGS_FILE"
echo '{"version":"2.1.0","runs":[]}'
exit "${FAKE_RC:-0}"
FAKE

# the fake gh: "gh release download [tag] --repo R --pattern P --dir D --clobber"
cat >"$TMP/stub/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
tag=""; pattern=""; dir=""
args=("$@")
[ "${args[0]}" = release ] && [ "${args[1]}" = download ] || exit 2
i=2
[ "${args[$i]:0:2}" != "--" ] && { tag="${args[$i]}"; i=$((i + 1)); }
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --pattern) pattern="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    --dir) dir="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    *) i=$((i + 1)) ;;
  esac
done
case "$pattern" in
  SHA256SUMS)
    [ "${NO_SUMS:-}" = 1 ] && exit 1
    (cd "$FAKE_RELEASE" && sha256sum octoscan octoscan-linux-arm64 >"$dir/SHA256SUMS")
    [ "${BAD_SUMS:-}" = 1 ] && sed -i 's/^[0-9a-f]/0/' "$dir/SHA256SUMS"
    ;;
  *) [ "${DL_FAIL:-}" = 1 ] && exit 1; cp "$FAKE_RELEASE/$pattern" "$dir/$pattern" ;;
esac
GH
chmod +x "$TMP/stub/gh"

export FAKE_RELEASE="$TMP/release" GH_LOG="$TMP/gh.log" ARGS_FILE="$TMP/args"
mkdir -p "$FAKE_RELEASE"
cp "$TMP/octoscan.sh" "$FAKE_RELEASE/octoscan"
cp "$TMP/octoscan.sh" "$FAKE_RELEASE/octoscan-linux-arm64"

# run <env assignments...>: runs the entrypoint in a clean workspace, returns its exit code
run() {
  : >"$GH_LOG"
  rm -f "$ARGS_FILE" "$TMP/out"
  RC=0
  (
    cd "$TMP/ws" || exit 99
    env -i PATH="$TMP/stub:/usr/bin:/bin" HOME="$TMP" RUNNER_TEMP="$TMP/runner" GITHUB_OUTPUT="$TMP/out" \
      FAKE_RELEASE="$FAKE_RELEASE" GH_LOG="$GH_LOG" ARGS_FILE="$ARGS_FILE" "$@" \
      bash "$ROOT/entrypoint.sh"
  ) >"$TMP/log" 2>&1 || RC=$?
}

args() { [ -f "$ARGS_FILE" ] && tr '\n' ' ' <"$ARGS_FILE"; }

# --- defaults
run INPUT_FILTER_TRIGGERS=external INPUT_FILTER_RUN=true
check "exit 0 when nothing is found" "$([ "$RC" = 0 ] && echo ok)"
check "default arguments" "$([ "$(args)" = "scan . --format sarif --filter-run --filter-triggers external " ] && echo ok)"
check "latest release is downloaded without a tag" "$(grep -q '^gh release download --repo' "$GH_LOG" && echo ok)"
check "output is set" "$([ "$(cat "$TMP/out")" = "sarif_output=octoscan.sarif" ] || [ "$(cat "$TMP/out")" = "sarif_output=$TMP/ws/octoscan.sarif" ] && echo ok)"
check "sarif is written" "$(grep -q '"version"' "$TMP/ws/octoscan.sarif" && echo ok)"

# --- the inputs are arguments, never shell code
pwned="$TMP/pwned"
evil='x"; touch '"$pwned"'; echo "'
run INPUT_IGNORE="$evil" INPUT_FILTER_TRIGGERS="\$(touch $pwned)" INPUT_ENABLE_RULES='a,b"; touch '"$pwned"
check "hostile inputs do not run" "$([ ! -e "$pwned" ] && echo ok)"
check "hostile ignore is one argument" "$(grep -qxF -- "$evil" "$ARGS_FILE" && echo ok)"
check "hostile filter_triggers is one argument" "$(grep -qxF -- "\$(touch $pwned)" "$ARGS_FILE" && echo ok)"

# --- options
run INPUT_DEBUG_RULES=true INPUT_FILTER_RUN=false INPUT_DISABLE_RULES=shellcheck,local-action INPUT_CONFIG_FILE=conf.yml
check "options" "$([ "$(args)" = "scan . --format sarif --debug-rules --disable-rules shellcheck,local-action --config-file conf.yml " ] && echo ok)"
run INPUT_FILTER_RUN=false
check "filter_run=false is not passed" "$(! grep -q filter-run "$ARGS_FILE" && echo ok)"
run INPUT_DISABLE_RULES=a INPUT_ENABLE_RULES=b
check "disable_rules and enable_rules are exclusive" "$([ "$RC" != 0 ] && echo ok)"

# --- exit codes
run FAKE_RC=2
check "findings (2) do not fail the step" "$([ "$RC" = 0 ] && echo ok)"
run FAKE_RC=1
check "a real error (1) fails the step" "$([ "$RC" != 0 ] && echo ok)"
run FAKE_RC=127
check "any other code fails the step" "$([ "$RC" != 0 ] && echo ok)"

# --- versions
run INPUT_VERSION=v1.2.3
check "a version is a tag" "$(grep -q '^gh release download v1.2.3 ' "$GH_LOG" && echo ok)"
run INPUT_VERSION=1.2.3
check "a version without v gets one" "$(grep -q '^gh release download v1.2.3 ' "$GH_LOG" && echo ok)"
run INPUT_VERSION='v1; touch '"$pwned"
check "invalid version is refused" "$([ "$RC" != 0 ] && [ ! -e "$pwned" ] && echo ok)"
run INPUT_VERSION=main
run INPUT_VERSION=v1.2.3-rc.1
check "a prerelease is a version" "$(grep -q '^gh release download v1.2.3-rc.1 ' "$GH_LOG" && echo ok)"
run INPUT_VERSION=v1.2..3\;
check "a malformed version is refused" "$([ "$RC" != 0 ] && echo ok)"
check "a branch is not a version" "$([ "$RC" != 0 ] && echo ok)"

# --- the download
run DL_FAIL=1
check "download failure fails the step" "$([ "$RC" != 0 ] && echo ok)"
run BAD_SUMS=1
check "wrong checksum fails the step" "$([ "$RC" != 0 ] && echo ok)"
run NO_SUMS=1
check "no checksum is a warning" "$([ "$RC" = 0 ] && grep -q '::warning::This release' "$TMP/log" && echo ok)"

# --- the workdir
mkdir -p "$TMP/ws/sub"
run GITHUB_WORKSPACE="$TMP/ws" INPUT_WORKDIR=sub
check "workdir: sarif path is relative to the workspace" "$([ "$(cat "$TMP/out")" = "sarif_output=sub/octoscan.sarif" ] && echo ok)"
run GITHUB_WORKSPACE="$TMP/ws" INPUT_WORKDIR=missing
check "missing workdir fails" "$([ "$RC" != 0 ] && echo ok)"

echo
if [ "$fails" = 0 ]; then
  echo "all passed"
else
  echo "$fails failed"
  exit 1
fi
