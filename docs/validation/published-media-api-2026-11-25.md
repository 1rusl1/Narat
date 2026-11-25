# Accepted published-media API — C2 / ID-B

Accepted private commit `5e442540bf59977ebcb11b811cb5e2c56cf9edf4`, source base `9f811ad06e7ecb5730d62a66370fba4d149b5f98`, checked FP `0912fbf314018ef0c125e3312e7f27ef6c1eb4fe0d898337fa54303a1be1455f`. Internal app-module API in GuestCatalogueView.swift append footer; existing file contents untouched. Foundation only, no Browse/result UI wiring or T175 completion.

## Value

`PublishedPlantImageSource(url: URL?, author: String? = nil, license: String? = nil, attribution: String? = nil, sourcePage: URL? = nil)` — Equatable/Hashable/Sendable. Raw published credit is joined from nonempty author/license/attribution. `safeURL(_:)` accepts HTTPS with nonempty host and no username/password. Source link uses the same check.

Map catalogue `card.heroImage?.downloadURL/author/license/attribution/sourcePage` or ID-A `publishedFacts.imageURL/imageAuthor/imageLicense/imageAttribution/imageSourcePage` directly. Do not pass personal/observation photo URLs, owner IDs or authenticated API routes. No fact generation or attribution substitution.

## Loader

`@MainActor PublishedPlantImageLoader(session: URLSession? = nil, capacity: Int = 8, costLimit: Int = 16 * 1024 * 1024)`; `load(_ source: PublishedPlantImageSource) async throws -> UIImage`. Default `.shared` exists. `publicConfiguration()` creates dedicated ephemeral configuration; do NOT reuse CatalogueConnection/Supabase transport.

Default session: no cookies, credential storage, URLCache, additional headers; request Accept PNG/JPEG only. Injection accepts dedicated trusted public URLSession with nil delegate/background identifier/cookie storage/credential storage/cache, cookies disabled and empty extra headers/proxy dictionary. Custom protocolClasses are a trusted test seam and must obey the same public-transport contract. Per-task delegate rejects redirects and non-TLS auth challenges; TLS uses system trust. No global URLProtocol registration.

**C2 fixture:** use `PublishedPlantImageLoader.publicConfiguration()`, set scoped protocolClasses, create URLSession, inject loader. Do not add namespace header to configuration: extra headers are rejected. Encode unique fixture namespace in image URL/host/path and dispatch inside that scoped protocol; never fetch internet as fixture fallback. Use unique per-case URLs to avoid public-URL cache collisions. Caller invalidates its injected session when finished; loader invalidates only sessions it owns.

Cache holds successful decoded images FIFO by URL, default 8 entries /16 MiB decoded cost; capacity/cost are clamped. Payload max4 MiB, PNG/JPEG only, original max40M pixels/20000 eachside, decoded larger side max1024. Failure/cancel not cached. No persistent cache, owner queue, bulk download, coalescing framework or automatic retry loop.

## View / state

`PublishedPlantImageView(source: source, presentation: .thumbnail | .hero, label: String, locale: Locale = Locale(identifier: "en"), loader: PublishedPlantImageLoader = .shared)`. Thumbnail56×56; hero240high/max640wide, aspect fit. Hero shows raw credit and safe source Link. Missing/loading/failure states are honest with EN/PL labels. Caller sets stable row/view accessibility identifier and distinguishes **example** photo from personal original.

View uses `.task(id: source)` + `onDisappear` cancellation. `@MainActor PublishedPlantImageState` exposes read-only `phase` (.missing/.loading/.ready(UIImage)/.failed), `load(_:using:) async`, `cancel()`. Generation/task checks prevent late source replacement/disappear publication. Existing Root/Store/source authority remains caller responsibility; this public bitmap cache has no owner/session/snapshot authority.

## Verification and integration limits

Seven tests: PNG privacy/credit/cache hit; JPEG FIFO eviction/failure retry; badHTTP/MIME/decode/oversize; unsafeURL0transport; unsafe injected session; held cancellation+retry; source replacement/disappear. Actual530Swift tests/527methods, Release,149automation +highReviewQA PASS. Rendering geometry/dark/DynamicType/live images not visually verified here. UI wiring remains separate, old Connection/Browse/auth/savedcard bodies and all old tests are exact prefixes.
