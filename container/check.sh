#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TARGET_HOST:-}" ]] || [[ -z "${TARGET_PORT:-}" ]]; then
  echo "Error: Required environment variables not set"
  echo "Required: TARGET_HOST, TARGET_PORT"
  echo "Optional (runs real SQL instead of just a connectivity check): DB_USER, DB_PASSWORD"
  exit 1
fi

echo "Testing TCP reachability to ${TARGET_HOST}:${TARGET_PORT}..."
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${TARGET_HOST}/${TARGET_PORT}" 2>/dev/null; then
  echo "REACHABLE: successfully opened TCP connection to ${TARGET_HOST}:${TARGET_PORT}"
else
  echo "UNREACHABLE: could not open TCP connection to ${TARGET_HOST}:${TARGET_PORT}"
  exit 1
fi

if [[ -z "${DB_USER:-}" ]] || [[ -z "${DB_PASSWORD:-}" ]]; then
  echo "SQL_SKIPPED: DB_USER/DB_PASSWORD not set, connectivity-only check complete"
  exit 0
fi

echo "Running real SQL against ${TARGET_HOST}:${TARGET_PORT}..."
export MYSQL_PWD="${DB_PASSWORD}"
SCRATCH_DB="mitigation_check_$$"
if mysql -h "${TARGET_HOST}" -P "${TARGET_PORT}" -u "${DB_USER}" --connect-timeout=5 -e "
SELECT VERSION() AS mysql_version;
SHOW DATABASES;
CREATE DATABASE ${SCRATCH_DB};
USE ${SCRATCH_DB};
CREATE TABLE ping (id INT PRIMARY KEY, note VARCHAR(100));
INSERT INTO ping VALUES (1, 'mitigation script SQL check');
SELECT * FROM ping;
DROP DATABASE ${SCRATCH_DB};
"; then
  echo "SQL_OK: successfully executed real SQL (DDL+DML+query) against ${TARGET_HOST}:${TARGET_PORT}"
else
  echo "SQL_FAILED: could not execute SQL against ${TARGET_HOST}:${TARGET_PORT}"
  exit 1
fi
