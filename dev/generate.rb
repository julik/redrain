# frozen_string_literal: true

# Generates lib/redrain/models/, lib/redrain/resources/ and test/resources/
# from openapi/rain-issuing.json + dev/resource_map.yml.
#
# Run with `rake generate`. Output is committed; never hand-edit it. The
# generator must stay idempotent — a run on a clean tree leaves git status empty.

require "json"
require "yaml"
require "fileutils"
require_relative "generator/naming"
require_relative "generator/spec"
require_relative "generator/registry"
require_relative "generator/resource_builder"
require_relative "generator/model_writer"
require_relative "generator/resource_writer"
require_relative "generator/test_writer"

module Generator
  ROOT = File.expand_path("..", __dir__)

  def self.run
    spec = Spec.load(File.join(ROOT, "openapi", "rain-issuing.json"))
    map  = YAML.load_file(File.join(ROOT, "dev", "resource_map.yml"))

    verify_map!(spec, map)

    registry = Registry.new(spec)
    registry.load_components!
    resources = ResourceBuilder.new(spec, map, registry).build

    ModelWriter.new(ROOT, registry).write
    ResourceWriter.new(ROOT, resources).write
    TestWriter.new(ROOT, resources).write

    puts "Generated #{registry.models.size} models and #{resources.size} resource classes " \
         "covering #{map.size} endpoints."
  end

  # The whole point of keeping the map by hand is catching spec drift. If Rain
  # adds or removes a route, fail here rather than silently shipping a gap.
  def self.verify_map!(spec, map)
    in_spec = spec.routes.keys.sort
    in_map  = map.keys.sort
    return if in_spec == in_map

    missing = in_spec - in_map
    extra   = in_map - in_spec
    message = +"dev/resource_map.yml is out of sync with the spec.\n"
    message << "  In the spec but not the map:\n#{missing.map { |r| "    #{r}" }.join("\n")}\n" if missing.any?
    message << "  In the map but not the spec:\n#{extra.map { |r| "    #{r}" }.join("\n")}\n" if extra.any?
    abort message
  end
end

Generator.run if $PROGRAM_NAME == __FILE__
