# Changelog

## Unreleased

- Initial port of the Rain Python SDK (`rain-sdk`) to Ruby.
- Covers all 60 endpoints of Rain Issuing API v1.2.1.
- Models and resources generated from the vendored OpenAPI spec via `rake generate`.
- Cursor pagination helper (`auto_paging_each`) on the collection resources.
- Full YARD documentation, including the generated models and resources
  (`rake doc`). YARD is a development dependency only.
- No runtime dependencies beyond stdlib.
