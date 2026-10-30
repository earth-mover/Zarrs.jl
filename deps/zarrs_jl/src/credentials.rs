//! Refreshable credentials supplied by a Julia function.
//!
//! icechunk asks for fresh credentials from an `S3CredentialsFetcher` / `GcsCredentialsFetcher`,
//! on a Tokio worker thread. Julia code must never run on such a thread while a Julia thread is
//! blocked in a (GC-unsafe) `ccall`: a garbage collection would wait for the blocked thread
//! forever, and I/O in the callback cannot make progress (see `docs/src/icechunk.md`).
//!
//! So the fetchers here never call Julia. Instead:
//!
//! 1. `get()` queues a request `(request_id, callback_id)`, wakes Julia with `uv_async_send`
//!    (thread-safe, does not touch the Julia runtime) and awaits a oneshot reply, with a timeout.
//! 2. A Julia task woken by that `Base.AsyncCondition` takes requests with
//!    `zarrsCredentialsTakeRequest`, runs the user's Julia function as an ordinary task (it may do
//!    HTTP, allocate, trigger GC) and answers with `zarrsCredentialsProvideS3` /
//!    `zarrsCredentialsProvideGcs` (or `zarrsCredentialsProvideError`).
//! 3. For that task to run, the Julia thread must not itself be blocked inside the FFI call that
//!    triggered the request. Zarrs.jl therefore runs its blocking calls off-thread (a GC-safe
//!    `@threadcall` variant) once any refreshable credentials exist.
//!
//! Fetchers serialise as `{callback_id, pid}` only; a fetcher deserialised in another process
//! refuses to run, since the Julia function lives in the process that registered it.

use std::collections::{HashMap, VecDeque};
use std::ffi::{c_char, c_void};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};

use icechunk::config::{GcsBearerCredential, GcsCredentialsFetcher, S3CredentialsFetcher, S3StaticCredentials};

use super::{str_from_ptr, ZarrsResult};

/// Seconds a fetcher waits for Julia to answer before failing the icechunk operation.
const DEFAULT_TIMEOUT_SECS: u64 = 120;

type UvAsyncSend = unsafe extern "C" fn(*mut c_void) -> i32;

enum Reply {
    S3(S3StaticCredentials),
    Gcs(GcsBearerCredential),
}

struct Notifier {
    handle: usize,
    send: UvAsyncSend,
}

static NOTIFIER: Lazy<Mutex<Option<Notifier>>> = Lazy::new(|| Mutex::new(None));
static PENDING: Lazy<Mutex<VecDeque<(u64, u64)>>> = Lazy::new(|| Mutex::new(VecDeque::new()));
type Waiter = tokio::sync::oneshot::Sender<Result<Reply, String>>;
static WAITERS: Lazy<Mutex<HashMap<u64, Waiter>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);
/// The most recent credentials failure, not yet reported. Storage SDKs often reduce a failing
/// credentials provider to a generic error ("dispatch failure"), so `set_error` appends this.
static LAST_FAILURE: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

fn record_failure(msg: &str) {
    if let Ok(mut f) = LAST_FAILURE.lock() {
        *f = Some(msg.to_string());
    }
}

/// Take the last unreported credentials failure (called by `set_error`).
pub(crate) fn take_failure() -> Option<String> {
    LAST_FAILURE.lock().ok().and_then(|mut f| f.take())
}
static TIMEOUT_SECS: AtomicU64 = AtomicU64::new(DEFAULT_TIMEOUT_SECS);

/// Queue a request for `callback_id` and wake Julia. Returns the receiver for the reply.
fn request(callback_id: u64) -> Result<tokio::sync::oneshot::Receiver<Result<Reply, String>>, String> {
    let notifier = NOTIFIER.lock().map_err(|e| e.to_string())?;
    let notifier = notifier.as_ref().ok_or_else(|| {
        "refreshable credentials: no Julia credential service is registered".to_string()
    })?;
    let id = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = tokio::sync::oneshot::channel();
    WAITERS.lock().map_err(|e| e.to_string())?.insert(id, tx);
    PENDING.lock().map_err(|e| e.to_string())?.push_back((id, callback_id));
    // SAFETY: `handle` is a live uv_async_t owned by a Base.AsyncCondition that Julia keeps
    // alive for the life of the process; uv_async_send is safe to call from any thread.
    unsafe { (notifier.send)(notifier.handle as *mut c_void) };
    Ok(rx)
}

