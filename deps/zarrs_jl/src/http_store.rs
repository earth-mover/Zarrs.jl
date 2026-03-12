//! A simple read-only HTTP object store that tolerates servers (e.g. Cloudflare)
//! which omit the `Content-Length` header from responses.

use std::fmt;
use std::ops::Range;

use async_trait::async_trait;
use futures::stream::BoxStream;
use object_store::{
    CopyOptions, GetOptions, GetRange, GetResult, GetResultPayload, ListResult, MultipartUpload,
    ObjectMeta, ObjectStore, PutMultipartOptions, PutOptions, PutPayload, PutResult, Result,
    path::Path,
};
use reqwest::{Client, Response, StatusCode, header};
use url::Url;

/// A read-only HTTP [`ObjectStore`] that tolerates missing `Content-Length` headers.
#[derive(Debug)]
pub struct SimpleHttpStore {
    client: Client,
    base_url: Url,
}

impl SimpleHttpStore {
    pub fn new(url: &str) -> std::result::Result<Self, String> {
        let client = Client::builder()
            .http1_only()
            .no_gzip()
            .no_brotli()
            .no_zstd()
            .no_deflate()
            .build()
            .map_err(|e| format!("Failed to build HTTP client: {e}"))?;

        let mut base_url =
            Url::parse(url).map_err(|e| format!("Failed to parse URL '{url}': {e}"))?;

        // Ensure trailing slash so path joining works correctly
        if !base_url.path().ends_with('/') {
            base_url.set_path(&format!("{}/", base_url.path()));
        }

        Ok(Self { client, base_url })
    }

    fn full_url(&self, location: &Path) -> String {
        let path = location.as_ref();
        match self.base_url.join(path) {
            Ok(u) => u.to_string(),
            Err(_) => format!("{}{}", self.base_url, path),
        }
    }
}

impl fmt::Display for SimpleHttpStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SimpleHttpStore({})", self.base_url)
    }
}

fn not_implemented(op: &str) -> object_store::Error {
    object_store::Error::NotImplemented {
        operation: op.into(),
        implementer: "SimpleHttpStore".into(),
    }
}

fn map_reqwest_error(e: reqwest::Error, location: &Path) -> object_store::Error {
    if e.status() == Some(StatusCode::NOT_FOUND) {
        object_store::Error::NotFound {
            path: location.to_string(),
            source: Box::new(e),
        }
    } else {
        object_store::Error::Generic {
            store: "SimpleHttpStore",
            source: Box::new(e),
        }
    }
}

fn check_status(status: StatusCode, location: &Path, url: &str) -> Result<()> {
    if status == StatusCode::NOT_FOUND {
        return Err(object_store::Error::NotFound {
            path: location.to_string(),
            source: "Not Found".into(),
        });
    }
    if status == StatusCode::NOT_MODIFIED {
        return Err(object_store::Error::NotModified {
            path: location.to_string(),
            source: "Not Modified".into(),
        });
    }
    if status == StatusCode::PRECONDITION_FAILED {
        return Err(object_store::Error::Precondition {
            path: location.to_string(),
            source: "Precondition Failed".into(),
        });
    }
    if !status.is_success() {
        return Err(object_store::Error::Generic {
            store: "SimpleHttpStore",
            source: format!("HTTP {status} for {url}").into(),
        });
    }
    Ok(())
}

fn extract_etag(headers: &header::HeaderMap) -> Option<String> {
    headers
        .get(header::ETAG)
        .and_then(|v| v.to_str().ok())
        .map(String::from)
}

fn extract_last_modified(headers: &header::HeaderMap) -> chrono::DateTime<chrono::Utc> {
    headers
        .get(header::LAST_MODIFIED)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| chrono::DateTime::parse_from_rfc2822(v).ok())
        .map(|dt| dt.with_timezone(&chrono::Utc))
        .unwrap_or_else(chrono::Utc::now)
}

fn extract_content_length(headers: &header::HeaderMap) -> Option<u64> {
    headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
}

fn parse_content_range(headers: &header::HeaderMap) -> Option<(Range<u64>, u64)> {
    let value = headers.get(header::CONTENT_RANGE)?.to_str().ok()?;
    // Format: "bytes start-end/total"
    let bytes_part = value.strip_prefix("bytes ")?;
    let (range_part, total_part) = bytes_part.split_once('/')?;
    let total = total_part.parse::<u64>().ok()?;
    let (start, end) = range_part.split_once('-')?;
    let start = start.parse::<u64>().ok()?;
    let end = end.parse::<u64>().ok()? + 1; // HTTP ranges are inclusive, Rust exclusive
    Some((start..end, total))
}

