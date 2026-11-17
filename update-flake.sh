#!/usr/bin/env bash
# Point flake.nix at the newest Ardia release that ships Linux builds.
#
# Upstream publishes Linux artifacts from its nightly channel, and not every
# nightly gets them, so this scans the release list instead of using
# /releases/latest.
#
# Usage: ./update-flake.sh [--dry-run]
#
# Env:
#   GITHUB_TOKEN   optional token, raises the GitHub API rate limit
#   ARDIA_REPO     repo to query (default: ardia-browser/ardia)
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

dry_run=0
for arg in "$@"; do
  case "$arg" in
    -n | --dry-run) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "update-flake.sh: unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v curl >/dev/null || {
  echo "update-flake.sh: curl is required" >&2
  exit 1
}
command -v nix >/dev/null || {
  echo "update-flake.sh: nix is required" >&2
  exit 1
}

repo=${ARDIA_REPO:-ardia-browser/ardia}
api="https://api.github.com/repos/$repo/releases?per_page=100"

release_json=$(mktemp)
flake_backup=$(mktemp)
cleanup() {
  rm -f "$release_json" "$flake_backup"
}
trap cleanup EXIT

curl_args=(
  --fail
  --silent
  --show-error
  --location
  --retry 3
  --retry-delay 1
  --retry-all-errors
  --connect-timeout 15
  --header "Accept: application/vnd.github+json"
)
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  curl_args+=(--header "Authorization: Bearer $GITHUB_TOKEN")
fi

echo "Fetching releases for $repo..." >&2
curl "${curl_args[@]}" "$api" --output "$release_json"

# Select the first (newest) release that has both Linux tarballs. Drafts are
# skipped; prereleases are included because Linux builds live there.
selection=$(
  RELEASE_JSON=$release_json nix eval --impure --raw --expr '
    let
      releases = builtins.fromJSON (builtins.readFile (builtins.getEnv "RELEASE_JSON"));
      hasLinux = r:
        let names = map (a: a.name) r.assets; in
        builtins.any (n: builtins.match "Ardia-.*-linux-x64\\.tar\\.xz" n != null) names
        && builtins.any (n: builtins.match "ardia-cli-.*-linux-x64\\.tar\\.gz" n != null) names;
      found = builtins.filter (r: !r.draft && hasLinux r) releases;
      tag = (builtins.head found).tag_name;
    in
      if found == [] then "" else tag + "\n" + (builtins.substring 1 (builtins.stringLength tag - 1) tag)
  '
)

if [[ -z $selection ]]; then
  echo "update-flake.sh: no release in $repo ships a Linux browser and CLI" >&2
  exit 1
fi

tag=$(printf '%s\n' "$selection" | sed -n '1p')
version=$(printf '%s\n' "$selection" | sed -n '2p')
base="https://github.com/$repo/releases/download/$tag"
browser="Ardia-$version-linux-x64.tar.xz"
cli="ardia-cli-$version-linux-x64.tar.gz"

sri_of() {
  local url=$1 hex
  hex=$(curl "${curl_args[@]}" "$url.sha256" | awk 'NR == 1 { print $1 }')
  if [[ ! $hex =~ ^[0-9a-f]{64}$ ]]; then
    echo "update-flake.sh: no valid SHA-256 sidecar for $url" >&2
    return 1
  fi
  nix hash convert --hash-algo sha256 --to sri "$hex"
}

echo "Newest Linux release: $tag" >&2
browser_hash=$(sri_of "$base/$browser")
cli_hash=$(sri_of "$base/$cli")

current_version=$(sed -n 's/^[[:space:]]*version = "\(.*\)";/\1/p' flake.nix)
echo "  version: $current_version -> $version"
echo "  browser: $browser_hash"
echo "  cli:     $cli_hash"

if ((dry_run)); then
  echo "Dry run; flake.nix not changed." >&2
  exit 0
fi

cp flake.nix "$flake_backup"

# Replace the version and the hash inside each source block.
sed -i "s|^\([[:space:]]*\)version = \".*\";|\1version = \"$version\";|" flake.nix
sed -i "/^      browserSrc = {/,/^      };/ s|hash = \".*\";|hash = \"$browser_hash\";|" flake.nix
sed -i "/^      cliSrc = {/,/^      };/ s|hash = \".*\";|hash = \"$cli_hash\";|" flake.nix

# sed can quietly miss if the flake is reformatted; make sure it didn't.
if ! grep -qF "version = \"$version\"" flake.nix \
  || ! grep -qF "hash = \"$browser_hash\"" flake.nix \
  || ! grep -qF "hash = \"$cli_hash\"" flake.nix; then
  echo "update-flake.sh: could not rewrite flake.nix; restoring it" >&2
  mv "$flake_backup" flake.nix
  exit 1
fi

if ! check_output=$(nix flake check --no-build 2>&1); then
  printf '%s\n' "$check_output" >&2
  echo "update-flake.sh: nix flake check failed; restoring flake.nix" >&2
  mv "$flake_backup" flake.nix
  exit 1
fi

echo "Updated flake.nix to $tag. Build with: nix build .#ardia" >&2
