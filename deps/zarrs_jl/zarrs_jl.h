#ifndef ZARRS_JL_H
#define ZARRS_JL_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Opaque handle types — allocated and managed by libzarrs_jl.
 * Callers interact with these only via pointers.
 */
typedef struct StorageHandle StorageHandle;
typedef struct ArrayHandle ArrayHandle;
typedef struct GroupHandle GroupHandle;
typedef struct IcStorageHandle IcStorageHandle;
typedef struct IcRepoHandle IcRepoHandle;
typedef struct IcSessionHandle IcSessionHandle;


enum ZarrsResult
#if __STDC_VERSION__ >= 202311L
  : int32_t
#endif // __STDC_VERSION__ >= 202311L
 {
  ZARRS_SUCCESS = 0,
  ZARRS_ERROR_NULL_PTR = -1,
  ZARRS_ERROR_STORAGE = -2,
  ZARRS_ERROR_ARRAY = -3,
  ZARRS_ERROR_BUFFER_LENGTH = -4,
  ZARRS_ERROR_INVALID_INDICES = -5,
  ZARRS_ERROR_NODE_PATH = -6,
  ZARRS_ERROR_STORE_PREFIX = -7,
  ZARRS_ERROR_INVALID_METADATA = -8,
  ZARRS_ERROR_STORAGE_CAPABILITY = -9,
  ZARRS_ERROR_UNKNOWN_CHUNK_GRID_SHAPE = -10,
  ZARRS_ERROR_UNKNOWN_INTERSECTING_CHUNKS = -11,
  ZARRS_ERROR_UNSUPPORTED_DATA_TYPE = -12,
  ZARRS_ERROR_GROUP = -13,
  ZARRS_ERROR_INCOMPATIBLE_DIMENSIONALITY = -14,
};
#if __STDC_VERSION__ >= 202311L
typedef enum ZarrsResult ZarrsResult;
#else
typedef int32_t ZarrsResult;
#endif // __STDC_VERSION__ >= 202311L

char *zarrsLastError(void);

void zarrsFreeString(char *s);

char *zarrsVersion(void);

/**
 * Whether array metadata written from now on includes zarrs' `_zarrs` attribute (the zarrs
 * version and a description of the codec pipeline). zarrs' default is on; Zarrs.jl turns it
 * off when it loads, see `Zarrs.set_include_zarrs_metadata!`.
 */
ZarrsResult zarrsSetIncludeZarrsMetadata(int32_t include);

ZarrsResult zarrsGetIncludeZarrsMetadata(int32_t *pInclude);

ZarrsResult zarrsCreateStorageFilesystem(const char *path, StorageHandle **pStorage);

ZarrsResult zarrsCreateStorageHTTP(const char *url, StorageHandle **pStorage);

ZarrsResult zarrsCreateStorageS3(const char *bucket,
                                 const char *prefix,
                                 const char *region,
                                 const char *endpoint_url,
                                 int32_t anonymous,
                                 StorageHandle **pStorage);

ZarrsResult zarrsCreateStorageGCS(const char *bucket,
                                  const char *prefix,
                                  int32_t anonymous,
                                  StorageHandle **pStorage);

ZarrsResult zarrsDestroyStorage(StorageHandle *storage);

ZarrsResult zarrsCreateArrayRW(StorageHandle *storage,
                               const char *path,
                               const char *metadata_json,
                               ArrayHandle **pArray);

ZarrsResult zarrsOpenArrayRW(StorageHandle *storage, const char *path, ArrayHandle **pArray);

ZarrsResult zarrsDestroyArray(ArrayHandle *array);

ZarrsResult zarrsArrayGetDimensionality(ArrayHandle *array, uintptr_t *pDimensionality);

ZarrsResult zarrsArrayGetShape(ArrayHandle *array, uintptr_t dimensionality, uint64_t *pShape);

ZarrsResult zarrsArrayGetDataType(ArrayHandle *array, int32_t *pDataType);

ZarrsResult zarrsArrayGetMetadataString(ArrayHandle *array, int32_t pretty, char **pMetadata);

ZarrsResult zarrsArrayGetAttributes(ArrayHandle *array, int32_t pretty, char **pAttributes);

ZarrsResult zarrsArraySetAttributes(ArrayHandle *array, const char *attributes);

ZarrsResult zarrsArrayStoreMetadata(ArrayHandle *array);

ZarrsResult zarrsArrayGetSubsetSize(ArrayHandle *array,
                                    uintptr_t dimensionality,
                                    const uint64_t *pSubsetShape,
                                    uintptr_t *pSubsetSize);

ZarrsResult zarrsArrayRetrieveSubset(ArrayHandle *array,
                                     uintptr_t dimensionality,
                                     const uint64_t *pSubsetStart,
                                     const uint64_t *pSubsetShape,
                                     uintptr_t subsetBytesCount,
                                     uint8_t *pSubsetBytes);

