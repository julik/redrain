# Build `Rain::FakeClient` in zay-payouts-backend

Instructions for an agent implementing a fake Rain client, scoped to the
endpoints that have direct analogues in our existing Kulipa integration.

**Repo:** `zay-payouts-backend` (Rails). **Gem under test:** `redrain`, a Ruby
client for Rain's Issuing API, in a sibling checkout at `../redrain`.

---

## 1. Read these first

| Path | Why |
| --- | --- |
| `lib/kulipa/fake_client.rb` | **The template.** 1,100 lines, 51 methods. Copy its structure, conventions and level of rigour. |
| `lib/kulipa/fake_data_generator.rb` | Lazy seeding pattern. |
| `app/models/fake_remote_entity.rb` | The state store. Provider-agnostic, already shared by Kulipa and Privy. |
| `app/models/kulipa_card.rb` (`#kulipa_client`) | The `when "stub"` provider-routing convention. |
| `test/services/issue_kulipa_card_test.rb` | Test style to match. |
| `AGENTS.md` | House rules. Minitest under `test/`, never new RSpec. |
| `../redrain/llm/outputs/mocking-rain.md` | Rain's data model, enums, state machines, per-endpoint behaviour. **The reference for every field name.** |
| `../redrain/openapi/rain-issuing.json` | Source of truth. If anything here disagrees with it, the spec wins. |

---

## 2. The one structural difference from Kulipa

`Kulipa::Client#get_user` returns `get("users/#{id}").body` — **a raw camelCase
Hash**. So `Kulipa::FakeClient` returns hashes and matches trivially.

**`redrain` returns typed `Redrain::Model` objects.** A fake returning hashes is
not a drop-in — every call site breaks on `card.status` vs `card["status"]`.

Resolution: store camelCase hashes in `FakeRemoteEntity#data` exactly as Kulipa
does, and wrap on the way out.

```ruby
def retrieve(card_id)
  Redrain::IssuingCard.from_api(find_entity!(card_id, CARD_ENTITY_TYPE, "Card").data)
end
```

Storage identical to Kulipa's; one line converts. This is not a detail — it means
fake-client tests still exercise `redrain`'s real camelCase→snake_case mapping,
type coercion, nested models, `Time` parsing and unknown-key passthrough. Do not
hand-roll lookalike objects.

**Second difference:** `Kulipa::Client` is flat (`client.get_card`). `redrain` is
a nested resource tree (`client.cards.retrieve`, `client.users.create_card`,
`client.applications.user.initiate`). The fake must mirror that nesting — a root
object with memoised sub-resource readers. More classes than Kulipa's fake; that
is what makes it a drop-in.

```ruby
rain = Rain::FakeClient.new
user = rain.users.create(first_name: "Ada", last_name: "Lovelace", email: "a@b.com")
card = rain.users.create_card(user.id, type: "virtual")
rain.cards.update(card.id, status: "locked")          # Kulipa's freeze_card
rain.transactions.list(user_id: user.id, type: "spend")
```

---

## 3. Scope: what to build

Only what has a Kulipa analogue **and** is mocked in `Kulipa::FakeClient`.
**18 of Rain's 60 endpoints.** Every one verified to exist on `redrain`'s
generated surface.

### In scope

