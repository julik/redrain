# Project notes

`redrain` is a Ruby port of Rain's Python SDK (`rain-sdk`).

- `llm/plans/port-plan.md` — what we set out to build
- `llm/outputs/port-methodology.md` — how it was actually executed, which
  decisions were forced vs. judgement calls, the bugs review caught, and what
  is still open. Read this before changing the generator or the client's
  environment handling.
- `llm/outputs/mocking-rain.md` — Rain's data model, state machines and
  endpoint behaviours, for building a mock server or mock client.

## Generated code

`lib/redrain/models/` and `lib/redrain/resources/` are **generated** by
`rake generate` from `openapi/rain-issuing.json` + `dev/resource_map.yml`.
Never hand-edit them — fix `dev/generate.rb` and regenerate. The generator
must stay idempotent: `rake generate` on a clean tree leaves `git status` empty.

Everything else under `lib/` is hand-written and the generator never touches it.

## Testing

- **Use Minitest, not RSpec.** Tests live in `test/`, files named `*_test.rb`,
  classes inherit from `Minitest::Test`. Run with `rake test` or
  `ruby -Ilib -Itest test/<file>_test.rb`.
- Test helper: `test/test_helper.rb` (sets `$LOAD_PATH` and requires
  `minitest/autorun` + `webmock/minitest` + `redrain`).
- Use WebMock for HTTP stubbing. Integration tests under `test/integration/`
  hit the real dev API and are skipped unless `RAIN_API_KEY` is set.

## Ruby

- Target Ruby 3.1+ (`.ruby-version` pins 3.4.4).
- **Prefer endless `def` for single-expression methods.**
  - Good fit: simple readers / delegators / one-line predicates / aliases.
    `def size = @count`, `def valid? = !empty?`.
  - Skip when the body needs `begin/rescue`, mutation across multiple lines,
    or a `yield` block where the classic form is more readable.
  - For methods that genuinely do nothing, use `def foo = nil`.
- No runtime dependencies. Stdlib only (`net/http`, `json`, `uri`, `zlib`).

## API shape

Public call sites mirror the Python SDK method-for-method — see
`tmp/rain-sdk-python/api.md`. Wire format is camelCase; everything Ruby-side
is snake_case, mapped in `lib/redrain/model.rb`.
