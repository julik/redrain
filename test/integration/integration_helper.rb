# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "minitest/autorun"
require "redrain"

# These hit the real Rain dev API. They're skipped unless RAIN_API_KEY is set,
# so `rake test` stays offline by default.
#
#   RAIN_API_KEY=... bundle exec rake test
#
# They exist because WebMock can't prove that multipart bodies and
# octet-stream responses are encoded the way Rain actually wants them.
module IntegrationHelper
  def setup
    skip "set RAIN_API_KEY to run integration tests against the Rain dev API" unless ENV["RAIN_API_KEY"]
    super
  end

  def client
    @client ||= Redrain::Client.new(api_key: ENV.fetch("RAIN_API_KEY"), environment: :dev)
  end
end
