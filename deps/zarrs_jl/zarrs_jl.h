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


enum ZarrsResult {
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
typedef int32_t ZarrsResult;

char *zarrsLastError(void);

void zarrsFreeString(char *s);

char *zarrsVersion(void);

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

#endif  /* ZARRS_JL_H */