fn build_meta(location: &Path, response: &Response, size: u64) -> ObjectMeta {
    ObjectMeta {
        location: location.clone(),
        last_modified: extract_last_modified(response.headers()),
        size,
        e_tag: extract_etag(response.headers()),
        version: None,
    }
}

#[async_trait]
impl ObjectStore for SimpleHttpStore {
    async fn put_opts(
        &self,
        _location: &Path,
        _payload: PutPayload,
        _opts: PutOptions,
    ) -> Result<PutResult> {
        Err(not_implemented("put_opts"))
    }

    async fn put_multipart_opts(
        &self,
        _location: &Path,
        _opts: PutMultipartOptions,
    ) -> Result<Box<dyn MultipartUpload>> {
        Err(not_implemented("put_multipart_opts"))
    }

    async fn get_opts(&self, location: &Path, options: GetOptions) -> Result<GetResult> {
        let url = self.full_url(location);

        // For head-only requests, use Range: bytes=0-0 to discover total size
        // from Content-Range, since some CDNs omit Content-Length from HEAD.
        if options.head {
            let response = self
                .client
                .get(&url)
                .header(header::RANGE, "bytes=0-0")
                .send()
                .await
                .map_err(|e| map_reqwest_error(e, location))?;

            let status = response.status();
            check_status(status, location, &url)?;

            let total_size = parse_content_range(response.headers())
                .map(|(_, total)| total)
                .or_else(|| extract_content_length(response.headers()))
                .unwrap_or(0);

            let meta = build_meta(location, &response, total_size);
            return Ok(GetResult {
                payload: GetResultPayload::Stream(Box::pin(futures::stream::empty())),
                meta,
                range: 0..0,
                attributes: Default::default(),
            });
        }

        let mut request = self.client.get(&url);

        if let Some(ref range) = options.range {
            let range_header = match range {
                GetRange::Bounded(r) => format!("bytes={}-{}", r.start, r.end.saturating_sub(1)),
                GetRange::Offset(offset) => format!("bytes={offset}-"),
                GetRange::Suffix(suffix) => format!("bytes=-{suffix}"),
            };
            request = request.header(header::RANGE, range_header);
        }

        if let Some(ref etag) = options.if_none_match {
            request = request.header(header::IF_NONE_MATCH, etag.as_str());
        }

        if let Some(ref etag) = options.if_match {
            request = request.header(header::IF_MATCH, etag.as_str());
        }

        let response = request
            .send()
            .await
            .map_err(|e| map_reqwest_error(e, location))?;

        let status = response.status();
        check_status(status, location, &url)?;

        let content_length = extract_content_length(response.headers());

        // For range responses, parse Content-Range to get byte range and total size
        let (range, total_size) = if status == StatusCode::PARTIAL_CONTENT {
            parse_content_range(response.headers()).unwrap_or_else(|| {
                let len = content_length.unwrap_or(0);
                (0..len, len)
            })
        } else {
            (0..content_length.unwrap_or(0), content_length.unwrap_or(0))
        };

        let meta = build_meta(location, &response, total_size);

        // Read the full body — lets us determine size when Content-Length is missing
        let body_bytes = response.bytes().await.map_err(|e| object_store::Error::Generic {
            store: "SimpleHttpStore",
            source: Box::new(e),
        })?;

        let actual_size = body_bytes.len() as u64;
        let meta_size = if meta.size > 0 { meta.size } else { actual_size };
        let actual_range = if range.end == 0 && range.start == 0 {
            0..actual_size
        } else {
            range
        };

        let meta = ObjectMeta {
            size: meta_size,
            ..meta
        };

        Ok(GetResult {
            payload: GetResultPayload::Stream(Box::pin(futures::stream::once(async move {
                Ok(body_bytes)
            }))),
            meta,
            range: actual_range,
            attributes: Default::default(),
        })
    }

    fn delete_stream(
        &self,
        _locations: BoxStream<'static, Result<Path>>,
    ) -> BoxStream<'static, Result<Path>> {
        Box::pin(futures::stream::once(async {
            Err(not_implemented("delete_stream"))
        }))
    }

    fn list(&self, _prefix: Option<&Path>) -> BoxStream<'static, Result<ObjectMeta>> {
        Box::pin(futures::stream::once(async {
            Err(not_implemented("list"))
        }))
    }

    async fn list_with_delimiter(&self, _prefix: Option<&Path>) -> Result<ListResult> {
        Err(not_implemented("list_with_delimiter"))
    }

    async fn copy_opts(&self, _from: &Path, _to: &Path, _options: CopyOptions) -> Result<()> {
        Err(not_implemented("copy_opts"))
    }
}
