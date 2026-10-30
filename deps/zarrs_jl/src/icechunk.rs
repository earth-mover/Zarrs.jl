use std::ffi::CString;
use std::ffi::c_char;
use std::sync::Arc;

use super::{
    set_error, shared_runtime, str_from_ptr, IcechunkAdapter, SharedRuntime, StorageHandle,
    TokioBlockOn, ZarrsResult,
};

use zarrs_storage::storage_adapter::async_to_sync::AsyncToSyncStorageAdapter;

// ---------------------------------------------------------------------------
// Opaque handles
// ---------------------------------------------------------------------------

/// Handle wrapping Icechunk object-store storage + a Tokio runtime.
pub struct IcStorageHandle {
    pub storage: Arc<dyn icechunk::storage::Storage + Send + Sync>,
    pub runtime: SharedRuntime,
}

/// Handle wrapping an Icechunk Repository.
pub struct IcRepoHandle {
    pub repo: icechunk::Repository,
    pub runtime: SharedRuntime,
}

/// Handle wrapping an Icechunk Session and its Store (zarr-compatible).
/// Stores both the Store (for zarrs compatibility) and the underlying Session
/// (for commit/has_changes operations).
pub struct IcSessionHandle {
    pub store: icechunk::Store,
    pub session: Arc<tokio::sync::RwLock<icechunk::session::Session>>,
    pub runtime: SharedRuntime,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Kept as a function so the storage constructors read as before; always the shared runtime.
fn make_runtime() -> Result<SharedRuntime, String> {
    Ok(shared_runtime())
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
    access_key_id: *const c_char,
    secret_access_key: *const c_char,
    session_token: *const c_char,
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
    let access_key_opt = opt_string(access_key_id);
    let secret_key_opt = opt_string(secret_access_key);
    let session_token_opt = opt_string(session_token);

    let runtime = match make_runtime() {
        Ok(rt) => rt,
        Err(msg) => {
            set_error(msg);
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let mut s3_opts = icechunk::config::S3Options::default();
    s3_opts.region = region_opt;
    s3_opts.endpoint_url = endpoint_opt;
    s3_opts.anonymous = anonymous != 0;
    s3_opts.allow_http = allow_http != 0;
    s3_opts.network_stream_timeout_seconds = Some(30);

    let credentials = if anonymous != 0 {
        Some(icechunk::config::S3Credentials::Anonymous)
    } else if let (Some(ak), Some(sk)) = (&access_key_opt, &secret_key_opt) {
        Some(icechunk::config::S3Credentials::Static(
            icechunk::config::S3StaticCredentials {
                access_key_id: ak.clone(),
                secret_access_key: sk.clone(),
                session_token: session_token_opt,
                expires_after: None,
            },
        ))
    } else {
        Some(icechunk::config::S3Credentials::FromEnv)
    };

    match icechunk::new_s3_storage(s3_opts, bucket_str, prefix_opt, credentials, vec![], vec![], None) {
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
    credential_type: i32,
    credential_value: *const c_char,
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
    let cred_value_opt = opt_string(credential_value);

    let runtime = match make_runtime() {
        Ok(rt) => rt,
        Err(msg) => {
            set_error(msg);
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let credentials = match credential_type {
        1 => Some(icechunk::config::GcsCredentials::Anonymous),
        2 => {
            // ServiceAccountPath
            if let Some(path) = cred_value_opt {
                Some(icechunk::config::GcsCredentials::Static(
                    icechunk::config::GcsStaticCredentials::ServiceAccount(path.into()),
                ))
            } else {
                Some(icechunk::config::GcsCredentials::FromEnv)
            }
        }
        3 => {
            // ServiceAccountKey (JSON string)
            if let Some(key) = cred_value_opt {
                Some(icechunk::config::GcsCredentials::Static(
                    icechunk::config::GcsStaticCredentials::ServiceAccountKey(key),
                ))
            } else {
                Some(icechunk::config::GcsCredentials::FromEnv)
            }
        }
        4 => {
            // BearerToken
            if let Some(token) = cred_value_opt {
                Some(icechunk::config::GcsCredentials::Static(
                    icechunk::config::GcsStaticCredentials::BearerToken(
                        icechunk::config::GcsBearerCredential {
                            bearer: token,
                            expires_after: None,
                        },
                    ),
                ))
            } else {
                Some(icechunk::config::GcsCredentials::FromEnv)
            }
        }
        _ => {
            // 0 or default = FromEnv
            Some(icechunk::config::GcsCredentials::FromEnv)
        }
    };

    let result = runtime.block_on(async {
        icechunk::storage::new_gcs_storage(bucket_str, prefix_opt, credentials, None, vec![], vec![])
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

/// S3 storage whose credentials come from a Julia function (refreshed by icechunk before they
/// expire). `callback_id` identifies the function in Zarrs.jl's credential registry; see
/// `credentials.rs` for how the function is called without running Julia on Tokio threads.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkS3StorageRefreshable(
    bucket: *const c_char,
    prefix: *const c_char,
    region: *const c_char,
    endpoint_url: *const c_char,
    allow_http: i32,
    force_path_style: i32,
    callback_id: u64,
    pHandle: *mut *mut IcStorageHandle,
) -> ZarrsResult {
    if pHandle.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let bucket_str = match str_from_ptr(bucket) {
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
    let mut s3_opts = icechunk::config::S3Options::default();
    s3_opts.region = opt_string(region);
    s3_opts.endpoint_url = opt_string(endpoint_url);
    s3_opts.allow_http = allow_http != 0;
    s3_opts.force_path_style = force_path_style != 0;
    s3_opts.network_stream_timeout_seconds = Some(30);
    let fetcher = crate::credentials::JuliaS3CredentialsFetcher { callback_id, pid: std::process::id() };
    let credentials = Some(icechunk::config::S3Credentials::Refreshable(Arc::new(fetcher)));
    match icechunk::new_s3_storage(s3_opts, bucket_str, opt_string(prefix), credentials, vec![], vec![], None) {
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

/// GCS storage whose bearer token comes from a Julia function (see
/// `zarrsIcechunkS3StorageRefreshable`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkGcsStorageRefreshable(
    bucket: *const c_char,
    prefix: *const c_char,
    callback_id: u64,
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
    let fetcher = crate::credentials::JuliaGcsCredentialsFetcher { callback_id, pid: std::process::id() };
    let credentials = Some(icechunk::config::GcsCredentials::Refreshable(Arc::new(fetcher)));
    let result = runtime.block_on(async {
        icechunk::storage::new_gcs_storage(bucket_str, prefix_opt, credentials, None, vec![], vec![])
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
    credential_type: i32,
    credential_value: *const c_char,
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
    let cred_value_opt = opt_string(credential_value);

    let runtime = match make_runtime() {
        Ok(rt) => rt,
        Err(msg) => {
            set_error(msg);
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let credentials = match credential_type {
        1 => {
            // AccessKey
            if let Some(key) = cred_value_opt {
                Some(icechunk::config::AzureCredentials::Static(
                    icechunk::config::AzureStaticCredentials::AccessKey(key),
                ))
            } else {
                Some(icechunk::config::AzureCredentials::FromEnv)
            }
        }
        2 => {
            // SASToken
            if let Some(token) = cred_value_opt {
                Some(icechunk::config::AzureCredentials::Static(
                    icechunk::config::AzureStaticCredentials::SASToken(token),
                ))
            } else {
                Some(icechunk::config::AzureCredentials::FromEnv)
            }
        }
        3 => {
            // BearerToken
            if let Some(token) = cred_value_opt {
                Some(icechunk::config::AzureCredentials::Static(
                    icechunk::config::AzureStaticCredentials::BearerToken(token),
                ))
            } else {
                Some(icechunk::config::AzureCredentials::FromEnv)
            }
        }
        _ => {
            // 0 or default = FromEnv
            Some(icechunk::config::AzureCredentials::FromEnv)
        }
    };

    let result = runtime.block_on(async {
        icechunk::storage::new_azure_blob_storage(account_str, container_str, prefix_opt, credentials, None)
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
    let runtime = ic.runtime;

    let result = runtime.block_on(async {
        icechunk::Repository::open(storage)
            .execute()
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
    let runtime = ic.runtime;

    let result = runtime.block_on(async {
        icechunk::Repository::create(storage)
            .execute()
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
    let runtime = ic.runtime;

    let result = runtime.block_on(async {
        icechunk::Repository::open_or_create(storage)
            .execute()
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
// Branch & tag management
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoCreateBranch(
    repo: *mut IcRepoHandle,
    name: *const c_char,
    snapshot_id_str: *const c_char,
    pResult: *mut *mut c_char,
) -> ZarrsResult {
    if repo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let name_str = match str_from_ptr(name) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let snap_str = match str_from_ptr(snapshot_id_str) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let rh = unsafe { &*repo };
    let snap_id: icechunk::format::SnapshotId = match icechunk::format::SnapshotId::try_from(snap_str.as_str()) {
        Ok(id) => id,
        Err(e) => {
            set_error(format!("Invalid snapshot ID: {e}"));
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let result = rh.runtime.block_on(async {
        rh.repo
            .create_branch(&name_str, &snap_id)
            .await
            .map_err(|e| format!("create_branch error: {e}"))
    });

    match result {
        Ok(_) => {
            if !pResult.is_null() {
                let cstr = CString::new("").unwrap_or_default();
                unsafe { *pResult = cstr.into_raw() };
            }
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoDeleteBranch(
    repo: *mut IcRepoHandle,
    name: *const c_char,
) -> ZarrsResult {
    if repo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let name_str = match str_from_ptr(name) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let rh = unsafe { &*repo };
    let result = rh.runtime.block_on(async {
        rh.repo
            .delete_branch(&name_str)
            .await
            .map_err(|e| format!("delete_branch error: {e}"))
    });

    match result {
        Ok(_) => ZarrsResult::ZARRS_SUCCESS,
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoCreateTag(
    repo: *mut IcRepoHandle,
    name: *const c_char,
    snapshot_id_str: *const c_char,
    pResult: *mut *mut c_char,
) -> ZarrsResult {
    if repo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let name_str = match str_from_ptr(name) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let snap_str = match str_from_ptr(snapshot_id_str) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let rh = unsafe { &*repo };
    let snap_id: icechunk::format::SnapshotId = match icechunk::format::SnapshotId::try_from(snap_str.as_str()) {
        Ok(id) => id,
        Err(e) => {
            set_error(format!("Invalid snapshot ID: {e}"));
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let result = rh.runtime.block_on(async {
        rh.repo
            .create_tag(&name_str, &snap_id)
            .await
            .map_err(|e| format!("create_tag error: {e}"))
    });

    match result {
        Ok(_) => {
            if !pResult.is_null() {
                let cstr = CString::new("").unwrap_or_default();
                unsafe { *pResult = cstr.into_raw() };
            }
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoDeleteTag(
    repo: *mut IcRepoHandle,
    name: *const c_char,
) -> ZarrsResult {
    if repo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let name_str = match str_from_ptr(name) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let rh = unsafe { &*repo };
    let result = rh.runtime.block_on(async {
        rh.repo
            .delete_tag(&name_str)
            .await
            .map_err(|e| format!("delete_tag error: {e}"))
    });

    match result {
        Ok(_) => ZarrsResult::ZARRS_SUCCESS,
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoLookupBranch(
    repo: *mut IcRepoHandle,
    name: *const c_char,
    pSnapshotId: *mut *mut c_char,
) -> ZarrsResult {
    if repo.is_null() || pSnapshotId.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let name_str = match str_from_ptr(name) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let rh = unsafe { &*repo };
    let result = rh.runtime.block_on(async {
        rh.repo
            .lookup_branch(&name_str)
            .await
            .map_err(|e| format!("lookup_branch error: {e}"))
    });

    match result {
        Ok(snap_id) => {
            let id_str = snap_id.to_string();
            match CString::new(id_str) {
                Ok(cstr) => {
                    unsafe { *pSnapshotId = cstr.into_raw() };
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
pub unsafe extern "C" fn zarrsIcechunkRepoLookupTag(
    repo: *mut IcRepoHandle,
    name: *const c_char,
    pSnapshotId: *mut *mut c_char,
) -> ZarrsResult {
    if repo.is_null() || pSnapshotId.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let name_str = match str_from_ptr(name) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let rh = unsafe { &*repo };
    let result = rh.runtime.block_on(async {
        rh.repo
            .lookup_tag(&name_str)
            .await
            .map_err(|e| format!("lookup_tag error: {e}"))
    });

    match result {
        Ok(snap_id) => {
            let id_str = snap_id.to_string();
            match CString::new(id_str) {
                Ok(cstr) => {
                    unsafe { *pSnapshotId = cstr.into_raw() };
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
        2 => match parse_snapshot_id(&version_str) {
            Ok(id) => icechunk::repository::VersionInfo::SnapshotId(id),
            Err(msg) => {
                set_error(msg);
                return ZarrsResult::ZARRS_ERROR_STORAGE;
            }
        },
        _ => {
            set_error(format!("Invalid version_type: {version_type}"));
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let rh = unsafe { &*repo };
    let runtime = rh.runtime;

    let result = runtime.block_on(async {
        let session = rh
            .repo
            .readonly_session(&version)
            .await
            .map_err(|e| format!("readonly_session error: {e}"))?;

        let session_arc: Arc<tokio::sync::RwLock<icechunk::session::Session>> =
            Arc::new(tokio::sync::RwLock::new(session));
        let store = icechunk::Store::from_session(session_arc.clone()).await;
        Ok::<_, String>((store, session_arc))
    });

    match result {
        Ok((store, session_arc)) => {
            let handle = Box::new(IcSessionHandle { store, session: session_arc, runtime });
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
    let runtime = rh.runtime;

    let result = runtime.block_on(async {
        let session = rh
            .repo
            .writable_session(&branch_str)
            .await
            .map_err(|e| format!("writable_session error: {e}"))?;

        let session_arc: Arc<tokio::sync::RwLock<icechunk::session::Session>> =
            Arc::new(tokio::sync::RwLock::new(session));
        let store = icechunk::Store::from_session(session_arc.clone()).await;
        Ok::<_, String>((store, session_arc))
    });

    match result {
        Ok((store, session_arc)) => {
            let handle = Box::new(IcSessionHandle { store, session: session_arc, runtime });
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
    let block_on = TokioBlockOn(shared_runtime());
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

// ---------------------------------------------------------------------------
// Session commit & changes
// ---------------------------------------------------------------------------

/// Commit a writable session with a message, returning a snapshot ID string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionCommit(
    session: *mut IcSessionHandle,
    message: *const c_char,
    pSnapshotId: *mut *mut c_char,
) -> ZarrsResult {
    if session.is_null() || pSnapshotId.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let msg_str = match str_from_ptr(message) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };

    let sh = unsafe { &*session };
    let result = sh.runtime.block_on(async {
        let mut session_guard: tokio::sync::RwLockWriteGuard<'_, icechunk::session::Session> =
            sh.session.write().await;
        session_guard
            .commit(msg_str.as_str())
            .execute()
            .await
            .map_err(|e| format!("commit error: {e}"))
    });

    match result {
        Ok(snap_id) => {
            let id_str = format!("{snap_id}");
            match CString::new(id_str) {
                Ok(cstr) => {
                    unsafe { *pSnapshotId = cstr.into_raw() };
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

/// Check if a session has uncommitted changes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionHasChanges(
    session: *mut IcSessionHandle,
    pHasChanges: *mut i32,
) -> ZarrsResult {
    if session.is_null() || pHasChanges.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }

    let sh = unsafe { &*session };
    let has_changes = sh.runtime.block_on(async {
        let session_guard: tokio::sync::RwLockReadGuard<'_, icechunk::session::Session> =
            sh.session.read().await;
        session_guard.has_uncommitted_changes()
    });

    unsafe { *pHasChanges = if has_changes { 1 } else { 0 } };
    ZarrsResult::ZARRS_SUCCESS
}

/// Commit a writable session with a message and snapshot metadata (`metadata_json`, a JSON
/// object, or null for none), returning the snapshot ID string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionCommitWithMetadata(
    session: *mut IcSessionHandle,
    message: *const c_char,
    metadata_json: *const c_char,
    pSnapshotId: *mut *mut c_char,
) -> ZarrsResult {
    if session.is_null() || pSnapshotId.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let msg_str = match str_from_ptr(message) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let properties: icechunk::format::snapshot::SnapshotProperties = match opt_string(metadata_json)
    {
        None => Default::default(),
        Some(json) => match serde_json::from_str(&json) {
            Ok(p) => p,
            Err(e) => {
                set_error(format!("commit metadata must be a JSON object: {e}"));
                return ZarrsResult::ZARRS_ERROR_INVALID_METADATA;
            }
        },
    };

    let sh = unsafe { &*session };
    let result = sh.runtime.block_on(async {
        let mut guard = sh.session.write().await;
        guard
            .commit(msg_str.as_str())
            .properties(properties)
            .execute()
            .await
            .map_err(|e| format!("commit error: {e}"))
    });
    match result.and_then(|id| CString::new(id.to_string()).map_err(|e| e.to_string())) {
        Ok(cstr) => {
            unsafe { *pSnapshotId = cstr.into_raw() };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

/// The ancestry of a branch, newest first, as a JSON array of
/// `{"id", "parent_id", "written_at", "message", "metadata"}` (`written_at` is RFC 3339, UTC).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoAncestry(
    repo: *mut IcRepoHandle,
    branch: *const c_char,
    pJson: *mut *mut c_char,
) -> ZarrsResult {
    if repo.is_null() || pJson.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let branch_str = match str_from_ptr(branch) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let rh = unsafe { &*repo };
    let result = rh.runtime.block_on(async {
        use futures::TryStreamExt;
        let version = icechunk::repository::VersionInfo::BranchTipRef(branch_str);
        let stream = rh.repo.ancestry(&version).await.map_err(|e| format!("ancestry error: {e}"))?;
        let infos: Vec<_> = stream.try_collect().await.map_err(|e| format!("ancestry error: {e}"))?;
        let items: Vec<serde_json::Value> = infos
            .into_iter()
            .map(|info| {
                serde_json::json!({
                    "id": info.id.to_string(),
                    "parent_id": info.parent_id.map(|p| p.to_string()),
                    "written_at": info.flushed_at.to_rfc3339(),
                    "message": info.message,
                    "metadata": info.metadata,
                })
            })
            .collect();
        serde_json::to_string(&items).map_err(|e| e.to_string())
    });
    match result.and_then(|json| CString::new(json).map_err(|e| e.to_string())) {
        Ok(cstr) => {
            unsafe { *pJson = cstr.into_raw() };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

// ---------------------------------------------------------------------------
// Snapshots, time travel, status, diff, branch reset
// ---------------------------------------------------------------------------

fn parse_snapshot_id(s: &str) -> Result<icechunk::format::SnapshotId, String> {
    icechunk::format::SnapshotId::try_from(s).map_err(|e| format!("Invalid snapshot ID {s:?}: {e}"))
}

fn parse_rfc3339(s: &str) -> Result<chrono::DateTime<chrono::Utc>, String> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|t| t.with_timezone(&chrono::Utc))
        .map_err(|e| format!("Invalid timestamp {s:?} (expected RFC 3339): {e}"))
}

/// Store a string result in `*out`, or record the error.
unsafe fn string_out(result: Result<String, String>, out: *mut *mut c_char) -> ZarrsResult {
    match result.and_then(|s| CString::new(s).map_err(|e| e.to_string())) {
        Ok(cstr) => {
            unsafe { *out = cstr.into_raw() };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

/// Create a readonly session on the last snapshot of `branch` written at or before `at`
/// (an RFC 3339 timestamp).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkReadonlySessionAsOf(
    repo: *mut IcRepoHandle,
    branch: *const c_char,
    at: *const c_char,
    pSession: *mut *mut IcSessionHandle,
) -> ZarrsResult {
    if repo.is_null() || pSession.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let branch_str = match str_from_ptr(branch) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let at = match str_from_ptr(at).map(parse_rfc3339) {
        Ok(Ok(t)) => t,
        Ok(Err(msg)) => {
            set_error(msg);
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
        Err(r) => return r,
    };
    let version = icechunk::repository::VersionInfo::AsOf { branch: branch_str, at };
    let rh = unsafe { &*repo };
    let runtime = rh.runtime;
    let result = runtime.block_on(async {
        let session = rh
            .repo
            .readonly_session(&version)
            .await
            .map_err(|e| format!("readonly_session error: {e}"))?;
        let session_arc = Arc::new(tokio::sync::RwLock::new(session));
        let store = icechunk::Store::from_session(session_arc.clone()).await;
        Ok::<_, String>((store, session_arc))
    });
    match result {
        Ok((store, session_arc)) => {
            let handle = Box::new(IcSessionHandle { store, session: session_arc, runtime });
            unsafe { *pSession = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

/// The snapshot a session is based on (its branch tip when it was opened, or the snapshot it
/// reads).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionSnapshotId(
    session: *mut IcSessionHandle,
    pSnapshotId: *mut *mut c_char,
) -> ZarrsResult {
    if session.is_null() || pSnapshotId.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let sh = unsafe { &*session };
    let id = sh.runtime.block_on(async { sh.session.read().await.snapshot_id().to_string() });
    unsafe { string_out(Ok(id), pSnapshotId) }
}

/// The branch of a session, or an empty string for a session that is not on a branch.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionBranch(
    session: *mut IcSessionHandle,
    pBranch: *mut *mut c_char,
) -> ZarrsResult {
    if session.is_null() || pBranch.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let sh = unsafe { &*session };
    let branch =
        sh.runtime.block_on(async { sh.session.read().await.branch().unwrap_or("").to_string() });
    unsafe { string_out(Ok(branch), pBranch) }
}

/// Drop all uncommitted changes of a writable session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionDiscardChanges(
    session: *mut IcSessionHandle,
) -> ZarrsResult {
    if session.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let sh = unsafe { &*session };
    let result = sh.runtime.block_on(async {
        sh.session.write().await.discard_changes().map_err(|e| format!("discard_changes error: {e}"))
    });
    match result {
        Ok(()) => ZarrsResult::ZARRS_SUCCESS,
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

/// Commit with options: `metadata_json` (a JSON object, or null), `amend` (replace the branch
/// tip instead of adding a snapshot on top of it) and `allow_empty` (commit even without
/// changes). Returns the new snapshot ID.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionCommitWithOptions(
    session: *mut IcSessionHandle,
    message: *const c_char,
    metadata_json: *const c_char,
    amend: i32,
    allow_empty: i32,
    pSnapshotId: *mut *mut c_char,
) -> ZarrsResult {
    if session.is_null() || pSnapshotId.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let msg_str = match str_from_ptr(message) {
        Ok(s) => s.to_string(),
        Err(r) => return r,
    };
    let properties: icechunk::format::snapshot::SnapshotProperties = match opt_string(metadata_json)
    {
        None => Default::default(),
        Some(json) => match serde_json::from_str(&json) {
            Ok(p) => p,
            Err(e) => {
                set_error(format!("commit metadata must be a JSON object: {e}"));
                return ZarrsResult::ZARRS_ERROR_INVALID_METADATA;
            }
        },
    };
    let sh = unsafe { &*session };
    let result = sh.runtime.block_on(async {
        let mut guard = sh.session.write().await;
        let mut builder = guard.commit(msg_str.as_str()).properties(properties).allow_empty(allow_empty != 0);
        if amend != 0 {
            builder = builder.amend();
        }
        builder.execute().await.map(|id| id.to_string()).map_err(|e| format!("commit error: {e}"))
    });
    unsafe { string_out(result, pSnapshotId) }
}

fn diff_to_json(diff: &icechunk::diff::Diff) -> serde_json::Value {
    let paths = |set: &std::collections::BTreeSet<icechunk::format::Path>| -> Vec<String> {
        set.iter().map(|p| p.to_string()).collect()
    };
    let chunks: serde_json::Map<String, serde_json::Value> = diff
        .updated_chunks
        .iter()
        .map(|(path, coords)| {
            let coords: Vec<Vec<u32>> = coords.iter().map(|c| c.0.clone()).collect();
            (path.to_string(), serde_json::json!(coords))
        })
        .collect();
    let moved: Vec<serde_json::Value> = diff
        .moved_nodes
        .iter()
        .map(|m| serde_json::json!({"from": m.from.to_string(), "to": m.to.to_string()}))
        .collect();
    serde_json::json!({
        "new_groups": paths(&diff.new_groups),
        "new_arrays": paths(&diff.new_arrays),
        "deleted_groups": paths(&diff.deleted_groups),
        "deleted_arrays": paths(&diff.deleted_arrays),
        "updated_groups": paths(&diff.updated_groups),
        "updated_arrays": paths(&diff.updated_arrays),
        "updated_chunks": chunks,
        "moved_nodes": moved,
    })
}

/// The uncommitted changes of a session, as a JSON diff object.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionStatus(
    session: *mut IcSessionHandle,
    pJson: *mut *mut c_char,
) -> ZarrsResult {
    if session.is_null() || pJson.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let sh = unsafe { &*session };
    let result = sh.runtime.block_on(async {
        let diff = sh.session.read().await.status().await.map_err(|e| format!("status error: {e}"))?;
        Ok(diff_to_json(&diff).to_string())
    });
    unsafe { string_out(result, pJson) }
}

/// A version selector: `kind` 0 = branch tip, 1 = tag, 2 = snapshot ID.
fn version_from(kind: i32, value: String) -> Result<icechunk::repository::VersionInfo, String> {
    use icechunk::repository::VersionInfo;
    match kind {
        0 => Ok(VersionInfo::BranchTipRef(value)),
        1 => Ok(VersionInfo::TagRef(value)),
        2 => parse_snapshot_id(&value).map(VersionInfo::SnapshotId),
        _ => Err(format!("Invalid version kind: {kind}")),
    }
}

/// The changes between two versions (`from` excluded, `to` included), as a JSON diff object.
/// `*_kind`: 0 = branch tip, 1 = tag, 2 = snapshot ID.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoDiff(
    repo: *mut IcRepoHandle,
    from_kind: i32,
    from_value: *const c_char,
    to_kind: i32,
    to_value: *const c_char,
    pJson: *mut *mut c_char,
) -> ZarrsResult {
    if repo.is_null() || pJson.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let (from, to) = match (str_from_ptr(from_value), str_from_ptr(to_value)) {
        (Ok(f), Ok(t)) => (version_from(from_kind, f.to_string()), version_from(to_kind, t.to_string())),
        (Err(r), _) | (_, Err(r)) => return r,
    };
    let rh = unsafe { &*repo };
    let result = from.and_then(|from| to.map(|to| (from, to))).and_then(|(from, to)| {
        rh.runtime.block_on(async {
            let diff = rh.repo.diff(&from, &to).await.map_err(|e| format!("diff error: {e}"))?;
            Ok(diff_to_json(&diff).to_string())
        })
    });
    unsafe { string_out(result, pJson) }
}

/// Point `branch` at `snapshot_id` (any snapshot, not only an ancestor).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoResetBranch(
    repo: *mut IcRepoHandle,
    branch: *const c_char,
    snapshot_id: *const c_char,
) -> ZarrsResult {
    if repo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let (branch_str, snap_str) = match (str_from_ptr(branch), str_from_ptr(snapshot_id)) {
        (Ok(b), Ok(s)) => (b.to_string(), s.to_string()),
        (Err(r), _) | (_, Err(r)) => return r,
    };
    let rh = unsafe { &*repo };
    let result = parse_snapshot_id(&snap_str).and_then(|id| {
        rh.runtime.block_on(async {
            rh.repo.reset_branch(&branch_str, &id, None).await.map_err(|e| format!("reset_branch error: {e}"))
        })
    });
    match result {
        Ok(()) => ZarrsResult::ZARRS_SUCCESS,
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

// ---------------------------------------------------------------------------
// Repository configuration and virtual chunks
// ---------------------------------------------------------------------------

/// Open (`mode` 0), create (1) or open-or-create (2) a repository with a configuration and
/// virtual chunk credentials.
///
/// `config_json`: an icechunk `RepositoryConfig` as JSON (its serde form, e.g.
/// `{"inline_chunk_threshold_bytes": 512, "virtual_chunk_containers": {...}}`), or null. On
/// open, it is merged over the configuration stored in the repository.
/// `credentials_json`: a JSON object mapping virtual chunk container URL prefixes to icechunk
/// `Credentials` (serde form) or `null`, or null for none. Containers not listed cannot be read.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoOpenWithConfig(
    ic_storage: *mut IcStorageHandle,
    mode: i32,
    config_json: *const c_char,
    credentials_json: *const c_char,
    pRepo: *mut *mut IcRepoHandle,
) -> ZarrsResult {
    if ic_storage.is_null() || pRepo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let config: Option<icechunk::RepositoryConfig> = match opt_string(config_json) {
        None => None,
        Some(json) => match serde_json::from_str(&json) {
            Ok(c) => Some(c),
            Err(e) => {
                set_error(format!("invalid repository config: {e}"));
                return ZarrsResult::ZARRS_ERROR_INVALID_METADATA;
            }
        },
    };
    let credentials: std::collections::HashMap<String, Option<icechunk::config::Credentials>> =
        match opt_string(credentials_json) {
            None => Default::default(),
            Some(json) => match serde_json::from_str(&json) {
                Ok(c) => c,
                Err(e) => {
                    set_error(format!("invalid virtual chunk credentials: {e}"));
                    return ZarrsResult::ZARRS_ERROR_INVALID_METADATA;
                }
            },
        };

    let ic = unsafe { &*ic_storage };
    let storage = ic.storage.clone();
    let runtime = ic.runtime;
    let result = runtime.block_on(async {
        macro_rules! build {
            ($builder:expr) => {{
                let mut b = $builder.authorize_virtual_chunk_access(credentials);
                if let Some(c) = config {
                    b = b.config(c);
                }
                b.execute().await
            }};
        }
        match mode {
            0 => build!(icechunk::Repository::open(storage)),
            1 => build!(icechunk::Repository::create(storage)),
            2 => build!(icechunk::Repository::open_or_create(storage)),
            _ => return Err(format!("Invalid mode: {mode}")),
        }
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

/// The repository's configuration (stored configuration merged with the one it was opened
/// with) as JSON.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoConfig(
    repo: *mut IcRepoHandle,
    pJson: *mut *mut c_char,
) -> ZarrsResult {
    if repo.is_null() || pJson.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let rh = unsafe { &*repo };
    let result = serde_json::to_string(rh.repo.config()).map_err(|e| e.to_string());
    unsafe { string_out(result, pJson) }
}

/// Persist the repository's current configuration (e.g. its virtual chunk containers) in the
/// repository, so later opens use it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkRepoSaveConfig(repo: *mut IcRepoHandle) -> ZarrsResult {
    if repo.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let rh = unsafe { &*repo };
    let result = rh
        .runtime
        .block_on(async { rh.repo.save_config().await.map_err(|e| format!("save_config error: {e}")) });
    match result {
        Ok(_) => ZarrsResult::ZARRS_SUCCESS,
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

/// Point the chunk at store key `key` (e.g. `"array/c/0/1"`) to `length` bytes at `offset` in
/// the object at `location` (a URL inside a virtual chunk container). `etag` (or null) and
/// `last_modified` (seconds since the epoch, or 0) guard against the object changing: reads
/// fail if it no longer matches. With `validate_container` set, the location must belong to a
/// container declared in the repository configuration.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionSetVirtualRef(
    session: *mut IcSessionHandle,
    key: *const c_char,
    location: *const c_char,
    offset: u64,
    length: u64,
    etag: *const c_char,
    last_modified: u32,
    validate_container: i32,
) -> ZarrsResult {
    if session.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let (key_str, location_str) = match (str_from_ptr(key), str_from_ptr(location)) {
        (Ok(k), Ok(l)) => (k.to_string(), l.to_string()),
        (Err(r), _) | (_, Err(r)) => return r,
    };
    let location = match icechunk::format::manifest::VirtualChunkLocation::from_url(&location_str) {
        Ok(l) => l,
        Err(e) => {
            set_error(format!("invalid virtual chunk location {location_str:?}: {e}"));
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };
    let checksum: Option<icechunk::format::manifest::Checksum> = match opt_string(etag) {
        Some(tag) => serde_json::from_value(serde_json::json!({ "ETag": tag })).ok(),
        None if last_modified > 0 => {
            serde_json::from_value(serde_json::json!({ "LastModified": last_modified })).ok()
        }
        None => None,
    };
    let reference = icechunk::format::manifest::VirtualChunkRef { location, offset, length, checksum };
    let sh = unsafe { &*session };
    let result = sh.runtime.block_on(async {
        sh.store
            .set_virtual_ref(&key_str, reference, validate_container != 0)
            .await
            .map_err(|e| format!("set_virtual_ref error: {e}"))
    });
    match result {
        Ok(()) => ZarrsResult::ZARRS_SUCCESS,
        Err(msg) => {
            set_error(msg);
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

/// All virtual chunk locations referenced by the session's snapshot, as a JSON array of URLs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsIcechunkSessionVirtualChunkLocations(
    session: *mut IcSessionHandle,
    pJson: *mut *mut c_char,
) -> ZarrsResult {
    if session.is_null() || pJson.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let sh = unsafe { &*session };
    let result = sh.runtime.block_on(async {
        use futures::TryStreamExt;
        let guard = sh.session.read().await;
        let stream = guard
            .all_virtual_chunk_locations()
            .await
            .map_err(|e| format!("virtual chunk locations error: {e}"))?;
        let mut locations: Vec<String> =
            stream.try_collect().await.map_err(|e| format!("virtual chunk locations error: {e}"))?;
        locations.sort();
        locations.dedup();
        serde_json::to_string(&locations).map_err(|e| e.to_string())
    });
    unsafe { string_out(result, pJson) }
}
