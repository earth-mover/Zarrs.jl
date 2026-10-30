# Icechunk feature parity

How the `Zarrs.Icechunk` API compares with
[icechunk-python](https://icechunk.io/en/latest/reference/) (icechunk 2.x). Priority is for
closing the gap: P1 = commonly needed, P2 = useful, P3 = niche.

| Feature | icechunk-python | Zarrs.jl | Gap priority |
|---|---|---|---|
| **Storage** | | | |
| S3 / S3-compatible | `s3_storage` | `S3Storage` (`endpoint_url`, `allow_http`, `force_path_style`) | - |
| GCS | `gcs_storage` | `GCSStorage` | - |
| Azure Blob | `azure_storage` | `AzureStorage` | - |
| Local filesystem | `local_filesystem_storage` | `LocalStorage` | - |
| In-memory | `in_memory_storage` | `MemoryStorage` | - |
| R2 / Tigris storage helpers | `r2_storage`, `tigris_storage` | use `S3Storage(endpoint_url=...)` | P3 |
| HTTP read-only storage | `http_storage` | URL pipeline only (`zopen("https://...")`, not Icechunk) | P3 |
| **Credentials** | | | |
| Static S3 keys | `s3_credentials(...)` | `S3Storage(access_key_id=...)` | - |
| Anonymous / from environment | `s3_anonymous_credentials`, `from_env` | `anonymous=true` / default | - |
| Refreshable S3 / GCS credentials | `get_credentials=callable` | `RefreshableCredentials(f)` (Julia >= 1.12) | - |
| Refreshable Azure credentials | yes | no | P3 |
| **Repository** | | | |
| create / open / open_or_create | yes | `Repository(storage; mode)` | - |
| `Repository.exists` | yes | no | P2 |
| Repository config (`RepositoryConfig`) | full object | `RepositoryConfig` (containers, inline threshold, raw fields), `repository_config(repo)` | P2 (typed caching/compression/manifest options) |
| `save_config` / `fetch_config` | yes | `save_config`; `repository_config` shows the effective config | - |
| `reopen` with new config | yes | open again with `config=` | P3 |
| Default commit metadata | `set_default_commit_metadata` | no | P3 |
| Repository metadata (`get_metadata`/`set_metadata`) | yes | no | P3 |
| Spec version upgrade (`upgrade_icechunk_repository`) | yes | no | P3 |
| **Sessions** | | | |
| Read-only by branch / tag | yes | `readonly_session(repo; branch / tag)` | - |
| Read-only by snapshot id | yes | `readonly_session(repo; snapshot_id)` | - |
| Read-only `as_of` a time | yes | `readonly_session(repo; branch, as_of)` | - |
| Writable session | yes | `writable_session` | - |
| Rearrange session (move nodes) | `rearrange_session`, `session.move` | no | P2 |
| Transaction context manager | `repo.transaction` | no (use `writable_session` + `commit`) | P3 |
| `snapshot_id`, `branch`, `read_only` | yes | `snapshot_id`, `session_branch` | - |
| Fork / merge (distributed writes) | `fork`, `merge` | no | P2 |
| Session serialization (pickle) | yes | no | P3 |
| **Creating data** | | | |
| Create groups / arrays | via zarr-python | `create_group`, `create_array`, `zopen(session, path)` | - |
| Delete nodes | via zarr-python | no | P2 |
| **Commits** | | | |
| commit with message | yes | `commit` | - |
| commit metadata | `metadata=` | `commit(...; metadata)` | - |
| amend | `session.amend` | `commit(...; amend=true)` | - |
| allow_empty | yes | `commit(...; allow_empty=true)` | - |
| flush (anonymous snapshot) | `session.flush` | no | P3 |
| rebase + conflict solvers | `rebase_with`, `BasicConflictSolver`, `ConflictDetector` | no | P2 |
| discard changes | `discard_changes` | `discard_changes` | - |
| status / has_uncommitted_changes | yes | `status`, `has_uncommitted_changes` | - |
| **Refs** | | | |
| branches: create / delete / list / lookup | yes | yes | - |
| `reset_branch` | yes | `reset_branch` | - |
| tags: create / delete / list / lookup | yes | yes | - |
| `lookup_snapshot` (snapshot info by id) | yes | no (`ancestry` gives the same fields) | P3 |
| **History** | | | |
| ancestry | yes | `ancestry(repo; branch)` | P3 (from tag / snapshot) |
| diff between versions | `repo.diff` | `diff(repo; from_*, to_*)` | - |
| ops log | `ops_log` | no | P3 |
| **Virtual chunks** | | | |
| Containers in config | `VirtualChunkContainer`, `*_store` | `VirtualChunkContainer`, `s3_store`, `gcs_store`, `http_store`, `local_filesystem_store` | - |
| Container credentials | `containers_credentials` / `authorize_virtual_chunk_access` | `Repository(...; authorize_virtual_chunk_access)` (static, anonymous, from_env) | P3 (refreshable, Azure) |
| Read virtual chunks | yes | yes (through the normal array API) | - |
| Write virtual refs | `set_virtual_ref(s)` | `set_virtual_ref` | P3 (bulk `set_virtual_refs`) |
| List virtual chunk locations | `all_virtual_chunk_locations` | `virtual_chunk_locations` | - |
| **Maintenance** | | | |
| Garbage collection | `garbage_collect` | no | P2 |
| Expire snapshots | `expire_snapshots` | no | P2 |
| Rewrite manifests / chunk storage stats | yes | no | P3 |
| **Other** | | | |
| Logging filter | `set_logs_filter` | no | P3 |
| Data types | all zarr-python types | bool, (u)int8-64, float16/32/64, complex64/128, string | P2 (`numpy.datetime64`/`timedelta64`, fixed-length bytes) |
| Arrays without zarrs' `_zarrs` attribute | n/a | default; `set_include_zarrs_metadata!` | - |

Data types: arrays with other Zarr data types (for example `numpy.datetime64`, which xarray uses
for time coordinates) cannot be opened yet; `zopen` reports the data type in an `ArgumentError`.
