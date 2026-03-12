#![allow(non_snake_case)]
#![allow(non_camel_case_types)]

use std::ffi::{CStr, CString, c_char};
use std::slice;
use std::sync::{Arc, Mutex};

use once_cell::sync::Lazy;
use zarrs::array::{Array, ArrayMetadata, ArrayBytes};
use zarrs::group::Group;
use zarrs::storage::ReadableWritableListableStorageTraits;
use zarrs_storage::storage_adapter::async_to_sync::{AsyncToSyncBlockOn, AsyncToSyncStorageAdapter};

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------

#[non_exhaustive]
#[repr(i32)]
pub enum ZarrsResult {
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
}

static LAST_ERROR: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));

fn set_error(msg: String) {
    *LAST_ERROR.lock().unwrap() = msg;
}

#[unsafe(no_mangle)]
pub extern "C" fn zarrsLastError() -> *mut c_char {
    let err = LAST_ERROR.lock().unwrap().clone();
    CString::new(err).unwrap_or_default().into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsFreeString(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

// ---------------------------------------------------------------------------
// Version
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn zarrsVersion() -> *mut c_char {
    let v = env!("CARGO_PKG_VERSION");
    CString::new(v).unwrap_or_default().into_raw()
}

// ---------------------------------------------------------------------------
// Storage — opaque handle wrapping an Arc<FilesystemStore>
// ---------------------------------------------------------------------------

type StorageArc = Arc<dyn ReadableWritableListableStorageTraits>;

struct StorageHandle {
    store: StorageArc,
}

fn str_from_ptr<'a>(ptr: *const c_char) -> Result<&'a str, ZarrsResult> {
    if ptr.is_null() {
        return Err(ZarrsResult::ZARRS_ERROR_NULL_PTR);
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|e| {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_NODE_PATH
        })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsCreateStorageFilesystem(
    path: *const c_char,
    pStorage: *mut *mut StorageHandle,
) -> ZarrsResult {
    let path_str = match str_from_ptr(path) {
        Ok(s) => s,
        Err(r) => return r,
    };
    match zarrs::filesystem::FilesystemStore::new(path_str) {
        Ok(store) => {
            let handle = Box::new(StorageHandle {
                store: Arc::new(store),
            });
            unsafe { *pStorage = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

// ---------------------------------------------------------------------------
// Storage — HTTP (read-only via object_store)
// ---------------------------------------------------------------------------

struct TokioBlockOn(tokio::runtime::Runtime);

impl AsyncToSyncBlockOn for TokioBlockOn {
    fn block_on<F: core::future::Future>(&self, future: F) -> F::Output {
        self.0.block_on(future)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsCreateStorageHTTP(
    url: *const c_char,
    pStorage: *mut *mut StorageHandle,
) -> ZarrsResult {
    let url_str = match str_from_ptr(url) {
        Ok(s) => s,
        Err(r) => return r,
    };

    let runtime = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            set_error(format!("Failed to create tokio runtime: {e}"));
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let options = object_store::ClientOptions::new().with_allow_http(true);
    let http_store = match object_store::http::HttpBuilder::new()
        .with_url(url_str)
        .with_client_options(options)
        .build()
    {
        Ok(store) => store,
        Err(e) => {
            set_error(format!("Failed to create HTTP store: {e}"));
            return ZarrsResult::ZARRS_ERROR_STORAGE;
        }
    };

    let async_store = Arc::new(zarrs_object_store::AsyncObjectStore::new(http_store));
    let sync_store = Arc::new(AsyncToSyncStorageAdapter::new(async_store, TokioBlockOn(runtime)));

    let handle = Box::new(StorageHandle {
        store: sync_store,
    });
    unsafe { *pStorage = Box::into_raw(handle) };
    ZarrsResult::ZARRS_SUCCESS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsDestroyStorage(storage: *mut StorageHandle) -> ZarrsResult {
    if storage.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    unsafe { drop(Box::from_raw(storage)) };
    ZarrsResult::ZARRS_SUCCESS
}

// ---------------------------------------------------------------------------
// Array — opaque handle wrapping Array<dyn ReadableWritableStorageTraits>
// ---------------------------------------------------------------------------

struct ArrayHandle {
    array: Array<dyn ReadableWritableListableStorageTraits>,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsCreateArrayRW(
    storage: *mut StorageHandle,
    path: *const c_char,
    metadata_json: *const c_char,
    pArray: *mut *mut ArrayHandle,
) -> ZarrsResult {
    if storage.is_null() || pArray.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let path_str = match str_from_ptr(path) {
        Ok(s) => s,
        Err(r) => return r,
    };
    let meta_str = match str_from_ptr(metadata_json) {
        Ok(s) => s,
        Err(r) => return r,
    };

    let metadata: ArrayMetadata = match serde_json::from_str(meta_str) {
        Ok(m) => m,
        Err(e) => {
            set_error(format!("Invalid metadata JSON: {e}"));
            return ZarrsResult::ZARRS_ERROR_INVALID_METADATA;
        }
    };

    let store = unsafe { &*storage }.store.clone();
    match Array::new_with_metadata(store, path_str, metadata) {
        Ok(array) => {
            if let Err(e) = array.store_metadata() {
                set_error(e.to_string());
                return ZarrsResult::ZARRS_ERROR_ARRAY;
            }
            let handle = Box::new(ArrayHandle { array });
            unsafe { *pArray = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsOpenArrayRW(
    storage: *mut StorageHandle,
    path: *const c_char,
    pArray: *mut *mut ArrayHandle,
) -> ZarrsResult {
    if storage.is_null() || pArray.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let path_str = match str_from_ptr(path) {
        Ok(s) => s,
        Err(r) => return r,
    };

    let store = unsafe { &*storage }.store.clone();
    match Array::open(store, path_str) {
        Ok(array) => {
            let handle = Box::new(ArrayHandle { array });
            unsafe { *pArray = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsDestroyArray(array: *mut ArrayHandle) -> ZarrsResult {
    if array.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    unsafe { drop(Box::from_raw(array)) };
    ZarrsResult::ZARRS_SUCCESS
}

// ---------------------------------------------------------------------------
// Array metadata queries
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetDimensionality(
    array: *mut ArrayHandle,
    pDimensionality: *mut usize,
) -> ZarrsResult {
    if array.is_null() || pDimensionality.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    unsafe { *pDimensionality = (*array).array.dimensionality() };
    ZarrsResult::ZARRS_SUCCESS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetShape(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pShape: *mut u64,
) -> ZarrsResult {
    if array.is_null() || pShape.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let shape = unsafe { &*array }.array.shape();
    if shape.len() != dimensionality {
        set_error(format!("Expected dimensionality {dimensionality}, got {}", shape.len()));
        return ZarrsResult::ZARRS_ERROR_INCOMPATIBLE_DIMENSIONALITY;
    }
    let out = unsafe { slice::from_raw_parts_mut(pShape, dimensionality) };
    for (i, &s) in shape.iter().enumerate() {
        out[i] = s;
    }
    ZarrsResult::ZARRS_SUCCESS
}

#[repr(i32)]
pub enum ZarrsDataType {
    ZARRS_UNDEFINED = -1,
    ZARRS_BOOL = 0,
    ZARRS_INT8 = 1,
    ZARRS_INT16 = 2,
    ZARRS_INT32 = 3,
    ZARRS_INT64 = 4,
    ZARRS_UINT8 = 5,
    ZARRS_UINT16 = 6,
    ZARRS_UINT32 = 7,
    ZARRS_UINT64 = 8,
    ZARRS_FLOAT16 = 9,
    ZARRS_FLOAT32 = 10,
    ZARRS_FLOAT64 = 11,
    ZARRS_COMPLEX64 = 12,
    ZARRS_COMPLEX128 = 13,
}

fn data_type_to_enum(dt: &zarrs::array::DataType) -> i32 {
    use zarrs::plugin::ExtensionName;
    // Use V3 name first, fall back to V2 name
    let name = dt.name(zarrs::plugin::ZarrVersion::V3)
        .or_else(|| dt.name(zarrs::plugin::ZarrVersion::V2))
        .unwrap_or_default();
    match name.as_ref() {
        "bool" => 0,
        "int8" => 1,
        "int16" => 2,
        "int32" => 3,
        "int64" => 4,
        "uint8" => 5,
        "uint16" => 6,
        "uint32" => 7,
        "uint64" => 8,
        "float16" => 9,
        "float32" => 10,
        "float64" => 11,
        "complex64" => 12,
        "complex128" => 13,
        _ => -1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetDataType(
    array: *mut ArrayHandle,
    pDataType: *mut i32,
) -> ZarrsResult {
    if array.is_null() || pDataType.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let dt = unsafe { &*array }.array.data_type();
    unsafe { *pDataType = data_type_to_enum(dt) };
    ZarrsResult::ZARRS_SUCCESS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetMetadataString(
    array: *mut ArrayHandle,
    pretty: i32,
    pMetadata: *mut *mut c_char,
) -> ZarrsResult {
    if array.is_null() || pMetadata.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let metadata = unsafe { &*array }.array.metadata();
    let json = if pretty != 0 {
        serde_json::to_string_pretty(&metadata)
    } else {
        serde_json::to_string(&metadata)
    };
    match json {
        Ok(s) => {
            let cstr = CString::new(s).unwrap_or_default();
            unsafe { *pMetadata = cstr.into_raw() };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetAttributes(
    array: *mut ArrayHandle,
    pretty: i32,
    pAttributes: *mut *mut c_char,
) -> ZarrsResult {
    if array.is_null() || pAttributes.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let attrs = unsafe { &*array }.array.attributes();
    let json = if pretty != 0 {
        serde_json::to_string_pretty(attrs)
    } else {
        serde_json::to_string(attrs)
    };
    match json {
        Ok(s) => {
            let cstr = CString::new(s).unwrap_or_default();
            unsafe { *pAttributes = cstr.into_raw() };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArraySetAttributes(
    array: *mut ArrayHandle,
    attributes: *const c_char,
) -> ZarrsResult {
    if array.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let attrs_str = match str_from_ptr(attributes) {
        Ok(s) => s,
        Err(r) => return r,
    };
    let attrs: serde_json::Map<String, serde_json::Value> = match serde_json::from_str(attrs_str) {
        Ok(a) => a,
        Err(e) => {
            set_error(e.to_string());
            return ZarrsResult::ZARRS_ERROR_INVALID_METADATA;
        }
    };
    unsafe { &mut *array }.array.attributes_mut().clone_from(&attrs);
    ZarrsResult::ZARRS_SUCCESS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayStoreMetadata(
    array: *mut ArrayHandle,
) -> ZarrsResult {
    if array.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    match unsafe { &*array }.array.store_metadata() {
        Ok(_) => ZarrsResult::ZARRS_SUCCESS,
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

// ---------------------------------------------------------------------------
// Array data I/O — arbitrary regions
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetSubsetSize(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pSubsetShape: *const u64,
    pSubsetSize: *mut usize,
) -> ZarrsResult {
    if array.is_null() || pSubsetShape.is_null() || pSubsetSize.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let shape = unsafe { slice::from_raw_parts(pSubsetShape, dimensionality) };
    let num_elements: u64 = shape.iter().product();
    let element_size = unsafe { &*array }.array.data_type().fixed_size().unwrap_or(0);
    unsafe { *pSubsetSize = (num_elements as usize) * element_size };
    ZarrsResult::ZARRS_SUCCESS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayRetrieveSubset(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pSubsetStart: *const u64,
    pSubsetShape: *const u64,
    subsetBytesCount: usize,
    pSubsetBytes: *mut u8,
) -> ZarrsResult {
    if array.is_null() || pSubsetStart.is_null() || pSubsetShape.is_null() || pSubsetBytes.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let start = unsafe { slice::from_raw_parts(pSubsetStart, dimensionality) }.to_vec();
    let shape = unsafe { slice::from_raw_parts(pSubsetShape, dimensionality) }.to_vec();

    let subset = zarrs::array::ArraySubset::new_with_start_shape(start, shape).unwrap();
    match unsafe { &*array }.array.retrieve_array_subset::<ArrayBytes<'static>>(&subset) {
        Ok(bytes) => {
            let bytes: Vec<u8> = bytes.into_fixed().unwrap().into_owned();
            if bytes.len() > subsetBytesCount {
                set_error(format!("Buffer too small: need {} got {subsetBytesCount}", bytes.len()));
                return ZarrsResult::ZARRS_ERROR_BUFFER_LENGTH;
            }
            let out = unsafe { slice::from_raw_parts_mut(pSubsetBytes, bytes.len()) };
            out.copy_from_slice(&bytes);
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayStoreSubset(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pSubsetStart: *const u64,
    pSubsetShape: *const u64,
    subsetBytesCount: usize,
    pSubsetBytes: *const u8,
) -> ZarrsResult {
    if array.is_null() || pSubsetStart.is_null() || pSubsetShape.is_null() || pSubsetBytes.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let start = unsafe { slice::from_raw_parts(pSubsetStart, dimensionality) }.to_vec();
    let shape = unsafe { slice::from_raw_parts(pSubsetShape, dimensionality) }.to_vec();
    let data = unsafe { slice::from_raw_parts(pSubsetBytes, subsetBytesCount) }.to_vec();
    let array_bytes = zarrs::array::ArrayBytes::Fixed(std::borrow::Cow::Owned(data));

    let subset = zarrs::array::ArraySubset::new_with_start_shape(start, shape).unwrap();
    match unsafe { &*array }.array.store_array_subset(&subset, array_bytes) {
        Ok(_) => ZarrsResult::ZARRS_SUCCESS,
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

// ---------------------------------------------------------------------------
// Chunk-level I/O
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetChunkGridShape(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pChunkGridShape: *mut u64,
) -> ZarrsResult {
    if array.is_null() || pChunkGridShape.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let arr = unsafe { &*array };
    let shape = arr.array.chunk_grid_shape();
    let out = unsafe { slice::from_raw_parts_mut(pChunkGridShape, dimensionality) };
    for (i, s) in shape.iter().enumerate() {
        if i < dimensionality {
            out[i] = *s;
        }
    }
    ZarrsResult::ZARRS_SUCCESS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetChunkSize(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pChunkIndices: *const u64,
    pChunkSize: *mut usize,
) -> ZarrsResult {
    if array.is_null() || pChunkIndices.is_null() || pChunkSize.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let indices = unsafe { slice::from_raw_parts(pChunkIndices, dimensionality) };
    let arr = unsafe { &*array };
    match arr.array.chunk_shape(indices) {
        Ok(chunk_shape) => {
            let num_elements: usize = chunk_shape.iter().map(|s| s.get() as usize).product();
            let element_size = arr.array.data_type().fixed_size().unwrap_or(0);
            unsafe { *pChunkSize = num_elements * element_size };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayRetrieveChunk(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pChunkIndices: *const u64,
    chunkBytesCount: usize,
    pChunkBytes: *mut u8,
) -> ZarrsResult {
    if array.is_null() || pChunkIndices.is_null() || pChunkBytes.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let indices = unsafe { slice::from_raw_parts(pChunkIndices, dimensionality) };
    match unsafe { &*array }.array.retrieve_chunk::<ArrayBytes<'static>>(indices) {
        Ok(bytes) => {
            let bytes: Vec<u8> = bytes.into_fixed().unwrap().into_owned();
            if bytes.len() > chunkBytesCount {
                set_error(format!("Buffer too small: need {} got {chunkBytesCount}", bytes.len()));
                return ZarrsResult::ZARRS_ERROR_BUFFER_LENGTH;
            }
            let out = unsafe { slice::from_raw_parts_mut(pChunkBytes, bytes.len()) };
            out.copy_from_slice(&bytes);
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayStoreChunk(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pChunkIndices: *const u64,
    chunkBytesCount: usize,
    pChunkBytes: *const u8,
) -> ZarrsResult {
    if array.is_null() || pChunkIndices.is_null() || pChunkBytes.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let indices = unsafe { slice::from_raw_parts(pChunkIndices, dimensionality) };
    let data = unsafe { slice::from_raw_parts(pChunkBytes, chunkBytesCount) }.to_vec();
    let array_bytes = zarrs::array::ArrayBytes::Fixed(std::borrow::Cow::Owned(data));
    match unsafe { &*array }.array.store_chunk(indices, array_bytes) {
        Ok(_) => ZarrsResult::ZARRS_SUCCESS,
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetChunkOrigin(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pChunkIndices: *const u64,
    pChunkOrigin: *mut u64,
) -> ZarrsResult {
    if array.is_null() || pChunkIndices.is_null() || pChunkOrigin.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let indices = unsafe { slice::from_raw_parts(pChunkIndices, dimensionality) };
    let arr = unsafe { &*array };
    match arr.array.chunk_origin(indices) {
        Ok(origin) => {
            let out = unsafe { slice::from_raw_parts_mut(pChunkOrigin, dimensionality) };
            for (i, &o) in origin.iter().enumerate() {
                out[i] = o;
            }
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetChunkShape(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pChunkIndices: *const u64,
    pChunkShape: *mut u64,
) -> ZarrsResult {
    if array.is_null() || pChunkIndices.is_null() || pChunkShape.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let indices = unsafe { slice::from_raw_parts(pChunkIndices, dimensionality) };
    let arr = unsafe { &*array };
    match arr.array.chunk_shape(indices) {
        Ok(chunk_shape) => {
            let out = unsafe { slice::from_raw_parts_mut(pChunkShape, dimensionality) };
            for (i, s) in chunk_shape.iter().enumerate() {
                out[i] = s.get();
            }
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

// ---------------------------------------------------------------------------
// Sharded arrays
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsArrayGetSubChunkShape(
    array: *mut ArrayHandle,
    dimensionality: usize,
    pIsSharded: *mut i32,
    pSubChunkShape: *mut u64,
) -> ZarrsResult {
    if array.is_null() || pIsSharded.is_null() || pSubChunkShape.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let arr = unsafe { &*array };

    // Check metadata for sharding codec
    let metadata = arr.array.metadata();
    let json_str = serde_json::to_string(&metadata).unwrap_or_default();
    if json_str.contains("sharding_indexed") {
        unsafe { *pIsSharded = 1 };
        // Parse inner chunk shape from metadata
        let metadata_val: serde_json::Value = serde_json::from_str(&json_str).unwrap_or_default();
        if let Some(codecs) = metadata_val.get("codecs").and_then(|c| c.as_array()) {
            for codec in codecs {
                if codec.get("name").and_then(|n| n.as_str()) == Some("sharding_indexed") {
                    if let Some(chunk_shape) = codec
                        .get("configuration")
                        .and_then(|c| c.get("chunk_shape"))
                        .and_then(|s| s.as_array())
                    {
                        let out = unsafe { slice::from_raw_parts_mut(pSubChunkShape, dimensionality) };
                        for (i, v) in chunk_shape.iter().enumerate() {
                            if i < dimensionality {
                                out[i] = v.as_u64().unwrap_or(0);
                            }
                        }
                        return ZarrsResult::ZARRS_SUCCESS;
                    }
                }
            }
        }
    }
    unsafe { *pIsSharded = 0 };
    ZarrsResult::ZARRS_SUCCESS
}

// ---------------------------------------------------------------------------
// Groups
// ---------------------------------------------------------------------------

struct GroupHandle {
    group: Group<dyn ReadableWritableListableStorageTraits>,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsCreateGroupRW(
    storage: *mut StorageHandle,
    path: *const c_char,
    metadata_json: *const c_char,
    pGroup: *mut *mut GroupHandle,
) -> ZarrsResult {
    if storage.is_null() || pGroup.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let path_str = match str_from_ptr(path) {
        Ok(s) => s,
        Err(r) => return r,
    };

    let store = unsafe { &*storage }.store.clone();

    // Parse metadata for attributes
    let attrs = if !metadata_json.is_null() {
        let meta_str = match str_from_ptr(metadata_json) {
            Ok(s) => s,
            Err(r) => return r,
        };
        let meta: serde_json::Value = serde_json::from_str(meta_str).unwrap_or_default();
        meta.get("attributes")
            .and_then(|a| a.as_object())
            .cloned()
            .unwrap_or_default()
    } else {
        serde_json::Map::new()
    };

    match Group::new_with_metadata(
        store,
        path_str,
        zarrs::group::GroupMetadata::V3(zarrs::group::GroupMetadataV3::new().with_attributes(attrs)),
    ) {
        Ok(group) => {
            if let Err(e) = group.store_metadata() {
                set_error(e.to_string());
                return ZarrsResult::ZARRS_ERROR_GROUP;
            }
            let handle = Box::new(GroupHandle { group });
            unsafe { *pGroup = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_GROUP
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsOpenGroupRW(
    storage: *mut StorageHandle,
    path: *const c_char,
    pGroup: *mut *mut GroupHandle,
) -> ZarrsResult {
    if storage.is_null() || pGroup.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let path_str = match str_from_ptr(path) {
        Ok(s) => s,
        Err(r) => return r,
    };

    let store = unsafe { &*storage }.store.clone();
    match Group::open(store, path_str) {
        Ok(group) => {
            let handle = Box::new(GroupHandle { group });
            unsafe { *pGroup = Box::into_raw(handle) };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_GROUP
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsDestroyGroup(group: *mut GroupHandle) -> ZarrsResult {
    if group.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    unsafe { drop(Box::from_raw(group)) };
    ZarrsResult::ZARRS_SUCCESS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsGroupGetAttributes(
    group: *mut GroupHandle,
    pretty: i32,
    pAttributes: *mut *mut c_char,
) -> ZarrsResult {
    if group.is_null() || pAttributes.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let attrs = unsafe { &*group }.group.attributes();
    let json = if pretty != 0 {
        serde_json::to_string_pretty(attrs)
    } else {
        serde_json::to_string(attrs)
    };
    match json {
        Ok(s) => {
            let cstr = CString::new(s).unwrap_or_default();
            unsafe { *pAttributes = cstr.into_raw() };
            ZarrsResult::ZARRS_SUCCESS
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_GROUP
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsGroupSetAttributes(
    group: *mut GroupHandle,
    attributes: *const c_char,
) -> ZarrsResult {
    if group.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let attrs_str = match str_from_ptr(attributes) {
        Ok(s) => s,
        Err(r) => return r,
    };
    let attrs: serde_json::Map<String, serde_json::Value> = match serde_json::from_str(attrs_str) {
        Ok(a) => a,
        Err(e) => {
            set_error(e.to_string());
            return ZarrsResult::ZARRS_ERROR_INVALID_METADATA;
        }
    };
    unsafe { &mut *group }.group.attributes_mut().clone_from(&attrs);
    ZarrsResult::ZARRS_SUCCESS
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsGroupStoreMetadata(
    group: *mut GroupHandle,
) -> ZarrsResult {
    if group.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    match unsafe { &*group }.group.store_metadata() {
        Ok(_) => ZarrsResult::ZARRS_SUCCESS,
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_GROUP
        }
    }
}

// ---------------------------------------------------------------------------
// Companion crate extensions
// ---------------------------------------------------------------------------

/// Resize an array.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsJlArrayResize(
    storage: *mut StorageHandle,
    path: *const c_char,
    ndim: usize,
    new_shape: *const u64,
) -> ZarrsResult {
    if storage.is_null() || new_shape.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let path_str = match str_from_ptr(path) {
        Ok(s) => s,
        Err(r) => return r,
    };
    let shape = unsafe { slice::from_raw_parts(new_shape, ndim) }.to_vec();
    let store = unsafe { &*storage }.store.clone();

    match Array::open(store, path_str) {
        Ok(mut array) => {
            if let Err(e) = array.set_shape(shape) {
                set_error(e.to_string());
                return ZarrsResult::ZARRS_ERROR_ARRAY;
            }
            match array.store_metadata() {
                Ok(_) => ZarrsResult::ZARRS_SUCCESS,
                Err(e) => {
                    set_error(e.to_string());
                    ZarrsResult::ZARRS_ERROR_ARRAY
                }
            }
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}

/// List directory children, returning a JSON array of strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsJlStorageListDir(
    storage: *mut StorageHandle,
    path: *const c_char,
    json_out: *mut *mut c_char,
) -> ZarrsResult {
    if storage.is_null() || json_out.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let path_str = match str_from_ptr(path) {
        Ok(s) => s,
        Err(r) => return r,
    };
    let store = unsafe { &*storage }.store.clone();

    let prefix = zarrs::storage::StorePrefix::new(path_str)
        .unwrap_or_else(|_| zarrs::storage::StorePrefix::root());

    match store.list_dir(&prefix) {
        Ok(entries) => {
            let mut children: Vec<String> = Vec::new();
            for key in entries.keys() {
                children.push(key.to_string());
            }
            for prefix in entries.prefixes() {
                children.push(prefix.as_str().to_string());
            }
            let json = serde_json::to_string(&children).unwrap_or_else(|_| "[]".to_string());
            match CString::new(json) {
                Ok(cstr) => {
                    unsafe { *json_out = cstr.into_raw() };
                    ZarrsResult::ZARRS_SUCCESS
                }
                Err(e) => {
                    set_error(e.to_string());
                    ZarrsResult::ZARRS_ERROR_STORAGE
                }
            }
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_STORAGE
        }
    }
}

/// Erase a specific chunk from an array.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsJlArrayEraseChunk(
    storage: *mut StorageHandle,
    path: *const c_char,
    ndim: usize,
    indices: *const u64,
) -> ZarrsResult {
    if storage.is_null() || indices.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let path_str = match str_from_ptr(path) {
        Ok(s) => s,
        Err(r) => return r,
    };
    let chunk_indices = unsafe { slice::from_raw_parts(indices, ndim) };
    let store = unsafe { &*storage }.store.clone();

    match Array::open(store, path_str) {
        Ok(array) => {
            match array.erase_chunk(chunk_indices) {
                Ok(_) => ZarrsResult::ZARRS_SUCCESS,
                Err(e) => {
                    set_error(e.to_string());
                    ZarrsResult::ZARRS_ERROR_ARRAY
                }
            }
        }
        Err(e) => {
            set_error(e.to_string());
            ZarrsResult::ZARRS_ERROR_ARRAY
        }
    }
}