| Kulipa fake method | Rain endpoint | `redrain` call |
| --- | --- | --- |
| `initiate_kyc` | `POST /applications/user/initiate` | `applications.user.initiate` |
| — (KYC application body) | `POST /applications/user` | `applications.user.create` |
| `get_kyc`, `list_kycs` | `GET /applications/user/{userId}` | `applications.user.retrieve` |
| — | `PATCH /applications/user/{userId}` | `applications.user.update` |
| KYC document upload | `PUT /applications/user/{userId}/document` | `applications.user.upload_document` |
| `create_user` | `POST /users` | `users.create` |
| `get_user` | `GET /users/{userId}` | `users.retrieve` |
| `set_user_email`, `set_user_phone_number` | `PATCH /users/{userId}` | `users.update` |
| — | `GET /users` | `users.list` |
| `get_user_balance`, `get_wallet_balance` | `GET /users/{userId}/balances` | `users.retrieve_balances` |
| `create_card` | `POST /users/{userId}/cards` | `users.create_card` |
| `get_card` | `GET /cards/{cardId}` | `cards.retrieve` |
| `list_cards` | `GET /cards` | `cards.list` |
| `freeze_card`, `unfreeze_card`, `revoke_card` | `PATCH /cards/{cardId}` | `cards.update` |
| `generate_pan_token`, `redeem_pan_token` | `GET /cards/{cardId}/secrets` | `cards.retrieve_secrets` |
| `list_card_payments`, `list_top_ups`, `list_withdrawals` | `GET /transactions` | `transactions.list` |
| `create_withdrawal` | `POST /users/{userId}/payments` | `users.initiate_payment` |
| `find_withdrawal` | `GET /transactions/{transactionId}` | `transactions.retrieve` |

### Out of scope — do not build

42 endpoints, by group:

| # | Area | Why |
| --- | --- | --- |
| 18 | `companies.*`, `applications.company.*`, `…ubo.*`, `companies.signatures.*` | Rain's corporate/UBO flow. Kulipa is consumer-only; no analogue. |
| 5 | `disputes.*`, `transactions.create_dispute` | Kulipa has 3DS authentication, not disputes. Different problem. |
| 4 | `signatures.*`, `users.signatures.*` | On-chain signing. No Kulipa analogue. |
| 2 | `keys.*` | API key management. Not mocked for Kulipa. |
| 2 | `contracts.list`, `users.retrieve_contracts` | Collateral contract plumbing. Adjacent to Kulipa wallets but not equivalent — do not force the mapping. |
| 2 | `transactions.receipt.*` | Receipt upload/download. Not mocked for Kulipa. |
| 2 | `cards.pin.*` | Rain has PIN endpoints; `Kulipa::FakeClient` does not mock PIN. Out by the stated rule. |
| 2 | `balances.retrieve`, `payments.initiate` | Account-wide variants. Use the user-scoped `users.retrieve_balances` / `users.initiate_payment`. |
| 1 | `users.delete` | Not mocked for Kulipa (`Privy::FakeClient#delete_user` raises `NotImplementedError`). |
| 1 | `users.create_charge` | Levying fees. No Kulipa analogue. |
| 1 | `transactions.update` | Sets a memo. No Kulipa analogue. |
| 1 | `applications.user.reapply` | **Borderline** — Kulipa re-runs KYC via `initiate_kyc` rather than a distinct reapply. Left out; revisit if the KYC flow needs it. |

If a call site turns out to need something on this list, **add it deliberately
and note why** — don't quietly widen scope.

### Kulipa concepts with no Rain equivalent

Do not invent endpoints for these. Rain models them differently or not at all:

- **Wallets** (`get_wallet`, `verify_wallet`) — Rain has no wallet resource. A
  user carries a `walletAddress` string; collateral lives in contracts.
- **3DS authentication** (`accept_3ds_authentication`, `reject_3ds_authentication`) —
  absent from Rain's spec.
- **Card reissue** (`reissue_card`) — no Rain endpoint. Closest is cancel via
  `cards.update(status: "canceled")` then `users.create_card`.
- **`list_allowed_countries`** — no Rain endpoint.
- **Webhooks.** `Kulipa::FakeClient` emits them (`emit_card_webhook`,
  `emit_withdrawal_webhook`). **Rain's OpenAPI document contains zero mentions
  of webhooks or callbacks** — verified by grep. Rain very likely has them; they
  are simply not in this spec. **Do not invent a webhook shape.** Flag it as an
  open question for whoever owns the Rain relationship, and leave the fake
  polling-only for now.

---

## 4. Design

### 4.1 Storage

Reuse `FakeRemoteEntity` with `provider: "rain"`. **No migration needed.**

