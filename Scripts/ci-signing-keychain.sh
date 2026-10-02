#!/bin/bash
# Dedicated signing keychain for the self-hosted TestFlight runner.
#
# Xcode cloud-managed signing (-allowProvisioningUpdates with an App Store
# Connect API key) creates certificates and private keys in the default
# keychain. On a runner service the login keychain is locked or its keys are
# not authorized for codesign, which fails with errSecInternalComponent. This
# script keeps a runner-local keychain unlocked, makes it the default for the
# build, and authorizes Apple tools to use its keys.
#
# usage: Scripts/ci-signing-keychain.sh setup|grant|restore

set -euo pipefail

state_dir="$HOME/.harness-ci"
keychain="$HOME/Library/Keychains/harness-ci.keychain-db"
password_file="$state_dir/keychain-password"
saved_default="$state_dir/saved-default-keychain"
saved_list="$state_dir/saved-keychain-list"

password() {
  cat "$password_file"
}

setup() {
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  if [ ! -f "$password_file" ]; then
    (umask 077 && openssl rand -hex 24 > "$password_file")
  fi
  if [ ! -f "$keychain" ]; then
    security create-keychain -p "$(password)" "$keychain"
  fi
  security unlock-keychain -p "$(password)" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"

  current_default="$(security default-keychain -d user | tr -d ' "')"
  if [ "$current_default" != "$keychain" ]; then
    printf '%s\n' "$current_default" > "$saved_default"
    security list-keychains -d user | tr -d ' "' | grep -vF "$keychain" > "$saved_list" || true
  fi
  # Only the CI keychain is searched during the build so Xcode cannot pick a
  # login-keychain identity whose key codesign cannot use.
  security list-keychains -d user -s "$keychain"
  security default-keychain -d user -s "$keychain"
  grant
}

grant() {
  security unlock-keychain -p "$(password)" "$keychain"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(password)" "$keychain" >/dev/null 2>&1 || true
}

restore() {
  if [ -s "$saved_list" ]; then
    # shellcheck disable=SC2046
    security list-keychains -d user -s $(cat "$saved_list")
  fi
  if [ -s "$saved_default" ]; then
    security default-keychain -d user -s "$(cat "$saved_default")"
  fi
}

case "${1:-}" in
  setup) setup ;;
  grant) grant ;;
  restore) restore ;;
  *) echo "usage: $0 setup|grant|restore" >&2; exit 2 ;;
esac
