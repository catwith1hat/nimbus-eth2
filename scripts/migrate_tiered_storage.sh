#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/migrate_tiered_storage.sh <hot_db_path> <cold_db_path> --direction=<hot-to-cold|cold-to-hot>

Description:
  Moves Nimbus cold-routed kv tables between main (hot) and cold SQLite DBs.
  Rows are copied to target, then deleted from source.

Options:
  --direction=hot-to-cold   Move from main -> cold
  --direction=cold-to-hot   Move from cold -> main
USAGE
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

HOT_DB="$1"
COLD_DB="$2"
DIRECTION=""

shift 2
for arg in "$@"; do
  case "$arg" in
    --direction=hot-to-cold)
      DIRECTION="hot-to-cold"
      ;;
    --direction=cold-to-hot)
      DIRECTION="cold-to-hot"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DIRECTION" ]]; then
  echo "error: --direction is required" >&2
  usage
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "error: sqlite3 not found in PATH" >&2
  exit 1
fi

if [[ ! -f "$HOT_DB" ]]; then
  echo "error: hot DB does not exist: $HOT_DB" >&2
  exit 1
fi

mkdir -p "$(dirname "$COLD_DB")"
if [[ "$DIRECTION" == "cold-to-hot" && ! -f "$COLD_DB" ]]; then
  echo "error: cold DB does not exist for cold-to-hot mode: $COLD_DB" >&2
  exit 1
fi

# Tables routed to cold when cold storage is enabled.
TABLES=(
  blocks altair_blocks bellatrix_blocks capella_blocks deneb_blocks electra_blocks
  fulu_blocks foobar_not_real_name
  state_no_validators altair_state_no_validators bellatrix_state_no_validators
  capella_state_no_validator_pubkeys deneb_state_no_validator_pubkeys
  electra_state_no_validator_pubkeys fulu_state_no_validator_pubkeys
  more_intentional_gibberish___
  state_diffs deneb_blobs fulu_columns gloas_columns
)

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

has_table_in_schema() {
  local schema="$1"
  local table="$2"
  local cold_esc
  cold_esc="$(sql_escape "$COLD_DB")"

  local sql="
ATTACH DATABASE '${cold_esc}' AS cold;
SELECT 1 FROM ${schema}.sqlite_master WHERE type='table' AND name='${table}' LIMIT 1;
DETACH DATABASE cold;
"

  sqlite3 -batch -noheader "$HOT_DB" "$sql"
}

copy_one_table() {
  local table="$1"
  local source_schema="$2"
  local target_schema="$3"
  local cold_esc
  cold_esc="$(sql_escape "$COLD_DB")"

  local op_sql
  op_sql="
ATTACH DATABASE '${cold_esc}' AS cold;
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS ${target_schema}.\"${table}\" (
  key BLOB PRIMARY KEY,
  value BLOB
);
INSERT OR REPLACE INTO ${target_schema}.\"${table}\"(key, value)
SELECT key, value FROM ${source_schema}.\"${table}\";
DELETE FROM ${source_schema}.\"${table}\"
WHERE EXISTS (
  SELECT 1
  FROM ${target_schema}.\"${table}\" t
  WHERE t.key = ${source_schema}.\"${table}\".key
);
"

  op_sql+="
SELECT
  (SELECT COUNT(*) FROM ${source_schema}.\"${table}\") || '|' ||
  (SELECT COUNT(*) FROM ${target_schema}.\"${table}\");
COMMIT;
DETACH DATABASE cold;
"

  local counts
  counts="$(sqlite3 -batch -noheader "$HOT_DB" "$op_sql")"

  local source_count target_count
  source_count="${counts%%|*}"
  target_count="${counts##*|}"

  if [[ "$source_count" != "0" ]]; then
    echo "error: table '${table}' still has ${source_count} rows in ${source_schema} after delete" >&2
    exit 1
  fi

  echo "ok: ${table} (${source_schema}=${source_count}, ${target_schema}=${target_count})"
}

echo "hot DB : $HOT_DB"
echo "cold DB: $COLD_DB"

if [[ "$DIRECTION" == "hot-to-cold" ]]; then
  SOURCE_SCHEMA="main"
  TARGET_SCHEMA="cold"
else
  SOURCE_SCHEMA="cold"
  TARGET_SCHEMA="main"
fi

echo "direction: ${DIRECTION} (${SOURCE_SCHEMA} -> ${TARGET_SCHEMA})"
echo "mode     : move (copy+delete from source)"

for table in "${TABLES[@]}"; do
  if [[ "$(has_table_in_schema "$SOURCE_SCHEMA" "$table")" != "1" ]]; then
    echo "skip: ${table} (not present in ${SOURCE_SCHEMA})"
    continue
  fi

  copy_one_table "$table" "$SOURCE_SCHEMA" "$TARGET_SCHEMA"
done

echo "done"