| `entity_type` | Holds |
| --- | --- |
| `user` | `IssuingUser` wire hash (includes the application fields) |
| `card` | `IssuingCard` wire hash |
| `transaction` | `IssuingTransaction` wire hash — `{id, type, <payload>}` |

Rain has no separate application record: `IssuingUser` **inherits from
`IssuingApplication`**, so `applicationStatus` / `applicationReason` /
`applicationCompletionLink` live on the same user hash. `applications.user.retrieve`
and `users.retrieve` therefore read the same row and must return the same `id`.

### 4.2 Ids

**Rain ids are bare UUIDs** — `format: uuid`, no `usr-`/`crd-` prefix. Do not
carry Kulipa's prefix convention across. Use `SecureRandom.uuid`.

`redrain` escapes path params per RFC 3986 and rejects `.`/`..`, so a malformed
id surfaces as a client-side `ArgumentError`, not a 404.

### 4.3 Money

**Integer cents everywhere.** `creditLimit`, `amount`, `balanceDue`,
`spendingPower`. The sole exception is `CollateralTransaction.amount`, typed
`number` in the spec — preserve that; don't normalise it.

### 4.4 Errors

Raise real `redrain` classes so `rescue` clauses in app code get exercised:

```ruby
raise Redrain::NotFoundError.new(
  "Card not found",
  status: 404,
  body: {"message" => "Card not found"},
  headers: {"x-request-id" => "fake-#{SecureRandom.hex(4)}"}
)
```

Available: `BadRequestError` (400), `AuthenticationError` (401),
`PermissionDeniedError` (403), `NotFoundError` (404), `ConflictError` (409),
`UnprocessableEntityError` (422), `RateLimitError` (429),
`InternalServerError` (5xx). All carry `#status`, `#body`, `#headers`,
`#request_id`, `#error_message`.

Mirror Kulipa's `find_entity!(remote_id, entity_type, label)` helper.

### 4.5 State machines — enforce them

This is where a fake earns its keep. Copy Kulipa's `validate_status!` approach.

**Card status:** `notActivated` → `active` ⇄ `locked` → `canceled`. Cards start
`notActivated`; `canceled` is terminal. `cards.update` must reject illegal
transitions with `Redrain::UnprocessableEntityError`.

Kulipa's verbs map onto status writes:

| Kulipa | Rain |
| --- | --- |
| `freeze_card` | `cards.update(id, status: "locked")` |
| `unfreeze_card` | `cards.update(id, status: "active")` |
| `revoke_card` | `cards.update(id, status: "canceled")` |

Rain has **no `reason` parameter** on card status changes. Kulipa's
`VALID_REVOKE_REASONS` has no counterpart — drop it.

**ApplicationStatus:** `approved`, `pending`, `needsInformation`,
`needsVerification`, `manualReview`, `denied`, `locked`, `canceled`. Rain
documents the values but **not the transitions** — see the graph in
`mocking-rain.md §3`, and treat it as inference, not contract.

**Spend transaction status:** `pending` → `completed` | `reversed` | `declined`.
A `declined` spend carries `declinedReason`.

**Invariant worth enforcing:** only an `approved` user gets a working card; only
an `active` card authorises a spend.

### 4.6 Transactions are a tagged union

`{id, type, <payload>}` where the payload key equals `type`. Kulipa's three list
methods collapse into one Rain endpoint filtered by `type`:

| Kulipa | Rain filter |
| --- | --- |
| `list_card_payments` | `transactions.list(type: "spend")` |
| `list_top_ups` | `transactions.list(type: "collateral")` |
| `list_withdrawals` | `transactions.list(type: "payment")` |

**Emit only the matching payload key.** `redrain` merges the four variants into
one class with predicates, so emitting all four makes `spend?` and `fee?`
simultaneously true and the model meaningless.

```json
{"id": "…", "type": "spend",
 "spend": {"amount": 4250, "currency": "USD", "merchantName": "Blue Bottle",
           "status": "completed", "cardId": "…", "userId": "…"}}
```

Field lists per variant: `mocking-rain.md §2.3`.

