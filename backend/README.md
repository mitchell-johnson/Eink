# Private e-ink image service

Cloudflare Worker + one SQLite Durable Object per image job + a private R2 bucket.
The iPhone app supplies its own access token; the OpenAI API key stays in a Worker
secret. The public health endpoint contains no configuration or credentials.

Generation uses the Responses API with fixed mainline model `gpt-5.6-luna` and
exactly one `image_generation` tool call using `gpt-image-2.5-sunburst`. Settings
are fixed in source: 1024×768, medium quality, opaque PNG, no stored Responses
conversation. No fallback model, caller-selected URL, tool, quality, or system
instructions are accepted. The native app reduces the PNG to 400×300 and the
four exact panel colors before displaying it.

## API contract

All endpoints except `GET /health` require `Authorization: Bearer <APP_ACCESS_TOKEN>`.
Bearer credentials are compared with constant-time equality of SHA-256 digests.
All responses, including PNGs, carry `Cache-Control: private, no-store`.

| Endpoint | Result |
|---|---|
| `GET /health` | `200 {"ok":true}` |
| `GET /v1/config` | `200 {"model":"gpt-image-2.5-sunburst","width":400,"height":300,"palette":["#000000","#FFFFFF","#FFFF00","#FF0000"],"ready":true}` |
| `PUT /v1/jobs/{UUID}` | JSON body `{"prompt":"A red flower"}`. `202` when created, `200` for an identical replay, `409` if that ID has different content. |
| `GET /v1/jobs/{UUID}` | The saved job, or `404`. Never initiates generation. |
| `GET /v1/jobs/{UUID}/image` | Private `image/png`; `409` while unavailable, `404` for an unknown job, `410` after expiration. |

Job JSON:

```json
{
  "id": "91bf840c-09e7-484e-9b6e-4aba937fe001",
  "status": "queued",
  "model": "gpt-image-2.5-sunburst"
}
```

`status` is `queued`, `running`, `succeeded`, or `failed`. Failed jobs include
`error: {"code":"stable_code","message":"Readable explanation"}`. HTTP failures
use `{"error":{"code":"stable_code","message":"Readable explanation"}}`.
Job status retrieval itself returns HTTP 200 even when generation failed.

The request body is limited to 16 KiB, and `prompt` to 4096 UTF-8 bytes. Blank
prompts and additional JSON properties are rejected. Prompt identity is byte
exact, including whitespace. UUID case is normalized. Three new IDs are admitted
per rolling minute for this private application; concurrent retries reserve only
one slot. Replays and polling do not consume admission quota. A `429` response
includes `Retry-After: 60`. This is a request-rate guard, not a monetary budget;
set an appropriate project budget in the OpenAI account as well.

`ready` means an OpenAI key is configured. It does not make a paid API call or
prove that the account can use the requested model. Model access/quota problems
become explicit failed jobs; raw provider messages and credentials are not sent
to the client.

## Recovery, cancellation, and retention

The app should save a newly generated UUID and its prompt **before** PUT. If it
loses the connection, use GET or replay the same PUT with the same UUID. A new
UUID means a new paid request. If GET returns 404 after an uncertain PUT, replay
the original PUT rather than allocating a new ID. Poll about every two seconds
while foregrounded, with backoff for network errors and service failures.

Closing the app or cancelling its wait stops polling. It does not cancel the
already accepted generation or promise a refund. Keep the UUID so the result
can be recovered later. There is deliberately no misleading server cancellation
endpoint: the provider may continue billing after a network abort.

The create transaction persists the queued job and alarm atomically. The alarm
persists `running` and a watchdog before making the one allowed OpenAI request.
It waits at most 180 seconds, including reading the bounded provider response.
Cloudflare alarm delivery is at least once; if a restarted alarm finds `running`,
it records `generation_interrupted` instead of making another paid call. Network
loss or timeout can therefore produce an unknown provider outcome. Neither the
backend nor polling retries generation automatically. An explicit user action
with a new UUID is required for another attempt.

