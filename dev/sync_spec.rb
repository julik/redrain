# frozen_string_literal: true

# Re-fetches the upstream OpenAPI spec and reports how it differs from the
# vendored copy. Run with `rake sync_spec` when Rain announces an API version.
#
# It does not overwrite anything: a spec bump usually needs a look at the diff
# and an edit to dev/resource_map.yml before `rake generate` will even run.

require "json"
require "yaml"
require "net/http"
require "uri"
require "fileutils"

ROOT     = File.expand_path("..", __dir__)
STATS    = YAML.load_file(File.join(ROOT, "openapi", "stats.yml"))
VENDORED = File.join(ROOT, "openapi", "rain-issuing.json")

response = Net::HTTP.get_response(URI(STATS.fetch("spec_url")))
abort "Could not fetch the spec: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

upstream = JSON.parse(response.body)
current  = JSON.parse(File.read(VENDORED))

if upstream == current
  puts "Up to date: openapi/rain-issuing.json matches #{STATS["spec_url"]}"
  exit
end

def routes(spec) = spec["paths"].flat_map { |path, methods| methods.keys.map { |verb| "#{verb.upcase} #{path}" } }.sort

puts "The upstream spec has changed."
puts "  API version: #{current.dig("info", "version")} -> #{upstream.dig("info", "version")}"

added   = routes(upstream) - routes(current)
removed = routes(current) - routes(upstream)
puts "  Added routes:\n#{added.map { |r| "    #{r}" }.join("\n")}" if added.any?
puts "  Removed routes:\n#{removed.map { |r| "    #{r}" }.join("\n")}" if removed.any?

schemas_added   = upstream.dig("components", "schemas").keys - current.dig("components", "schemas").keys
schemas_removed = current.dig("components", "schemas").keys - upstream.dig("components", "schemas").keys
puts "  Added schemas: #{schemas_added.join(", ")}" if schemas_added.any?
puts "  Removed schemas: #{schemas_removed.join(", ")}" if schemas_removed.any?

candidate = File.join(ROOT, "tmp", "rain-issuing.upstream.json")
FileUtils.mkdir_p(File.dirname(candidate))
File.write(candidate, "#{JSON.pretty_generate(upstream)}\n")

puts <<~NEXT

  Wrote the upstream copy to #{candidate.delete_prefix("#{ROOT}/")}.
  To adopt it:
    1. diff it against openapi/rain-issuing.json and read the changes
    2. move it into place and update openapi/stats.yml
    3. reconcile dev/resource_map.yml with any added or removed routes
    4. rake generate && rake test
NEXT