ZarrsResult zarrsArrayStoreSubset(ArrayHandle *array,
                                  uintptr_t dimensionality,
                                  const uint64_t *pSubsetStart,
                                  const uint64_t *pSubsetShape,
                                  uintptr_t subsetBytesCount,
                                  const uint8_t *pSubsetBytes);

ZarrsResult zarrsArrayGetChunkGridShape(ArrayHandle *array,
                                        uintptr_t dimensionality,
                                        uint64_t *pChunkGridShape);

ZarrsResult zarrsArrayGetChunkSize(ArrayHandle *array,
                                   uintptr_t dimensionality,
                                   const uint64_t *pChunkIndices,
                                   uintptr_t *pChunkSize);

ZarrsResult zarrsArrayRetrieveChunk(ArrayHandle *array,
                                    uintptr_t dimensionality,
                                    const uint64_t *pChunkIndices,
                                    uintptr_t chunkBytesCount,
                                    uint8_t *pChunkBytes);

ZarrsResult zarrsArrayStoreChunk(ArrayHandle *array,
                                 uintptr_t dimensionality,
                                 const uint64_t *pChunkIndices,
                                 uintptr_t chunkBytesCount,
                                 const uint8_t *pChunkBytes);

ZarrsResult zarrsArrayGetChunkOrigin(ArrayHandle *array,
                                     uintptr_t dimensionality,
                                     const uint64_t *pChunkIndices,
                                     uint64_t *pChunkOrigin);

ZarrsResult zarrsArrayGetChunkShape(ArrayHandle *array,
                                    uintptr_t dimensionality,
                                    const uint64_t *pChunkIndices,
                                    uint64_t *pChunkShape);

ZarrsResult zarrsArrayGetSubChunkShape(ArrayHandle *array,
                                       uintptr_t dimensionality,
                                       int32_t *pIsSharded,
                                       uint64_t *pSubChunkShape);

ZarrsResult zarrsCreateGroupRW(StorageHandle *storage,
                               const char *path,
                               const char *metadata_json,
                               GroupHandle **pGroup);

ZarrsResult zarrsOpenGroupRW(StorageHandle *storage, const char *path, GroupHandle **pGroup);

ZarrsResult zarrsDestroyGroup(GroupHandle *group);

ZarrsResult zarrsGroupGetAttributes(GroupHandle *group, int32_t pretty, char **pAttributes);

ZarrsResult zarrsGroupSetAttributes(GroupHandle *group, const char *attributes);

ZarrsResult zarrsGroupStoreMetadata(GroupHandle *group);

/**
 * Resize an array.
 */
ZarrsResult zarrsJlArrayResize(StorageHandle *storage,
                               const char *path,
                               uintptr_t ndim,
                               const uint64_t *new_shape);

/**
 * List directory children, returning a JSON array of strings.
 */
ZarrsResult zarrsJlStorageListDir(StorageHandle *storage, const char *path, char **json_out);

/**
 * Read a single key from storage, returning its bytes as a C string.
 * Returns ZARRS_SUCCESS with null output if the key is not found.
 */
ZarrsResult zarrsJlStorageGet(StorageHandle *storage, const char *key, char **data_out);

/**
 * Erase a specific chunk from an array.
 */
ZarrsResult zarrsJlArrayEraseChunk(StorageHandle *storage,
                                   const char *path,
                                   uintptr_t ndim,
                                   const uint64_t *indices);

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkS3Storage(const char *bucket,
                                   const char *prefix,
                                   const char *region,
                                   int32_t anonymous,
                                   const char *endpoint_url,
                                   int32_t allow_http,
                                   const char *access_key_id,
                                   const char *secret_access_key,
                                   const char *session_token,
                                   IcStorageHandle **pHandle);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkGcsStorage(const char *bucket,
                                    const char *prefix,
                                    int32_t credential_type,
                                    const char *credential_value,
                                    IcStorageHandle **pHandle);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * S3 storage whose credentials come from a Julia function (refreshed by icechunk before they
 * expire). `callback_id` identifies the function in Zarrs.jl's credential registry; see
 * `credentials.rs` for how the function is called without running Julia on Tokio threads.
 */
ZarrsResult zarrsIcechunkS3StorageRefreshable(const char *bucket,
                                              const char *prefix,
                                              const char *region,
                                              const char *endpoint_url,
                                              int32_t allow_http,
                                              int32_t force_path_style,
                                              uint64_t callback_id,
                                              IcStorageHandle **pHandle);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * GCS storage whose bearer token comes from a Julia function (see
 * `zarrsIcechunkS3StorageRefreshable`).
 */