PNGs expire 24 hours after job creation. Reads enforce the expiration immediately;
an alarm deletes the R2 object, retrying deletion if storage is temporarily
unavailable. Completed/failed jobs discard prompt text. An expired job retains
only its ID, prompt hash, model, expiration and failed state. This small permanent
tombstone prevents an old retry from silently becoming a second paid request.
Deleting job storage or changing the Durable Object namespace would remove that
protection; do not reset production job storage as a routine deployment step.

## Rendering instructions

The actual Responses `instructions` field constrains composition to flat 4:3
artwork using black, white, yellow, and red only. It prohibits gradients, shadows,
gray, transparency, photographs of a screen, and device mockups; requests safe
8-pixel margins, minimum 2-pixel strokes, and text around 16 pixels tall or larger
at final panel size. Explicitly quoted user text is preserved. QR/barcode areas
remain blank for a trusted generator. Prompt content cannot select operational
settings or replace these instructions. These instructions guide the model;
the native app's deterministic palette conversion is the final color guarantee.

## Local verification

Node 22 or newer:

```sh
cd backend
npm ci
npm run types
npm run check
npm test
npm run build
```

`build` is a Wrangler dry run and creates no cloud resources. Tests use the actual
Workers runtime with local SQLite Durable Objects and R2. OpenAI fetches are
mocked, including the stalled-request test; no real key or paid generation is
needed. The test configuration injects visibly fake credentials. Wrangler may
warn about production secrets missing while loading that test configuration.

The compatibility date is `2026-09-11`, matching the installed workerd release.
Binding types are generated by Wrangler and checked in.

## Deployment setup

Deploy your own instance with your Cloudflare account. Authenticate using
`npx wrangler login`; choose your account through the CLI or private
`CLOUDFLARE_ACCOUNT_ID` environment variable. No account ID is committed.
Choose a Worker name and bucket name in `wrangler.jsonc` before deploying:

1. Create the private bucket with `npx wrangler r2 bucket create label-images`
   (or choose another name and update `wrangler.jsonc`). Do not enable public R2
   access or configure an `r2.dev` URL.
2. Store a random, high-entropy app token using `npx wrangler secret put APP_ACCESS_TOKEN`.
   Use at least 32 random bytes; provision the same value separately into the
   native app's Keychain settings. Do not embed it in source, screenshots, logs,
   a build setting, or the app bundle.
3. Store the OpenAI project key with `npx wrangler secret put OPENAI_API_KEY`.
   Never provision this key to the phone.
4. Run `npm run deploy`. The configuration declares both SQLite classes without
   manual migrations, and the deployment attaches the existing private bucket.
5. Enter the resulting HTTPS Worker URL and app token in the app. Verify public
   health, authenticated configuration, and then one deliberately authorized
   generation. Keep the original job UUID during any retries.

Secrets can be stored in an ignored `.dev.vars` file for local manual development.
`wrangler dev` uses simulated R2/DO storage, but a real OpenAI key makes real paid
requests. The automated test suite always overrides it with fake credentials.

## Documentation sources

- [OpenAI image generation](https://developers.openai.com/api/docs/guides/image-generation):
  Responses tool model selection, output settings, and custom sizes. 1024×768 meets
  Sunburst's documented dimension and pixel-count constraints.
- [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna):
  Supports the Responses image generation tool.
- [GPT Image 2.5 Sunburst](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst):
  The requested image model.
- [Durable Object alarms](https://developers.cloudflare.com/durable-objects/api/alarms/):
  Persistent scheduling and at-least-once delivery.
- [Workers best practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/):
  Secret bindings, generated types, bounded reads, and observability.

Checked against official documentation on 2026-09-14.

## Runtime compatibility

Provider requests use `redirect: "manual"` and explicitly reject every 3xx
response, so credentials never follow a redirect. The Workers runtime does not
support `redirect: "error"`. Tests validate actual Request construction as well
as provider failures, idempotency, authentication, limits and retention.