> **Preserve this quirk:** `postedAt` is `date-time` on `collateral` and `fee`
> but a bare `string` on `spend` and `payment`, so `redrain` returns a `Time` for
> two variants and a `String` for the other two. Don't normalise — you'd hide a
> real inconsistency.

### 4.7 Pagination — this differs from Kulipa

Kulipa's fake uses **page-based** paging (`limit:`, `from_page:`).
**Rain is cursor-based.** Do not copy `paginate`.

- `limit` — min 1, **max 100**, default 20. Clamp it.
- `cursor` — the id of the resource *after* which to start.
- Response is a **bare array**. No envelope, no `total`, no `nextCursor`.
- **Ordering must be stable** (insertion order is fine). `redrain`'s
  `auto_paging_each` cursors on the last record's id and stops on a short page —
  unstable ordering makes it loop or skip.

Supported filters, all optional and AND-combined:

- `cards.list` — `company_id`, `user_id`, `status`
- `users.list` — `company_id`
- `transactions.list` — `company_id`, `user_id`, `card_id`, `type`,
  `transaction_hash`, `authorized_before`, `authorized_after`, `posted_before`,
  `posted_after`

Implement at least one date filter so that path is exercised.

### 4.8 Balances

`users.retrieve_balances` returns five **integer-cent** fields: `creditLimit`,
`pendingCharges`, `postedCharges`, `balanceDue`, `spendingPower`.

**Derive them from stored transactions, not fixed values** — a fake where a spend
doesn't move `pendingCharges` won't catch the bugs worth catching:

```
pendingCharges = Σ spend where status == "pending"
postedCharges  = Σ spend + fee where status == "completed"
balanceDue     = postedCharges − Σ completed payments
spendingPower  = creditLimit − pendingCharges − balanceDue
```

This is a plausible reading of the field names, **not documented by Rain**.
Leave a comment saying so.

### 4.9 Card secrets

`cards.retrieve_secrets` → `{encryptedPan: {iv, data}, encryptedCvc: {iv, data}}`.

Rain's model is one-shot encrypted retrieval — **not** Kulipa's two-step
`generate_pan_token` → `redeem_pan_token`. Collapse both into this single call.

Return plausible base64 in the exact envelope; no real crypto needed. **Never put
a real PAN here**, even in a fake — the field is named `encrypted*` and someone
will eventually log it.

### 4.10 Test levers

Mirror Kulipa's explicit state drivers. Name them so they can never be mistaken
for API methods:

```ruby
Rain::FakeClient.force_application_status!(user_id, "approved")
Rain::FakeClient.post_transaction!(user_id:, card_id:, type: "spend", amount: 4250)
Rain::FakeClient.advance_transaction!(transaction_id, status: "completed")
```

Kulipa precedent: `force_kyc_outcome`, `simulate_external_card_event`,
`FakeClient.advance_withdrawal!`.

### 4.11 Wiring

Follow the existing convention — a `provider` column on the record, routed
per-call. **Not** a global config flag:

```ruby
def rain_client
  case provider
  when "rain" then Redrain::Client.new(api_key: RainConfig.api_key, environment: RainConfig.environment)
  when "stub" then Rain::FakeClient.new
  end
end
```

Note `environment:` defaults to `:dev`, **not** production — always pass it
explicitly. Valid values are `:dev` and `:production` only.

---

## 5. Deliverables

```
lib/rain/fake_client.rb              # root + memoised sub-resource readers
lib/rain/fake_client/users.rb        # users.*  (+ create_card, initiate_payment, retrieve_balances)
lib/rain/fake_client/cards.rb        # cards.*  (+ retrieve_secrets)
lib/rain/fake_client/transactions.rb # transactions.*
lib/rain/fake_client/applications.rb # applications.user.*
lib/rain/fake_data_generator.rb      # lazy seeding, mirrors Kulipa's
test/lib/rain/fake_client_test.rb
test/lib/rain/fake_client_conformance_test.rb   # see §6 — do not skip
```

Split by resource; a single 1,100-line file was fine for Kulipa's flat client but
won't be for a nested tree.

