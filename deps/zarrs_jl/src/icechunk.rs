use std::ffi::CString;
use std::ffi::c_char;
use std::sync::Arc;

use super::{
    set_error, str_from_ptr, IcechunkAdapter, StorageHandle, TokioBlockOn, ZarrsResult,
};

use zarrs_storage::storage_adapter::async_to_sync::AsyncToSyncStorageAdapter;

// ---------------------------------------------------------------------------
// Opaque handles
// ---------------------------------------------------------------------------

/// Handle wrapping Icechunk object-store storage + a Tokio runtime.
pub struct IcStorageHandle {
    pub storage: Arc<dyn icechunk::storage::Storage + Send + Sync>,
    pub runtime: Arc<tokio::runtime::Runtime>,
}

/// Handle wrapping an Icechunk Repository.
pub struct IcRepoHandle {
    pub repo: icechunk::Repository,
    pub runtime: Arc<tokio::runtime::Runtime>,
}

/// Handle wrapping an Icechunk Session and its Store (zarr-compatible).
pub struct IcSessionHandle {
    pub store: icechunk::Store,
    pub runtime: Arc<tokio::runtime::Runtime>,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_runtime() -> Result<Arc<tokio::runtime::Runtime>, String> {
    tokio::runtime::Runtime::new()
        .map(Arc::new)
        .map_err(|e| format!("Failed to create tokio runtime: {e}"))
}

fn opt_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    match str_from_ptr(ptr) {
        Ok(s) if s.is_empty() => None,
        Ok(s) => Some(s.to_string()),
        Err(_) => None,
    }
}

