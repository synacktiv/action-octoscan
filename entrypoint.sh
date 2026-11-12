#!/usr/bin/env bash
# Installs octoscan from its GitHub releases then scans the workflows. The inputs of the action are in INPUT_* variables.
#
# Nothing of the inputs is ever evaluated by a shell: they are given to octoscan as arguments.
set -euo pipefail

REPO="${OCTOSCAN_REPO:-synacktiv/octoscan}"
VERSION="${INPUT_VERSION:-latest}"
SARIF_NAME="octoscan.sarif"

die() {
  echo "::error::$*" >&2
  exit 1
}

install_octoscan() {
  [ "$(uname -s)" = "Linux" ] || die "This action only runs on Linux runners."

  case "$(uname -m)" in
    x86_64 | amd64) asset="octoscan" ;;
    aarch64 | arm64) asset="octoscan-linux-arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac

  dir="${RUNNER_TEMP:-/tmp}/octoscan-${VERSION}"
  mkdir -p "$dir"

  # without a tag, gh downloads the latest published release
  tag=()
  if [ "$VERSION" != "latest" ]; then
    [[ "$VERSION" =~ ^v?[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?$ ]] ||
      die "Invalid version '$VERSION': use 'latest' or a release like v1.2.3."

    tag=("v${VERSION#v}")
  fi

  gh release download "${tag[@]}" --repo "$REPO" --pattern "$asset" --dir "$dir" --clobber ||
    die "Could not download octoscan ${VERSION} from $REPO."

  # the releases before the checksums existed do not have them
  if gh release download "${tag[@]}" --repo "$REPO" --pattern SHA256SUMS --dir "$dir" --clobber 2>/dev/null; then
    (cd "$dir" && grep " \*\?${asset}\$" SHA256SUMS | sha256sum -c -) ||
      die "The checksum of the downloaded octoscan does not match SHA256SUMS."
  else
    echo "::warning::This release of octoscan has no SHA256SUMS, the binary is not verified."
  fi

  chmod +x "$dir/$asset"
  mkdir -p "$dir/bin"
  mv "$dir/$asset" "$dir/bin/octoscan"
  export PATH="$dir/bin:$PATH"
}

install_octoscan

command -v shellcheck >/dev/null 2>&1 ||
  echo "::warning::shellcheck is not installed: the shellcheck rule of octoscan is skipped."

echo "Using $(octoscan --version 2>&1 | head -1)"

if [ -n "${GITHUB_WORKSPACE:-}" ]; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR:-.}" || die "The workdir '${INPUT_WORKDIR:-.}' does not exist."
fi

# --disable-rules and --enable-rules are exclusive
if [ -n "${INPUT_DISABLE_RULES:-}" ] && [ -n "${INPUT_ENABLE_RULES:-}" ]; then
  die "disable_rules and enable_rules cannot be set at the same time."
fi

args=(scan . --format sarif)

[ "${INPUT_DEBUG_RULES:-}" = "true" ] && args+=(--debug-rules)
[ "${INPUT_FILTER_RUN:-}" = "true" ] && args+=(--filter-run)
[ -n "${INPUT_FILTER_TRIGGERS:-}" ] && args+=(--filter-triggers "$INPUT_FILTER_TRIGGERS")
[ -n "${INPUT_IGNORE:-}" ] && args+=(--ignore "$INPUT_IGNORE")
[ -n "${INPUT_DISABLE_RULES:-}" ] && args+=(--disable-rules "$INPUT_DISABLE_RULES")
[ -n "${INPUT_ENABLE_RULES:-}" ] && args+=(--enable-rules "$INPUT_ENABLE_RULES")
[ -n "${INPUT_CONFIG_FILE:-}" ] && args+=(--config-file "$INPUT_CONFIG_FILE")

echo "Octoscan command: octoscan ${args[*]}"

# 0: nothing found, 2: findings (reported in the SARIF file), anything else is an error
rc=0
octoscan "${args[@]}" >"$SARIF_NAME" || rc=$?

if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  die "octoscan failed with the exit code $rc."
fi

# the path is relative to the workspace, like the other actions expect
sarif="$PWD/$SARIF_NAME"
[ -n "${GITHUB_WORKSPACE:-}" ] && sarif="${sarif#"$GITHUB_WORKSPACE"/}"

echo "sarif_output=$sarif" >>"${GITHUB_OUTPUT:-/dev/stdout}"
