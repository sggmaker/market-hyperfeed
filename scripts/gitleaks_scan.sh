#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="8.30.1"
archive="gitleaks_${version}_linux_x64.tar.gz"
archive_sha256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
url="https://github.com/gitleaks/gitleaks/releases/download/v${version}/${archive}"
download_tmp=""
current_tree=""

cleanup() {
  if [[ -n "$download_tmp" ]]; then
    rm -rf "$download_tmp"
  fi
  if [[ -n "$current_tree" ]]; then
    rm -rf "$current_tree"
  fi
}
trap cleanup EXIT

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks_bin="$(command -v gitleaks)"
else
  machine="$(uname -m)"
  system="$(uname -s)"
  if [[ "$system" != "Linux" || "$machine" != "x86_64" ]]; then
    echo "gitleaks auto-install supports Linux x86_64; install gitleaks manually for $system/$machine" >&2
    exit 127
  fi
  cache_root="${XDG_CACHE_HOME:-${HOME:-/tmp/.cache}}/market-hyperfeed/gitleaks/v${version}"
  gitleaks_bin="$cache_root/gitleaks"
  if [[ ! -x "$gitleaks_bin" ]]; then
    download_tmp="$(mktemp -d)"
    curl -fsSL "$url" -o "$download_tmp/$archive"
    printf '%s  %s\n' "$archive_sha256" "$download_tmp/$archive" | sha256sum -c -
    mkdir -p "$cache_root"
    tar -xzf "$download_tmp/$archive" -C "$download_tmp" gitleaks
    install -m 0755 "$download_tmp/gitleaks" "$gitleaks_bin"
  fi
fi

current_tree="$(mktemp -d)"

cd "$repo_root"
while IFS= read -r -d '' file; do
  mkdir -p "$current_tree/$(dirname "$file")"
  cp "$file" "$current_tree/$file"
done < <(git ls-files -z)

"$gitleaks_bin" dir "$current_tree" --redact --exit-code 1 --no-banner
"$gitleaks_bin" git "$repo_root" --redact --exit-code 1 --no-banner
