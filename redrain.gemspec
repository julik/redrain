require_relative "lib/redrain/version"

Gem::Specification.new do |spec|
  spec.name          = "redrain"
  spec.version       = Redrain::VERSION
  spec.authors       = ["Julik Tarkhanov"]
  spec.email         = ["me@julik.nl"]

  spec.summary       = "Ruby client for the Rain Issuing API."
  spec.description   = "Port of the official Rain Python SDK (rain-sdk). Covers the full " \
                       "Issuing API surface — applications, users, companies, cards, " \
                       "transactions, disputes, payments and signatures — with no runtime " \
                       "dependencies beyond stdlib. Not affiliated with Signify Holdings, Inc."
  spec.homepage      = "https://github.com/julik/redrain"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"]      = spec.homepage
  spec.metadata["source_code_uri"]   = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]   = "#{spec.homepage}/issues"
  # Custom property: machine-readable orientation doc for LLM agents wiring
  # this gem into a codebase. https://llmstxt.org/
  spec.metadata["llms_txt_uri"]    = "#{spec.homepage}/blob/main/llms.txt"

  # The library, its docs, and the design notes under llm/ — the port plan and
  # methodology explain why the client behaves as it does, which is worth having
  # to hand when this gem is vendored or read offline. The generator, its
  # vendored OpenAPI spec and the test suite stay out.
  spec.files = Dir[
    "lib/**/*.rb",
    "llm/**/*.md",
    "README.md", "LICENSE.txt", "CHANGELOG.md", "llms.txt"
  ]
  spec.require_paths = ["lib"]
  spec.bindir = "exe"

  # Development only. The gem itself has no runtime dependencies — a docs
  # toolchain must not become one for anyone who installs it.
  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "webmock",  "~> 3.23"
  spec.add_development_dependency "rake",     "~> 13.0"
  spec.add_development_dependency "yard",     "~> 0.9"
  # kramdown rather than redcarpet: redcarpet hands YARD ASCII-8BIT strings and
  # blows up on the UTF-8 in our docs (em dashes, "↔").
  spec.add_development_dependency "kramdown", "~> 2.4"
end
