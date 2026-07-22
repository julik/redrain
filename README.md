# Redrain

A Ruby client for [Rain](https://www.raincards.xyz/)'s Issuing API — a port of
the official [Rain Python SDK](https://github.com/SignifyHQ/rain-sdk-python).
Same call shapes as the Python SDK, snake_case throughout, no runtime
dependencies beyond stdlib.

> **Trademark notice.** "Rain" is a trademark of Signify Holdings, Inc. This
> project is an independent, unofficial Ruby client and is **not** affiliated
> with, endorsed by, or sponsored by Signify Holdings. The name "Redrain" is a
> portmanteau ("Ruby" + "Rain") chosen to make that relationship clear. For the
> official SDK see <https://github.com/SignifyHQ/rain-sdk-python>.

> Status: covers all 60 endpoints of Issuing API v1.2.1. Not yet shipped to RubyGems.

## Install

```ruby
gem "redrain"
```

## Quick start

```ruby
require "redrain"

rain = Redrain::Client.new(api_key: ENV.fetch("RAIN_API_KEY"), environment: :production)

user = rain.users.create(email: "ada@example.com", first_name: "Ada", last_name: "Lovelace")
user.id            # => "3fa85f64-..."
user.first_name    # => "Ada"       — snake_case reader over the wire's `firstName`

card = rain.users.create_card(user.id, type: "virtual")
rain.cards.list(user_id: user.id, status: "active")
rain.balances.retrieve.credit_limit
```

The API key also falls back to `RAIN_API_KEY`, so `Redrain::Client.new` alone works.

## Environments

| `environment:` | Base URL |
| --- | --- |
| `:dev` (default) | `https://api-dev.raincards.xyz/v1/issuing` |
| `:production` | `https://api.raincards.xyz/v1/issuing` |

The default is `:dev`, matching the Python SDK — reaching production is a
deliberate act.

Base URL precedence, highest first: `base_url:`, then the `RAIN_BASE_URL`
environment variable, then `environment:`. The environment is validated even
when a URL overrides it, so `environment: :prod` raises immediately rather than
passing silently and surfacing the day the override is removed.

## Resources

Every method mirrors the Python SDK's, so
[their `api.md`](https://github.com/SignifyHQ/rain-sdk-python/blob/main/api.md)
reads as documentation for this gem too.

```ruby
rain.applications.company.create(name:, address:, entity:, ...)
rain.applications.company.ubo.update(ubo_id, company_id:, first_name: "Ada")
rain.applications.company.ubo.document.upload(ubo_id, company_id:, document: File.open("id.png"))
rain.applications.user.create(ip_address:, occupation:, ...)

rain.balances.retrieve
rain.cards.retrieve(card_id)
rain.cards.retrieve_secrets(card_id)
rain.cards.pin.update(card_id, encrypted_pin_block: "...")
rain.companies.charge(company_id, amount: 1500, description: "Late fee")
rain.companies.signatures.retrieve_payment_signature(company_id, token:, amount:, admin_address:)
rain.contracts.list
rain.disputes.update(dispute_id, status: "canceled")
rain.keys.create(name: "ci")
rain.payments.initiate(chain_id: 1, ...)
rain.transactions.create_dispute(transaction_id, reason: "fraud", ...)
rain.users.delete(user_id)
```

Optional parameters default to `nil` and are dropped before the request goes
out, so `nil` means "not sent" — never `null` on the wire.

## Responses

Responses come back as typed objects with snake_case readers:

```ruby
card = rain.cards.retrieve(card_id)
card.status                # "active"
card.limit.amount          # nested models all the way down
card.created_at            # a Time, parsed from ISO 8601
```

Fields Rain adds that this gem doesn't know about are never dropped:

```ruby
card["someBrandNewField"]  # read anything by its wire name
card.to_h                  # the raw body exactly as Rain sent it
card.to_snake_h            # Ruby-side view: snake_case keys, coerced values
```

`IssuingTransaction` and `IssuingSignature` are unions in the spec. They come
back as one object with a discriminator and predicates:

```ruby
transaction = rain.transactions.retrieve(id)
transaction.spend?         # => true
transaction.spend.merchant_name
transaction.fee            # => nil
```

## Pagination

Rain's list endpoints are cursor-paginated. Drive it yourself with
`cursor:`/`limit:`, or let the pager do it:

```ruby
rain.transactions.auto_paging_each(user_id: user.id) { |txn| puts txn.id }

# Without a block you get an Enumerator, so lazy chains work:
rain.cards.auto_paging_each.lazy.select { |c| c.status == "active" }.first(5)
```

## File uploads

The document, evidence and receipt endpoints take a file. Anything readable works:

```ruby
rain.applications.user.upload_document(application_id, document: File.open("id.png"), type: "idCard")
rain.applications.user.upload_document(application_id, document: Pathname("id.png"), type: "idCard")
rain.disputes.evidence.upload(dispute_id, name: "Receipt", type: "receipt", evidence: bytes)
```

Filename and content type are inferred where possible. When they matter and
can't be inferred — an in-memory PDF, say — be explicit:

```ruby
Redrain::Upload.new(bytes, filename: "receipt.pdf", content_type: "application/pdf")
```

The two download endpoints return the bytes as a `String`:

```ruby
File.binwrite("receipt.pdf", rain.transactions.receipt.retrieve(transaction_id))
```

## Errors

Everything derives from `Redrain::Error`.

| Class | Raised when |
| --- | --- |
| `Redrain::ConfigurationError` | Missing API key, unknown environment, malformed base URL |
| `Redrain::BadRequestError` | 400 |
| `Redrain::AuthenticationError` | 401 |
| `Redrain::PermissionDeniedError` | 403 |
| `Redrain::NotFoundError` | 404 |
| `Redrain::ConflictError` | 409 |
| `Redrain::UnprocessableEntityError` | 422 |
| `Redrain::RateLimitError` | 429 |
| `Redrain::InternalServerError` | 5xx |
| `Redrain::APITimeoutError` | The request timed out |
| `Redrain::APIConnectionError` | DNS, TLS, refused or reset connection |

`APIStatusError` carries `#status`, `#body`, `#headers`, `#request_id` and
`#error_message` — quote the request id when you talk to Rain support.

```ruby
begin
  rain.users.retrieve(id)
rescue Redrain::NotFoundError
  nil
rescue Redrain::APIStatusError => e
  Rails.logger.warn("Rain #{e.status} (#{e.request_id}): #{e.error_message}")
  raise
end
```

## Retries and timeouts

408, 409, 429 and 5xx responses, plus connection failures, are retried twice by
default with jittered exponential backoff from 0.5s to 8s, honouring
`Retry-After`. 4xx responses other than those are never retried.

```ruby
Redrain::Client.new(
  api_key: ...,
  timeout: 60,       # read timeout, seconds
  open_timeout: 5,   # connect timeout, seconds
  max_retries: 2,    # 0 disables retrying
  default_headers: { "X-Tenant" => "zay" }
)
```

## Regenerating from the spec

`lib/redrain/models/` and `lib/redrain/resources/` are generated from the
vendored OpenAPI document — never edit them by hand.

```sh
rake generate    # rebuild models, resources and endpoint smoke tests
rake sync_spec   # re-fetch Rain's spec and report what changed
rake test        # 173 offline tests; the generated ones cover all 60 endpoints
rake doc         # YARD docs into doc/ — 100% documented, zero warnings
```

`dev/resource_map.yml` maps each route to its Ruby resource and method name —
the one thing the spec can't tell us, transcribed from the Python SDK so the
call sites match. `rake generate` refuses to run if the map and the spec
disagree about which routes exist, so a Rain API bump can't quietly leave a gap.

Integration tests hit the real dev API and skip unless `RAIN_API_KEY` is set:

```sh
RAIN_API_KEY=... bundle exec rake test
```

## What was left out of the port

The Python SDK is Stainless-generated; most of its 35k lines have no Ruby
analogue. Deliberately not ported: the async client, streaming, the
`with_raw_response`/`with_streaming_response` wrappers, `_strict_response_validation`,
and the `RAIN_CUSTOM_HEADERS` env var (pass `default_headers:` instead).

## License

MIT