async fn await_reply(callback_id: u64, pid: u32) -> Result<Reply, String> {
    let result = await_reply_inner(callback_id, pid).await;
    if let Err(msg) = &result {
        record_failure(msg);
    }
    result
}

async fn await_reply_inner(callback_id: u64, pid: u32) -> Result<Reply, String> {
    if pid != std::process::id() {
        return Err(format!(
            "refreshable credentials (callback {callback_id}) were created in process {pid} and \
             cannot be used in another process"
        ));
    }
    let rx = request(callback_id)?;
    let secs = TIMEOUT_SECS.load(Ordering::Relaxed);
    match tokio::time::timeout(Duration::from_secs(secs), rx).await {
        Ok(Ok(reply)) => reply,
        Ok(Err(_)) => Err("refreshable credentials: the Julia credential service went away".into()),
        Err(_) => Err(format!(
            "refreshable credentials: no answer from Julia within {secs} s (is the calling \
             Julia thread blocked outside Zarrs.jl's off-thread calls?)"
        )),
    }
}

/// S3 credentials obtained from a Julia function (see the module docs).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JuliaS3CredentialsFetcher {
    pub callback_id: u64,
    pub pid: u32,
}

#[async_trait::async_trait]
#[typetag::serde(name = "zarrs_jl_julia_s3_callback")]
impl S3CredentialsFetcher for JuliaS3CredentialsFetcher {
    async fn get(&self) -> Result<S3StaticCredentials, String> {
        match await_reply(self.callback_id, self.pid).await? {
            Reply::S3(c) => Ok(c),
            Reply::Gcs(_) => {
                let msg = "refreshable credentials: expected S3 credentials, got a GCS token";
                record_failure(msg);
                Err(msg.into())
            }
        }
    }
}

/// GCS bearer tokens obtained from a Julia function (see the module docs).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JuliaGcsCredentialsFetcher {
    pub callback_id: u64,
    pub pid: u32,
}

#[async_trait::async_trait]
#[typetag::serde(name = "zarrs_jl_julia_gcs_callback")]
impl GcsCredentialsFetcher for JuliaGcsCredentialsFetcher {
    async fn get(&self) -> Result<GcsBearerCredential, String> {
        match await_reply(self.callback_id, self.pid).await? {
            Reply::Gcs(c) => Ok(c),
            Reply::S3(_) => {
                let msg = "refreshable credentials: expected a GCS token, got S3 credentials";
                record_failure(msg);
                Err(msg.into())
            }
        }
    }
}

fn expiry(unix_seconds: f64) -> Option<DateTime<Utc>> {
    if !unix_seconds.is_finite() || unix_seconds <= 0.0 {
        return None;
    }
    let secs = unix_seconds.floor() as i64;
    let nanos = ((unix_seconds - unix_seconds.floor()) * 1e9) as u32;
    Utc.timestamp_opt(secs, nanos).single()
}

fn opt(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    match str_from_ptr(ptr) {
        Ok("") | Err(_) => None,
        Ok(s) => Some(s.to_string()),
    }
}

fn reply(request_id: u64, value: Result<Reply, String>) -> ZarrsResult {
    // A missing waiter means the fetcher already timed out; that is not an error for Julia.
    if let Some(tx) = WAITERS.lock().ok().and_then(|mut w| w.remove(&request_id)) {
        let _ = tx.send(value);
    }
    ZarrsResult::ZARRS_SUCCESS
}

// ---------------------------------------------------------------------------
// FFI used by Zarrs.jl's credential service (never blocking)
// ---------------------------------------------------------------------------

