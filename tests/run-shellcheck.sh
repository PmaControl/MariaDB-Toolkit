#!/usr/bin/env bash
set -euo pipefail

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed"
  exit 0
fi

shellcheck /srv/www/pma-mariadb-toolkit/mariadb_storage_audit.sh
