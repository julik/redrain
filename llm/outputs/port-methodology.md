# How the Rain SDK port was executed

Companion to `llm/plans/port-plan.md`. The plan says what we intended to build;
this says what we actually did, which decisions were forced, which were
judgement calls, and which are still open. Written for whoever picks this up
after a Rain API bump, or has to defend a choice made here.

Ticket: [ZAY-433](https://linear.app/onside/issue/ZAY-433/create-a-ruby-port-of-python-rain-sdk).
Precedent: [`julik/ramplitude`](https://github.com/julik/ramplitude), our earlier
port of the Amplitude Python SDK — its `CLAUDE.md` and port plan set the
conventions used here.

---

## 1. What we started from

`rain-sdk-python` is **Stainless-generated**. That single fact drove everything
that follows.

| | Lines |
| --- | --- |
| Upstream `src/` | 21,052 (35,186 including its tests) |
| Our hand-written core | 1,012 |
| Our generated `lib/` | 3,165 |
| Our generator | 1,277 |
| Our hand-written tests | 1,111 (+650 generated) |

60 endpoints across 48 paths; 16 named component schemas in the spec.

Most of that is machinery with no Ruby analogue: an httpx-based
`_base_client`, pydantic models, a full async mirror of every resource,
`with_raw_response` / `with_streaming_response` wrappers, and hand-rolled
`_transform` / `_qs` / `_compat` shims for Python typing. Transcribing them
would have produced a large, strange Ruby codebase that no Rubyist would
recognise and that nobody could maintain.

The decisive find was in `tmp/rain-sdk-python/.stats.yml`: the URL of the
**OpenAPI document the SDK is generated from**, publicly fetchable (HTTP 200,
~200 KB pretty-printed). That is the actual source of truth — the Python SDK is
one rendering of it, and ours is another.

## 2. The structural decision: generate, don't transcribe

**Decision: port against the spec, and keep a generator in the repo.**

Three options were on the table. The user chose the third:

1. *Hand-write everything, spec as reference.* Readable, no build step, but 60
   endpoints and ~45 model types is a lot of transcription and every field name
   is a chance to typo something that only fails in production.
2. *Throwaway generator, commit and hand-polish the output.* Typo-proof once,
   then immediately stale.
3. **Keep the generator as a rake task.** Regenerable whenever Rain ships a new
   version.

The cost of (3) is real and worth naming: we are re-implementing a slice of
Stainless. The justification is that this SDK will be re-generated — Rain is a
vendor under evaluation, their API will move, and a `rake generate` that
reproduces the whole surface from a diffable spec beats a manual sweep across
20 files.

The boundary is enforced, not merely documented:

```
lib/redrain/{client,http_client,model,resource,errors,page,upload}.rb   hand-written
lib/redrain/models/       ← generated, committed, banner says "do not edit"
lib/redrain/resources/    ← generated, committed
test/resources/           ← generated, committed
dev/generate.rb           ← the generator
```

The generator **prunes** files it no longer emits, so a removed endpoint can't
leave an orphan behind that still loads and still looks real.

### 2.1 The part the spec can't tell you

An OpenAPI document describes routes. It does not say that
`PATCH /applications/company/{companyId}/ubo/{uboId}` should be reachable as
`client.applications.company.ubo.update(ubo_id, company_id:)`. Stainless keeps
that resource tree in its own config, which is not published.

So `dev/resource_map.yml` holds it — 60 rows of `"VERB /path" → resource.method`,
derived mechanically from the Python SDK's `api.md` rather than typed out. All
60 rows paired against the spec with **zero unmapped routes on the first
attempt**, which is the evidence that the mapping is faithful.

That file is also the drift alarm. `rake generate` **aborts** if the map and the
spec disagree about which routes exist:

```
dev/resource_map.yml is out of sync with the spec.
  In the spec but not the map:
    POST /cards/{cardId}/replace
```

A Rain API bump therefore cannot quietly leave a gap. `rake sync_spec` re-fetches
the published spec and reports added/removed routes and schemas without
overwriting anything — adopting a new spec should be a decision, not a side
effect.

## 3. Schema decisions

Only 16 schemas are named in the spec; every request body and most response
bodies are inline. The generator has to name them.

**Response classes reproduce Stainless's naming rule** — singular leaf resource
+ method + `Response`, so `applications.company.retrieve` →
`CompanyRetrieveResponse`. Not because that rule is elegant, but because it
makes our types line up with the Python SDK's `api.md`, which then doubles as
documentation for this gem.

**`allOf` → Ruby inheritance.** The first `$ref` member becomes the superclass,
remaining inline members merge into the body. `IssuingUser < IssuingApplication`
falls out naturally, matching what pydantic did.

**`oneOf` → one class with a discriminator.** The spec has two unions —
`IssuingTransaction` (spend/collateral/payment/fee) and `IssuingSignature`
(pending/ready). Ruby has no union type worth pattern-matching, so variants are
merged into a single permissive class: only properties required by *every*
variant stay required, and the discriminator gets predicates.

```ruby
transaction.spend?              # => true
transaction.spend.merchant_name
transaction.fee                 # => nil
```

Two wrinkles surfaced while merging, both fixed in the generator:

- Each variant described the shared `id` from its own point of view. Naively
  merging left whichever came last, so `IssuingTransaction#id` was documented as
  *"The identifier of the fee transaction"* — actively wrong for three of the
  four variants. Conflicting descriptions are now dropped rather than inherited.
- The discriminator itself inherited a single-value enum (`One of: fee`). It's
  now replaced with the union of all variant values.

**Enums are documented, not enforced.** Named string enums become a module with
a frozen `VALUES` array; inline ones become a doc comment. Nothing validates on
read: spec enums drift, and rejecting a response because Rain added a status is
strictly worse than surprising the caller with an unfamiliar string.

## 4. The model layer

**Unknown keys are never dropped.** `@raw` keeps the body exactly as Rain sent
it; `#[]` reads anything by wire name; `#to_h` round-trips it. Rain adding a
field must not break a running integration. This is the single most important
property of the model layer and it has a test.

**camelCase on the wire, snake_case in Ruby**, via a `field` DSL with an `api:`
override. `nil` means *not given* everywhere and is stripped before the request
— it is never sent as JSON `null`.

**A non-Hash where the spec promised an object** is parked under a reserved
`_unexpected` key rather than silently producing an empty model. That mirrors
how the HTTP layer keeps an unparseable error body as text instead of losing the
diagnosis.

## 5. Divergences from the Python SDK

Everything else mirrors Python method-for-method. These four don't:

| Divergence | Why |
| --- | --- |
| `auto_paging_each` added | Rain's list endpoints are cursor-paginated and return bare arrays. Python makes every caller write the loop. `limit` is clamped to Rain's cap of 100 — asking for 500 and treating the capped page as "short" would end the walk after one page. |
| Base URL precedence replaces the "ambiguous URL" raise | See §5.1. |
| Async, streaming, response wrappers, `_strict_response_validation` dropped | No Ruby analogue worth the code. |
| `RAIN_CUSTOM_HEADERS` env var dropped | `default_headers:` covers it without parsing a newline-delimited env var. |

### 5.1 `environment:` — the one API design argument

Python defaults `environment` to `"dev"` and raises if you set both
`RAIN_BASE_URL` and `environment`, on the reasoning that it can't know which you
meant.

We were asked to make `environment` "required, defaulting to `:dev`". Those are
mutually exclusive in Ruby, so it was put back to the user, who chose: **keep
the `:dev` default, but make it visible in the signature and validate strictly.**

That choice has a consequence that had to be worked through. Once the default is
in the signature, the client can no longer distinguish *"caller passed `:dev`"*
from *"caller passed nothing"* — they are the same call. Python's ambiguity
raise depended on exactly that distinction, so keeping it would have meant the
error firing for everyone who sets `RAIN_BASE_URL`. It was replaced with plain
precedence:

```
base_url:  >  RAIN_BASE_URL  >  environment:
```

The environment is validated **even when it loses**, so `environment: :prod`
raises immediately rather than passing silently and surfacing the day the
override is removed. A private sentinel could have preserved Python's behaviour
exactly; predictable precedence was judged better than a heuristic that guesses
at intent.

### 5.2 Terminology note

`:dev` and `:production` are **the Python SDK's shorthand**, not Rain's. Rain's
spec calls the two hosts "Development server" and "Production server". The
labels were carried over so call sites match Python. See §9 for the open
question about what the dev host actually is.

## 6. Bugs found in review

An adversarial review pass over the hand-written core found issues that testing
alone had not. Two were serious enough to have shipped as silent data loss. All
are fixed with regression tests; they are recorded here because the fixes look
arbitrary without the failure they prevent.

**A retried multipart upload sent an empty file.** `Upload#read` was called
inside the retry loop, so a `File` or `IO` drained by the first attempt returned
`""` on the second. Rain answers 502, the retry uploads a zero-byte identity
document, and the call returns **success**. Fixed by materialising uploads once
before the loop and memoising `#read`.

Worth noting how this one landed: the first fix memoised inside `Upload`, and
its own regression test proved that insufficient — `Upload.coerce` was called
per attempt, so each retry wrapped the already-drained IO in a *fresh* `Upload`.
The test failed, and the fix moved up a level.

**Multipart crashed on any non-ASCII field or filename.** The body buffer starts
binary but is only ASCII-*only*; the first UTF-8 field value promoted it to
UTF-8, and appending the file's bytes then raised
`Encoding::CompatibilityError`. A selfie named `identité.heic` was enough. Every
append is now forced to binary.

**Path params could reach a different endpoint.** `URI.encode_www_form_component`
leaves `.` untouched, so `cards.retrieve("..")` produced `GET /cards/../pin`,
which a normalising proxy resolves to a different endpoint. It's also the *form*
encoder — a space became `+`, silently corrupting ids. Now escaped per RFC 3986
with `.`/`..` rejected outright.

Also fixed: `Errno::ETIMEDOUT` and friends escaped unwrapped and unretried (now
`SystemCallError`, so one `rescue Redrain::APIConnectionError` covers the
network); `Time` query params went out in Ruby's `to_s` format, which Rain's date
filters don't accept; an already-elapsed `Retry-After` collapsed the backoff to
zero; and `#to_h` handed out the model's live internal hash.

**On thread safety:** a single `Client` is safe to share across Puma threads.
`HTTPClient#perform` builds a fresh `Net::HTTP` per request and keeps no mutable
per-request state. The memoisation hashes are now initialised in constructors so
only entries race, never the containers, and their values are pure functions of
immutable input — a race costs an allocation, not correctness.

## 7. Things that fought back

Recorded so nobody re-derives them.

**Ruby class/module collision.** The first resource layout gave each node its
own file with nested `module` declarations. That cannot work: `Ubo` must be both
the class backing `client.applications.company.ubo` *and* the namespace holding
`Document`. Now one file per top-level resource, with children nested as classes
inside their parent's body, emitted above the `sub_resource` calls that name them.

**YARD reads `{anything}` as a link.** The generated `# GET /cards/{cardId}`
comments produced 47 unresolvable-link warnings. Backslash-escaping `\{` works in
isolation but not in this pipeline — verified, not assumed. Routes are now
emitted with `:cardId` placeholders instead.

**redcarpet returns ASCII-8BIT.** It crashes YARD against the UTF-8 in our docs
(`—`, `↔`, `café`). Switched to kramdown, which is pure Ruby.

**`.yardopts` is read as binary.** An em dash in `--title` poisoned every
rendered page with the same encoding crash. That file must stay ASCII.

**YARD can't see DSL-defined readers.** `field :first_name, ...` defines a method
at runtime that YARD never sees, so the generator emits `@!attribute [r]` +
`@return` directives alongside each field.

## 8. What was verified, and how

Claims in the README that would otherwise be aspirational:

| Claim | How it's checked |
| --- | --- |
| All 60 endpoints reachable | `test/coverage_test.rb` walks `resource_map.yml` and asserts every operation resolves to a real method on a real object |
| Generated code really came from the spec | `rake generate` on a clean tree leaves `git status` empty |
| Zero runtime dependencies | `ruby --disable-gems -Ilib -e 'require "redrain"'` |
| The packaged gem works | Built the `.gem`, installed into a throwaway `GEM_HOME`, required it from outside the repo with no Bundler |
| Nothing private ships | The `.gem` holds 52 files — `lib/` plus four docs, nothing from `tmp/`, `test/`, `dev/`, `openapi/` or `doc/` |
| Runs on the stated Ruby floor | Parsed and loaded under 3.2 as well as 3.4 |

173 tests, 383 assertions, no failures. The generated suite covers all 60
endpoints and asserts the camelCase mapping — the stubs match on query and body
shape, so a mis-mapped parameter fails rather than passing unnoticed.

Integration tests under `test/integration/` hit the real dev API and skip unless
`RAIN_API_KEY` is set. They exist for the two things WebMock cannot vouch for:
multipart encoding and octet-stream downloads. **They have not been run** — see
below.

## 9. Open questions

**What is `api-dev.raincards.xyz`?** Rain's spec describes it only as
"Development server". Neither the spec nor the Python SDK's README contains the
words "sandbox", "test mode" or "staging" — grep returns zero hits across all
three. So it is unconfirmed whether it is a sandbox with test cards and fake
money, or a shared internal deployment that happens to be publicly routable.

This matters twice over: it decides whether defaulting `environment:` to `:dev`
is a harmless convenience or a bad default inherited from Python, and it decides
whether the integration tests — which upload a document — are safe to run. It is
a question for Rain, not something derivable from the artifacts.

**Linting.** No RuboCop or Standard. Adding one means a dev dependency plus
reconciling ~3,800 lines of generated code, and the generator would have to emit
conforming output forever rather than accumulating a `.rubocop_todo.yml`. Worth
doing deliberately or not at all.

**`IssuingChargeCreateChargeResponse`** is named from the spec's component name;
Python calls it `IssuingChargeCreateResponse`. Ours follows the spec, which is
the more defensible source, at the cost of one name not matching Python exactly.

## 10. Re-running this for a new Rain version

```sh
rake sync_spec   # re-fetch, report added/removed routes and schemas
                 # writes the upstream copy to tmp/, changes nothing
# read the diff, then:
#   move it to openapi/rain-issuing.json, update openapi/stats.yml,
#   reconcile dev/resource_map.yml with any route changes
rake generate    # aborts if the map and spec disagree
rake test
rake doc
```

Fix generator bugs **at the generator**, never in its output — the next
`rake generate` will overwrite it, and the idempotency check will catch you.