ZarrsResult zarrsIcechunkGcsStorageRefreshable(const char *bucket,
                                               const char *prefix,
                                               uint64_t callback_id,
                                               IcStorageHandle **pHandle);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkAzureStorage(const char *account,
                                      const char *container,
                                      const char *prefix,
                                      int32_t credential_type,
                                      const char *credential_value,
                                      IcStorageHandle **pHandle);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkLocalStorage(const char *path, IcStorageHandle **pHandle);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkMemoryStorage(IcStorageHandle **pHandle);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkDestroyStorage(IcStorageHandle *handle);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoOpen(IcStorageHandle *ic_storage, IcRepoHandle **pRepo);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoCreate(IcStorageHandle *ic_storage, IcRepoHandle **pRepo);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoOpenOrCreate(IcStorageHandle *ic_storage, IcRepoHandle **pRepo);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkDestroyRepo(IcRepoHandle *repo);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoListBranches(IcRepoHandle *repo, char **pJson);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoListTags(IcRepoHandle *repo, char **pJson);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoCreateBranch(IcRepoHandle *repo,
                                          const char *name,
                                          const char *snapshot_id_str,
                                          char **pResult);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoDeleteBranch(IcRepoHandle *repo, const char *name);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoCreateTag(IcRepoHandle *repo,
                                       const char *name,
                                       const char *snapshot_id_str,
                                       char **pResult);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoDeleteTag(IcRepoHandle *repo, const char *name);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoLookupBranch(IcRepoHandle *repo, const char *name, char **pSnapshotId);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkRepoLookupTag(IcRepoHandle *repo, const char *name, char **pSnapshotId);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Create a readonly session.
 * `version_type`: 0 = branch, 1 = tag, 2 = snapshot_id
 * `version_value`: the branch name, tag name, or snapshot ID string
 */
ZarrsResult zarrsIcechunkReadonlySession(IcRepoHandle *repo,
                                         int32_t version_type,
                                         const char *version_value,
                                         IcSessionHandle **pSession);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Create a writable session on a branch.
 */
ZarrsResult zarrsIcechunkWritableSession(IcRepoHandle *repo,
                                         const char *branch,
                                         IcSessionHandle **pSession);
#endif

#if defined(ZARRS_ICECHUNK)
ZarrsResult zarrsIcechunkDestroySession(IcSessionHandle *session);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Create a zarrs-compatible StorageHandle from an Icechunk session.
 * This bridges the Icechunk Store to the zarrs sync storage interface.
 */
ZarrsResult zarrsIcechunkSessionGetStorage(IcSessionHandle *session, StorageHandle **pStorage);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Check if a session is read-only.
 */
ZarrsResult zarrsIcechunkSessionReadOnly(IcSessionHandle *session, int32_t *pReadOnly);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Commit a writable session with a message, returning a snapshot ID string.
 */
ZarrsResult zarrsIcechunkSessionCommit(IcSessionHandle *session,
                                       const char *message,
                                       char **pSnapshotId);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Check if a session has uncommitted changes.
 */
ZarrsResult zarrsIcechunkSessionHasChanges(IcSessionHandle *session, int32_t *pHasChanges);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Commit a writable session with a message and snapshot metadata (`metadata_json`, a JSON
 * object, or null for none), returning the snapshot ID string.
 */
ZarrsResult zarrsIcechunkSessionCommitWithMetadata(IcSessionHandle *session,
                                                   const char *message,
                                                   const char *metadata_json,
                                                   char **pSnapshotId);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * The ancestry of a branch, newest first, as a JSON array of
 * `{"id", "parent_id", "written_at", "message", "metadata"}` (`written_at` is RFC 3339, UTC).
 */
ZarrsResult zarrsIcechunkRepoAncestry(IcRepoHandle *repo, const char *branch, char **pJson);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Create a readonly session on the last snapshot of `branch` written at or before `at`
 * (an RFC 3339 timestamp).
 */
ZarrsResult zarrsIcechunkReadonlySessionAsOf(IcRepoHandle *repo,
                                             const char *branch,
                                             const char *at,
                                             IcSessionHandle **pSession);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * The snapshot a session is based on (its branch tip when it was opened, or the snapshot it
 * reads).
 */
ZarrsResult zarrsIcechunkSessionSnapshotId(IcSessionHandle *session, char **pSnapshotId);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * The branch of a session, or an empty string for a session that is not on a branch.
 */
ZarrsResult zarrsIcechunkSessionBranch(IcSessionHandle *session, char **pBranch);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Drop all uncommitted changes of a writable session.
 */
ZarrsResult zarrsIcechunkSessionDiscardChanges(IcSessionHandle *session);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Commit with options: `metadata_json` (a JSON object, or null), `amend` (replace the branch
 * tip instead of adding a snapshot on top of it) and `allow_empty` (commit even without
 * changes). Returns the new snapshot ID.
 */
