# Tiered Storage

Nimbus supports a tiered storage architecture for its database, allowing you to split data between "hot" (frequently accessed) and "cold" (rarely accessed) storage. This is particularly useful for reducing the cost of running a node by storing historical data on cheaper, slower storage media (like HDD) while keeping recent, performance-critical data on fast SSDs.

## Overview

The database is split into two parts:

1.  **Hot Storage (Main Database):** Stores the most recent states, blocks, and indices required for ongoing consensus duties, block verification, and chain following. This resides in your main data directory (usually on NVMe/SSD).
2.  **Cold Storage (Attached Database):** Stores historical blocks, states, and other data that is rarely accessed (e.g., for serving sync requests to other peers). This can reside on a separate mount point (e.g., a large HDD).

## Configuration

To enable tiered storage, use the `--cold-storage-path` option when starting the beacon node.

```bash
nimbus_beacon_node \
  --data-dir=/fast/ssd/nimbus-data \
  --cold-storage-path=/slow/hdd/nimbus-cold
```

-   `--cold-storage-path`: Specifies the directory where the cold database file (`nbc_cold.sqlite3`) will be created or loaded from.

If `--cold-storage-path` is not specified, all data is stored in the main database within the data directory.

## Data Classification

| Data Type | Storage Location | Notes |
| :--- | :--- | :--- |
| **Blocks** | Cold | Historical blocks (phase0, altair, etc.) are written to cold storage. |
| **States** | Cold | State snapshots (without validator records) are written to cold storage. |
| **State Diffs** | Cold | Differential state updates. |
| **Blobs** | Cold | EIP-4844 blobs (Deneb) are stored in cold storage. |
| **Data Columns** | Cold | PeerDAS data columns (Fulu) are stored in cold storage. |
| **Indices** | Hot | Block and state indices, head/tail pointers, and metadata remain in hot storage. |
| **Validators** | Hot | Immutable validator data is kept in hot storage for fast access. |

## Migration

### New Installations

Simply start the node with `--cold-storage-path` pointing to your desired location. The node will initialize both databases and route data appropriately from the beginning.

### Existing Installations

Currently, there is no automatic migration tool to move existing data from the main database to cold storage.

*   **Option A (Recommended for fullness):** Start a fresh sync with tiered storage enabled.
*   **Option B (Hybrid):** You can enable tiered storage on an existing node. New historical data will go to cold storage, but existing data will remain in the main database. This works but won't free up space on your hot drive immediately.

## Backup

When backing up your node, ensure you backup **both** the main data directory and the cold storage directory to preserve the complete chain history.

```