/// Register the `uv_async_t` (from `Base.AsyncCondition`) and `uv_async_send` used to wake the
/// Julia credential service. Passing the function pointer avoids linking against libuv.
#[unsafe(no_mangle)]
pub extern "C" fn zarrsCredentialsSetNotifier(handle: *mut c_void, uv_async_send: *mut c_void) -> ZarrsResult {
    if handle.is_null() || uv_async_send.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    // SAFETY: Julia passes `cglobal(:uv_async_send)`, which has this signature.
    let send: UvAsyncSend = unsafe { std::mem::transmute(uv_async_send) };
    *NOTIFIER.lock().unwrap() = Some(Notifier { handle: handle as usize, send });
    ZarrsResult::ZARRS_SUCCESS
}

/// Seconds a fetcher waits for Julia before failing (default 120).
#[unsafe(no_mangle)]
pub extern "C" fn zarrsCredentialsSetTimeout(seconds: u64) -> ZarrsResult {
    TIMEOUT_SECS.store(seconds.max(1), Ordering::Relaxed);
    ZarrsResult::ZARRS_SUCCESS
}

/// Take one pending request into the outputs; request id 0 means the queue was empty.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsCredentialsTakeRequest(pRequestId: *mut u64, pCallbackId: *mut u64) -> ZarrsResult {
    if pRequestId.is_null() || pCallbackId.is_null() {
        return ZarrsResult::ZARRS_ERROR_NULL_PTR;
    }
    let (req, cb) = PENDING.lock().ok().and_then(|mut q| q.pop_front()).unwrap_or((0, 0));
    unsafe {
        *pRequestId = req;
        *pCallbackId = cb;
    }
    ZarrsResult::ZARRS_SUCCESS
}

/// Answer an S3 request. `expires_after` is seconds since the Unix epoch (NaN or <= 0: never).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsCredentialsProvideS3(
    request_id: u64,
    access_key_id: *const c_char,
    secret_access_key: *const c_char,
    session_token: *const c_char,
    expires_after: f64,
) -> ZarrsResult {
    let (Some(ak), Some(sk)) = (opt(access_key_id), opt(secret_access_key)) else {
        return reply(request_id, Err("refreshable credentials: empty access key or secret".into()));
    };
    reply(
        request_id,
        Ok(Reply::S3(S3StaticCredentials {
            access_key_id: ak,
            secret_access_key: sk,
            session_token: opt(session_token),
            expires_after: expiry(expires_after),
        })),
    )
}

/// Answer a GCS request with a bearer token. `expires_after` as for `zarrsCredentialsProvideS3`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsCredentialsProvideGcs(request_id: u64, bearer: *const c_char, expires_after: f64) -> ZarrsResult {
    let Some(bearer) = opt(bearer) else {
        return reply(request_id, Err("refreshable credentials: empty bearer token".into()));
    };
    reply(request_id, Ok(Reply::Gcs(GcsBearerCredential { bearer, expires_after: expiry(expires_after) })))
}