---

## 6. The conformance test — mandatory

**`redrain`'s surface is generated** from Rain's OpenAPI spec by `rake generate`.
It moves whenever Rain ships a new version. A hand-written fake drifts silently,
and a fake that lies is worse than no fake.

Reflect over the real classes. This catches **both** missing methods and
signature drift:

```ruby
COVERAGE = {
  Redrain::Resources::Users        => Rain::FakeClient::Users,
  Redrain::Resources::Cards        => Rain::FakeClient::Cards,
  Redrain::Resources::Transactions => Rain::FakeClient::Transactions
}.freeze

# Only the methods we chose to implement — see §3.
IMPLEMENTED = {
  Redrain::Resources::Users => %i[create retrieve update list create_card
                                  initiate_payment retrieve_balances],
  # …
}.freeze

test "the fake matches redrain's generated surface" do
  COVERAGE.each do |real, fake|
    IMPLEMENTED.fetch(real).each do |name|
      assert real.method_defined?(name), "#{real} no longer has ##{name} — redrain changed"
      assert fake.method_defined?(name), "#{fake} is missing ##{name}"
      assert_equal real.instance_method(name).parameters.sort,
                   fake.instance_method(name).parameters.sort,
                   "#{fake}##{name} signature drift"
    end
  end
end
```

Assert in **both directions**: a method vanishing from `redrain` is as important
as one missing from the fake. The first means Rain removed an endpoint.

Verified working — on a deliberately stale fake this correctly reported four
missing methods and one signature drift (`cards.list` missing `user_id:`/`status:`).

---

## 7. What this does NOT test — state it in the PR

A fake client bypasses everything below the client object. Not covered:

- multipart encoding (document upload)
- `application/octet-stream` responses
- retry semantics (408/409/429/5xx, twice, jittered, honouring `Retry-After`)
- the `Api-Key` header and auth failures
- HTTP status → exception mapping
- JSON encode/decode

That is ~6 behaviours, not 60 — and it is where `redrain`'s three
review-caught bugs lived, all silent-failure (a retry uploading a zero-byte file
while returning success). **Don't try to make the fake cover this.** The gem's
`test/integration/` suite already does, skipping unless `RAIN_API_KEY` is set.
Recommend running it against Rain's dev API on a schedule.

---

## 8. Pitfalls

- **Don't return raw hashes.** Wrap in `Redrain::` models (§2).
- **Don't emit all four transaction payload keys** — only the one matching `type`.
- **Don't copy Kulipa's page-based pagination.** Rain is cursor-based (§4.7).
- **Don't add `usr-`/`crd-` id prefixes.** Rain ids are bare UUIDs.
- **Don't invent a webhook shape.** Not in Rain's spec; flag it instead.
- **Don't invent a `reason` parameter** on card status changes.
- **Don't return unstable list ordering** — the pager cursors on the last id.
- **Don't let `limit: 500` return 500 records.** Rain caps at 100.
- **Don't normalise the `postedAt` type inconsistency** (§4.6).
- **Don't put real PANs, PINs or personal data in fixtures.**
- **Don't return snake_case from the store.** `FakeRemoteEntity#data` holds
  camelCase wire hashes; `redrain` does the conversion. Snake_case in the store
  produces models where every declared field is `nil` and every value sits in the
  unknown-key passthrough — quiet, and confusing to diagnose.

## 9. Open questions to raise, not guess

1. **Webhooks.** Kulipa's fake emits them; Rain's spec documents none. How does
   Rain notify us of authorisations, KYC outcomes and settlement? This shapes
   whether the integration is poll-based or event-based, and the fake can't be
   finished honestly without an answer.
2. **`api-dev.raincards.xyz`** — sandbox with test cards, or a shared dev
   deployment? Rain's spec says only "Development server". Decides whether
   integration tests are safe to run.
3. **ApplicationStatus transitions** — which are legal? The spec lists values
   only.
4. **Balance semantics** — is the §4.8 arithmetic right? Inferred from field
   names.