ZarrsResult zarrsIcechunkSessionCommitWithOptions(IcSessionHandle *session,
                                                  const char *message,
                                                  const char *metadata_json,
                                                  int32_t amend,
                                                  int32_t allow_empty,
                                                  char **pSnapshotId);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * The uncommitted changes of a session, as a JSON diff object.
 */
ZarrsResult zarrsIcechunkSessionStatus(IcSessionHandle *session, char **pJson);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * The changes between two versions (`from` excluded, `to` included), as a JSON diff object.
 * `*_kind`: 0 = branch tip, 1 = tag, 2 = snapshot ID.
 */
ZarrsResult zarrsIcechunkRepoDiff(IcRepoHandle *repo,
                                  int32_t from_kind,
                                  const char *from_value,
                                  int32_t to_kind,
                                  const char *to_value,
                                  char **pJson);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Point `branch` at `snapshot_id` (any snapshot, not only an ancestor).
 */
ZarrsResult zarrsIcechunkRepoResetBranch(IcRepoHandle *repo,
                                         const char *branch,
                                         const char *snapshot_id);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Open (`mode` 0), create (1) or open-or-create (2) a repository with a configuration and
 * virtual chunk credentials.
 *
 * `config_json`: an icechunk `RepositoryConfig` as JSON (its serde form, e.g.
 * `{"inline_chunk_threshold_bytes": 512, "virtual_chunk_containers": {...}}`), or null. On
 * open, it is merged over the configuration stored in the repository.
 * `credentials_json`: a JSON object mapping virtual chunk container URL prefixes to icechunk
 * `Credentials` (serde form) or `null`, or null for none. Containers not listed cannot be read.
 */
ZarrsResult zarrsIcechunkRepoOpenWithConfig(IcStorageHandle *ic_storage,
                                            int32_t mode,
                                            const char *config_json,
                                            const char *credentials_json,
                                            IcRepoHandle **pRepo);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * The repository's configuration (stored configuration merged with the one it was opened
 * with) as JSON.
 */
ZarrsResult zarrsIcechunkRepoConfig(IcRepoHandle *repo, char **pJson);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Persist the repository's current configuration (e.g. its virtual chunk containers) in the
 * repository, so later opens use it.
 */
ZarrsResult zarrsIcechunkRepoSaveConfig(IcRepoHandle *repo);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Point the chunk at store key `key` (e.g. `"array/c/0/1"`) to `length` bytes at `offset` in
 * the object at `location` (a URL inside a virtual chunk container). `etag` (or null) and
 * `last_modified` (seconds since the epoch, or 0) guard against the object changing: reads
 * fail if it no longer matches. With `validate_container` set, the location must belong to a
 * container declared in the repository configuration.
 */
ZarrsResult zarrsIcechunkSessionSetVirtualRef(IcSessionHandle *session,
                                              const char *key,
                                              const char *location,
                                              uint64_t offset,
                                              uint64_t length,
                                              const char *etag,
                                              uint32_t last_modified,
                                              int32_t validate_container);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * All virtual chunk locations referenced by the session's snapshot, as a JSON array of URLs.
 */
ZarrsResult zarrsIcechunkSessionVirtualChunkLocations(IcSessionHandle *session, char **pJson);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Register the `uv_async_t` (from `Base.AsyncCondition`) and `uv_async_send` used to wake the
 * Julia credential service. Passing the function pointer avoids linking against libuv.
 */
ZarrsResult zarrsCredentialsSetNotifier(void *handle, void *uv_async_send);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Seconds a fetcher waits for Julia before failing (default 120).
 */
ZarrsResult zarrsCredentialsSetTimeout(uint64_t seconds);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Take one pending request into the outputs; request id 0 means the queue was empty.
 */
ZarrsResult zarrsCredentialsTakeRequest(uint64_t *pRequestId, uint64_t *pCallbackId);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Answer an S3 request. `expires_after` is seconds since the Unix epoch (NaN or <= 0: never).
 */
ZarrsResult zarrsCredentialsProvideS3(uint64_t request_id,
                                      const char *access_key_id,
                                      const char *secret_access_key,
                                      const char *session_token,
                                      double expires_after);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Answer a GCS request with a bearer token. `expires_after` as for `zarrsCredentialsProvideS3`.
 */
ZarrsResult zarrsCredentialsProvideGcs(uint64_t request_id,
                                       const char *bearer,
                                       double expires_after);
#endif

#if defined(ZARRS_ICECHUNK)
/**
 * Answer a request with an error (for example, the Julia function threw).
 */
ZarrsResult zarrsCredentialsProvideError(uint64_t request_id, const char *message);
#endif

#endif  /* ZARRS_JL_H */