/// Answer a request with an error (for example, the Julia function threw).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zarrsCredentialsProvideError(request_id: u64, message: *const c_char) -> ZarrsResult {
    let msg = opt(message).unwrap_or_else(|| "unknown error".into());
    reply(request_id, Err(format!("refreshable credentials: the Julia function failed: {msg}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    static WAKES: AtomicUsize = AtomicUsize::new(0);
    // The request queue is process-global: run these tests one at a time.
    static SERIAL: Lazy<tokio::sync::Mutex<()>> = Lazy::new(|| tokio::sync::Mutex::new(()));
    unsafe extern "C" fn fake_send(_h: *mut c_void) -> i32 {
        WAKES.fetch_add(1, Ordering::SeqCst);
        0
    }

    fn setup() {
        let mut dummy = 0u8;
        zarrsCredentialsSetNotifier(&mut dummy as *mut u8 as *mut c_void, fake_send as *mut c_void);
    }

    fn take() -> Option<(u64, u64)> {
        let (mut r, mut c) = (0u64, 0u64);
        unsafe { zarrsCredentialsTakeRequest(&mut r, &mut c) };
        (r != 0).then_some((r, c))
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn round_trip_s3_and_errors() {
        let _serial = SERIAL.lock().await;
        setup();
        let f = JuliaS3CredentialsFetcher { callback_id: 7, pid: std::process::id() };
        let task = tokio::spawn(async move { f.get().await });
        // emulate the Julia service
        let (req, cb) = loop {
            if let Some(x) = take() { break x }
            tokio::time::sleep(Duration::from_millis(5)).await;
        };
        assert_eq!(cb, 7);
        let ak = std::ffi::CString::new("AK").unwrap();
        let sk = std::ffi::CString::new("SK").unwrap();
        unsafe { zarrsCredentialsProvideS3(req, ak.as_ptr(), sk.as_ptr(), std::ptr::null(), 2.0e9) };
        let creds = task.await.unwrap().unwrap();
        assert_eq!(creds.access_key_id, "AK");
        assert!(creds.session_token.is_none());
        assert_eq!(creds.expires_after.unwrap().timestamp(), 2_000_000_000);
        assert!(WAKES.load(Ordering::SeqCst) >= 1);

        // a Julia error becomes an icechunk error string
        let f = JuliaS3CredentialsFetcher { callback_id: 8, pid: std::process::id() };
        let task = tokio::spawn(async move { f.get().await });
        let (req, _) = loop {
            if let Some(x) = take() { break x }
            tokio::time::sleep(Duration::from_millis(5)).await;
        };
        let msg = std::ffi::CString::new("boom").unwrap();
        unsafe { zarrsCredentialsProvideError(req, msg.as_ptr()) };
        let err = task.await.unwrap().unwrap_err();
        assert!(err.contains("boom"), "{err}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn gcs_round_trip_and_wrong_kind() {
        let _serial = SERIAL.lock().await;
        setup();
        let f = JuliaGcsCredentialsFetcher { callback_id: 9, pid: std::process::id() };
        let task = tokio::spawn(async move { f.get().await });
        let (req, _) = loop {
            if let Some(x) = take() { break x }
            tokio::time::sleep(Duration::from_millis(5)).await;
        };
        let tok = std::ffi::CString::new("tok").unwrap();
        unsafe { zarrsCredentialsProvideGcs(req, tok.as_ptr(), f64::NAN) };
        let c = task.await.unwrap().unwrap();
        assert_eq!(c.bearer, "tok");
        assert!(c.expires_after.is_none());
    }

    #[tokio::test]
    async fn other_process_is_refused_and_serde_keeps_only_ids() {
        let f = JuliaS3CredentialsFetcher { callback_id: 3, pid: std::process::id().wrapping_add(1) };
        let err = f.get().await.unwrap_err();
        assert!(err.contains("another process"), "{err}");
        let boxed: Box<dyn S3CredentialsFetcher> = Box::new(JuliaS3CredentialsFetcher { callback_id: 3, pid: 42 });
        let json = serde_json::to_string(&boxed).unwrap();
        assert!(json.contains("zarrs_jl_julia_s3_callback") && json.contains("\"callback_id\":3"), "{json}");
        let back: Box<dyn S3CredentialsFetcher> = serde_json::from_str(&json).unwrap();
        assert!(format!("{back:?}").contains("pid: 42"));
    }

    #[tokio::test]
    async fn timeout_when_nobody_answers() {
        let _serial = SERIAL.lock().await;
        setup();
        zarrsCredentialsSetTimeout(1);
        let f = JuliaS3CredentialsFetcher { callback_id: 11, pid: std::process::id() };
        let err = f.get().await.unwrap_err();
        assert!(err.contains("no answer"), "{err}");
        zarrsCredentialsSetTimeout(DEFAULT_TIMEOUT_SECS);
        // drain the orphaned request so other tests are not confused
        while take().is_some() {}
    }
}
