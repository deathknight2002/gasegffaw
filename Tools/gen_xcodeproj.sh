#!/usr/bin/env bash
# Wrapper for Tools/gen_xcodeproj.rb: installs the xcodeproj gem when missing, then
# runs the generator from the repo root. Any arguments are passed through
# (e.g. --check, --force-scaffold, --quiet).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v ruby >/dev/null 2>&1; then
  echo "gen_xcodeproj.sh: ruby not found (ruby >= 3.0 required)" >&2
  exit 1
fi

if ! ruby -e 'require "xcodeproj"' >/dev/null 2>&1; then
  echo "gen_xcodeproj.sh: xcodeproj gem not found, installing..." >&2
  if ! gem install xcodeproj --no-document; then
    echo "gen_xcodeproj.sh: system gem install failed, retrying with --user-install" >&2
    gem install xcodeproj --no-document --user-install
  fi
fi

exec ruby "$repo_root/Tools/gen_xcodeproj.rb" "$@"
