require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs    << "test"
  t.libs    << "lib"
  t.pattern = "test/**/*_test.rb"
  t.warning = false
end

desc "Regenerate lib/redrain/models and lib/redrain/resources from openapi/rain-issuing.json"
task :generate do
  ruby "dev/generate.rb"
end

desc "Re-fetch the upstream OpenAPI spec and report drift against the vendored copy"
task :sync_spec do
  ruby "dev/sync_spec.rb"
end

begin
  require "yard"
  YARD::Rake::YardocTask.new(:doc)
rescue LoadError
  # YARD is a development dependency; skip the task when it isn't installed.
end

task default: :test