// ---------------------------------------------------------------------------
// Storage creation
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkS3Storage(
    bucket: *const c_char,
    prefix: *const c_char,
    region: *const c_char,
    anonymous: i32,
    endpoint_url: *const c_char,
    allow_http: i32,
    pHandle: *mut *mut IcStorageHandle,
) -> ZarrsResult {
    if pHandle.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let bucket_str = match str_from_ptr(bucket) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let prefix_opt = opt_string(prefix);
    let region_opt = opt_string(region);
    let endpoint_opt = opt_string(endpoint_url);

    let runtime = match make_runtime() {
        Ok(rt) => rt,
        Err(msg) => {
            set_error(msg);
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let s3_opts = icechunk::config::S3Options {
        region: region_opt,
        endpoint_url: endpoint_opt,
        anonymous: anonymous != 0,
        allow_http: allow_http != 0,
        force_path_style: false,
        network_stream_timeout_seconds: Some(30),
        requester_pays: false,
    };

    let credentials = if anonymous != 0 {
        Some(icechunk::config::S3Credentials::Anonymous)
    } else {
        Some(icechunk::config::S3Credentials::FromEnv)
    };

    match icechunk::new_s3_storage(s3_opts, bucket_str, prefix_opt, credentials) {
        Ok(storage) => {
            let handle = Box::new(IcStorageHandle { storage, runtime });
            unsafe { *pHandle = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(format!("S3 storage error: {e}"));
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkGcsStorage(
    bucket: *const c_char,
    prefix: *const c_char,
    pHandle: *mut *mut IcStorageHandle,
) -> ZarrsResult {
    if pHandle.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let bucket_str = match str_from_ptr(bucket) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let prefix_opt = opt_string(prefix);

    let runtime = match make_runtime() {
        Ok(rt) => rt,
        Err(msg) => {
            set_error(msg);
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let result = runtime.block_on(async {
        icechunk::storage::new_gcs_storage(bucket_str, prefix_opt, None, None)
            .await
            .map_err(|e| format!("GCS storage error: {e}"))
    });

    match result {
        Ok(storage) => {
            let handle = Box::new(IcStorageHandle { storage, runtime });
            unsafe { *pHandle = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkAzureStorage(
    account: *const c_char,
    container: *const c_char,
    prefix: *const c_char,
    pHandle: *mut *mut IcStorageHandle,
) -> ZarrsResult {
    if pHandle.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let account_str = match str_from_ptr(account) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let container_str = match str_from_ptr(container) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let prefix_opt = opt_string(prefix);

    let runtime = match make_runtime() {
        Ok(rt) => rt,
        Err(msg) => {
            set_error(msg);
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let result = runtime.block_on(async {
        icechunk::storage::new_azure_blob_storage(account_str, container_str, prefix_opt, None, None)
            .await
            .map_err(|e| format!("Azure storage error: {e}"))
    });

    match result {
        Ok(storage) => {
            let handle = Box::new(IcStorageHandle { storage, runtime });
            unsafe { *pHandle = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkLocalStorage(
    path: *const c_char,
    pHandle: *mut *mut IcStorageHandle,
) -> ZarrsResult {
    if pHandle.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let path_str = match str_from_ptr(path) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let runtime = match make_runtime() {
        Ok(rt) => rt,
        Err(msg) => {
            set_error(msg);
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let result = runtime.block_on(async {
        icechunk::storage::new_local_filesystem_storage(std::path::Path::new(&path_str))
            .await
            .map_err(|e| format!("Local storage error: {e}"))
    });

    match result {
        Ok(storage) => {
            let handle = Box::new(IcStorageHandle { storage, runtime });
            unsafe { *pHandle = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkMemoryStorage(
    pHandle: *mut *mut IcStorageHandle,
) -> ZarrsResult {
    if pHandle.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let runtime = match make_runtime() {
        Ok(rt) => rt,
        Err(msg) => {
            set_error(msg);
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let result = runtime.block_on(async {
        icechunk::storage::new_in_memory_storage()
            .await
            .map_err(|e| format!("Memory storage error: {e}"))
    });

    match result {
        Ok(storage) => {
            let handle = Box::new(IcStorageHandle { storage, runtime });
            unsafe { *pHandle = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkDestroyStorage(
    handle: *mut IcStorageHandle,
) -> ZarrsResult {
    if handle.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    unsafe { drop(Box::from_raw(handle)) };
    ZarrsResult::ZARRS_SUCCESS
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoOpen(
    ic_storage: *mut IcStorageHandle,
    pRepo: *mut *mut IcRepoHandle,
) -> ZarrsResult {
    if ic_storage.is_null() || pRepo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let ic = unsafe { &*ic_storage };
    let storage = ic.storage.clone();
    let runtime = ic.runtime.clone();

    let result = runtime.block_on(async {
        icechunk::Repository::open(None, storage, std::collections::HashMap::new())
            .await
            .map_err(|e| format!("Repository open error: {e}"))
    });

    match result {
        Ok(repo) => {
            let handle = Box::new(IcRepoHandle { repo, runtime });
            unsafe { *pRepo = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoCreate(
    ic_storage: *mut IcStorageHandle,
    pRepo: *mut *mut IcRepoHandle,
) -> ZarrsResult {
    if ic_storage.is_null() || pRepo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let ic = unsafe { &*ic_storage };
    let storage = ic.storage.clone();
    let runtime = ic.runtime.clone();

    let result = runtime.block_on(async {
        icechunk::Repository::create(None, storage, std::collections::HashMap::new())
            .await
            .map_err(|e| format!("Repository create error: {e}"))
    });

    match result {
        Ok(repo) => {
            let handle = Box::new(IcRepoHandle { repo, runtime });
            unsafe { *pRepo = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoOpenOrCreate(
    ic_storage: *mut IcStorageHandle,
    pRepo: *mut *mut IcRepoHandle,
) -> ZarrsResult {
    if ic_storage.is_null() || pRepo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let ic = unsafe { &*ic_storage };
    let storage = ic.storage.clone();
    let runtime = ic.runtime.clone();

    let result = runtime.block_on(async {
        icechunk::Repository::open_or_create(None, storage, std::collections::HashMap::new())
            .await
            .map_err(|e| format!("Repository open_or_create error: {e}"))
    });

    match result {
        Ok(repo) => {
            let handle = Box::new(IcRepoHandle { repo, runtime });
            unsafe { *pRepo = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkDestroyRepo(
    repo: *mut IcRepoHandle,
) -> ZarrsResult {
    if repo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    unsafe { drop(Box::from_raw(repo)) };
    ZarrsResult::ZARRS_SUCCESS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoListBranches(
    repo: *mut IcRepoHandle,
    pJson: *mut *mut c_char,
) -> ZarrsResult {
    if repo.is_null() || pJson.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let rh = unsafe { &*repo };
    let result = rh.runtime.block_on(async {
        rh.repo
            .list_branches()
            .await
            .map_err(|e| format!("list_branches error: {e}"))
    });

    match result {
        Ok(branches) => {
            let vec: Vec<&str> = branches.iter().map(|s| s.as_str()).collect();
            let json = serde_json::to_string(&vec).unwrap_or_else(|_| "[]".to_string());
            match CString::new(json) {
                Ok(cstr) => {
                    unsafe { *pJson = cstr.into_raw() };
                    ZarrsResult::ZARRS_SUCCESS
                }
                Err(e) => {
                    set_error(e.to_string());
                    ZarrsResult::ZARRS_ERROR_STORAGE
                }
            }
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoListTags(
    repo: *mut IcRepoHandle,
    pJson: *mut *mut c_char,
) -> ZarrsResult {
    if repo.is_null() || pJson.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let rh = unsafe { &*repo };
    let result = rh.runtime.block_on(async {
        rh.repo
            .list_tags()
            .await
            .map_err(|e| format!("list_tags error: {e}"))
    });

    match result {
        Ok(tags) => {
            let vec: Vec<&str> = tags.iter().map(|s| s.as_str()).collect();
            let json = serde_json::to_string(&vec).unwrap_or_else(|_| "[]".to_string());
            match CString::new(json) {
                Ok(cstr) => {
                    unsafe { *pJson = cstr.into_raw() };
                    ZarrsResult::ZARRS_SUCCESS
                }
                Err(e) => {
                    set_error(e.to_string());
                    ZarrsResult::ZARRS_ERROR_STORAGE
                }
            }
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// Create a readonly session.
/// `version_type`: 0 = branch, 1 = tag, 2 = snapshot_id
/// `version_value`: the branch name, tag name, or snapshot ID string
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkReadonlySession(
    repo: *mut IcRepoHandle,
    version_type: i32,
    version_value: *const c_char,
    pSession: *mut *mut IcSessionHandle,
) -> ZarrsResult {
    if repo.is_null() || pSession.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let version_str = match str_from_ptr(version_value) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let version = match version_type {
        0 => icechunk::repository::VersionInfo::BranchTipRef(version_str),
        1 => icechunk::repository::VersionInfo::TagRef(version_str),
        2 => {
            // SnapshotId doesn't implement FromStr; snapshot access via ID
            // is not yet supported in the Julia bindings.
            set_error("Snapshot ID access not yet supported; use branch or tag".to_string());
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
        _ => {
            set_error(format!("Invalid version_type: {version_type}"));
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let rh = unsafe { &*repo };
    let runtime = rh.runtime.clone();

    let result = runtime.block_on(async {
        let session = rh
            .repo
            .readonly_session(&version)
            .await
            .map_err(|e| format!("readonly_session error: {e}"))?;

        let session_arc = Arc::new(tokio::sync::RwLock::new(session));
        let store = icechunk::Store::from_session(session_arc).await;
        Ok::<_, String>(store)
    });

    match result {
        Ok(store) => {
            let handle = Box::new(IcSessionHandle { store, runtime });
            unsafe { *pSession = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

/// Create a writable session on a branch.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkWritableSession(
    repo: *mut IcRepoHandle,
    branch: *const c_char,
    pSession: *mut *mut IcSessionHandle,
) -> ZarrsResult {
    if repo.is_null() || pSession.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let branch_str = match str_from_ptr(branch) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let rh = unsafe { &*repo };
    let runtime = rh.runtime.clone();

    let result = runtime.block_on(async {
        let session = rh
            .repo
            .writable_session(&branch_str)
            .await
            .map_err(|e| format!("writable_session error: {e}"))?;

        let session_arc = Arc::new(tokio::sync::RwLock::new(session));
        let store = icechunk::Store::from_session(session_arc).await;
        Ok::<_, String>(store)
    });

    match result {
        Ok(store) => {
            let handle = Box::new(IcSessionHandle { store, runtime });
            unsafe { *pSession = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkDestroySession(
    session: *mut IcSessionHandle,
) -> ZarrsResult {
    if session.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    unsafe { drop(Box::from_raw(session)) };
    ZarrsResult::ZARRS_SUCCESS
}

// ---------------------------------------------------------------------------
// Session -> zarrs-compatible StorageHandle
// ---------------------------------------------------------------------------

/// Create a zarrs-compatible StorageHandle from an Icechunk session.
/// This bridges the Icechunk Store to the zarrs sync storage interface.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionGetStorage(
    session: *mut IcSessionHandle,
    pStorage: *mut *mut StorageHandle,
) -> ZarrsResult {
    if session.is_null() || pStorage.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let sh = unsafe { &*session };
    let adapter = Arc::new(IcechunkAdapter::new(sh.store.clone()));
    let runtime = tokio::runtime::Runtime::new();
    let runtime = match runtime {
        Ok(rt) => rt,
        Err(e) => {
            set_error(format!("Failed to create tokio runtime: {e}"));
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };
    let block_on = TokioBlockOn(runtime);
    let sync_store = Arc::new(AsyncToSyncStorageAdapter::new(adapter, block_on));

    let handle = Box::new(StorageHandle { store: sync_store });
    unsafe { *pStorage = Box::into_raw(handle) };
    ZarrsResult::ZARRS_SUCCESS
}

// ---------------------------------------------------------------------------
// Session properties
// ---------------------------------------------------------------------------

/// Check if a session is read-only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionReadOnly(
    session: *mut IcSessionHandle,
    pReadOnly: *mut i32,
) -> ZarrsResult {
    if session.is_null() || pReadOnly.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let sh = unsafe { &*session };
    let ro = sh.runtime.block_on(async { sh.store.read_only().await });
    unsafe { *pReadOnly = if ro { 1 } else { 0 } };
    ZarrsResult::ZARRS_SUCCESS
}
