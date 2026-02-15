# Tiered Storage

Nimbus supports a tiered storage layout for beacon-chain data: a hot main database and an optional cold attached database (`ATTACH DATABASE` in SQLite).

This is mainly useful when you want cheaper storage for large historical payloads while keeping latency-sensitive metadata on faster storage.

## Overview

When `--cold-storage-path` is set, Nimbus opens a second SQLite database (`nbc_cold.sqlite3`) as schema `cold` and routes selected tables there.

If `--cold-storage-path` is not set, all tables remain in the main database.

## Configuration

```bash
nimbus_beacon_node \
  --data-dir=/fast/ssd/nimbus-data \
  --cold-storage-path=/slow/hdd/nimbus-cold
```

- `--cold-storage-path`: directory where `nbc_cold.sqlite3` is created/opened.

## Data Placement And Rationale

The following reflects current routing behavior in this branch.

| Data Type / Tables | Location | Why |
| :--- | :--- | :--- |
| Blocks (`*_blocks`) | Cold | Large, append-only historical payloads; primarily used for history reconstruction/serving. |
| States without immutable validators (`*_state_no_validators*`) | Cold | Large snapshots mostly used for rewind/reindex/archive flows, not the per-slot hot path. |
| State diffs (`state_diffs`) | Cold | Compact delta records intended for storage-efficient state reconstruction/history retention. |
| Blob sidecars (`deneb_blobs`) | Cold | Large EIP-4844 payloads, mostly historical/data-serving workload. |
| Data columns (`*_columns`) | Cold | Large PeerDAS payloads, mostly historical/data-serving workload. |
| Key/value metadata (`key_values`) | Hot | Head/tail/genesis and node metadata are read frequently and should stay low-latency. |
| State-root index (`state_roots`) | Hot | High-value lookup index used to resolve state roots by `(slot, block_root)`. |
| Finalized blocks and summaries (`finalized_blocks`, `beacon_block_summaries`) | Hot | Frequently used indexing/navigation data for chain operations. |
| Immutable validator identities (`immutable_validators2`) | Hot | Needed for validator reconstruction; keeping it local avoids extra cold round-trips. |
| Light-client tables (`lc_*`) | Hot | Latency-sensitive serving path for light-client APIs. |
| Execution payload envelopes (`gloas_envelopes`) | Hot | Operational near-head access pattern. |

## FAQ

### Shouldn't state/stateDiff access be fast?

For *recent operational state*, Nimbus already prefers memory before DB:

- The DAG keeps long-lived in-memory states (head, epoch-ref, clearance).
- State advancement/replay first checks in-memory candidates, then falls back to DB.
- REST handlers optionally keep a small TTL cache of recently accessed states.

So hot-path consensus/validator work is typically not blocked on historical state table latency.

That said, heavy historical or archive-style state queries will still pay DB I/O cost. If your workload is state-history-heavy, placing cold storage on fast media can help.

### How many recent states are held in memory?

- DAG long-lived full states: 3 (`headState`, `epochRefState`, `clearanceState`).
- REST state TTL cache: configurable with `--rest-statecache-size` (default `3`) and `--rest-statecache-ttl` (default `60` seconds).
- The REST cache also only considers entries within a bounded slot distance (`5 * SLOTS_PER_EPOCH`).

Nimbus also uses `StateCache`, but that stores epoch-derived helper data (committee/proposer/sync-committee caches), not full historical state snapshots.

### What are state diffs important for?

`state_diffs` store `StateRoot -> BeaconStateDiff` and are meant to reduce storage footprint for historical state retention/reconstruction by storing deltas instead of full repeated state payloads.

In this branch, they are persisted in DB and covered by tests; they are primarily a storage/reconstruction mechanism rather than a primary near-head hot-path cache.

### How do I migrate existing data between hot and cold DBs?

Use `scripts/migrate_tiered_storage.sh` while the node is stopped.

- Move currently hot-routed rows to cold DB:

```bash
scripts/migrate_tiered_storage.sh \
  /path/to/data/nbc.sqlite3 \
  /path/to/cold/nbc_cold.sqlite3 \
  --direction=hot-to-cold
```

- Move them back from cold DB to hot DB:

```bash
scripts/migrate_tiered_storage.sh \
  /path/to/data/nbc.sqlite3 \
  /path/to/cold/nbc_cold.sqlite3 \
  --direction=cold-to-hot
```

The script migrates only cold-routed KV tables (`*_blocks`, `*_state_no_validators*`,
`state_diffs`, `deneb_blobs`, `*_columns`). It does not migrate hot-only metadata tables.

## Migration

### New installations

Start the node with `--cold-storage-path` from day one. Nimbus will initialize both DBs and route tables accordingly.

### Existing installations

There is currently no automatic migration that rewrites existing hot data into cold storage.

- Recommended: fresh sync with tiered storage enabled.
- Not currently supported as a seamless toggle for existing DBs without data copy/migration.

When cold storage is enabled, selected tables are opened against the cold schema directly.
Without migrating existing rows, historical data already present in the hot DB may not be visible via those cold-routed table handles.

## Backup

Back up both:

- main data directory (`--data-dir`)
- cold storage directory (`--cold-storage-path`)

You need both to preserve complete history and indices.
