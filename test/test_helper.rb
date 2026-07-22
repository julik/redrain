# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "webmock/minitest"
require "redrain"

TEST_API_KEY  = "test-api-key"
TEST_BASE_URL = "https://api-dev.raincards.xyz/v1/issuing"

# Shared by the generated per-endpoint smoke tests in test/resources.
module ResourceTestHelper
  BINARY_FIXTURE = "%PDF-1.4 fixture".b

  def client
    @client ||= Redrain::Client.new(api_key: TEST_API_KEY, environment: :dev)
  end

  # Stubs a Rain endpoint. `query` and `sends` are the request-side expectations
  # — they're what make the generated smoke tests prove the camelCase mapping
  # rather than just that a request went out.
  def stub_api(method, path, body: nil, status: 200, content_type: "application/json", query: nil, sends: nil)
    stub = stub_request(method, "#{TEST_BASE_URL}#{path}")
    expectations = {}
    expectations[:query] = query if query
    expectations[:body]  = sends if sends
    stub = stub.with(**expectations) if expectations.any?

    stub.to_return(
      status: status,
      body: content_type == "application/json" && !body.nil? ? JSON.generate(body) : body,
      headers: body.nil? ? {} : { "Content-Type" => content_type }
    )
  end

  def upload_fixture
    Redrain::Upload.new("fixture bytes", filename: "document.png")
  end
end
