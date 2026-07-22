# frozen_string_literal: true

require_relative "test_helper"

class HTTPClientTest < Minitest::Test
  URL = "#{TEST_BASE_URL}/users"

  def http(**options)
    Redrain::HTTPClient.new(base_url: TEST_BASE_URL, api_key: TEST_API_KEY, **options)
  end

  # Sleeping through the real backoff would put seconds on every retry test.
  def without_sleeping
    slept = []
    Redrain::HTTPClient.define_method(:sleep) { |seconds| slept << seconds }
    yield slept
  ensure
    Redrain::HTTPClient.remove_method(:sleep)
  end

  def test_sends_the_api_key_and_identifies_itself
    stub = stub_request(:get, URL).with(
      headers: { "Api-Key" => TEST_API_KEY, "User-Agent" => "redrain/#{Redrain::VERSION} ruby/#{RUBY_VERSION}" }
    ).to_return(status: 200, body: "{}")

    http.request(:get, "/users")

    assert_requested(stub)
  end

  def test_parses_json_responses
    stub_request(:get, URL).to_return(status: 200, body: %({"id":"u-1"}))

    assert_equal({ "id" => "u-1" }, http.request(:get, "/users"))
  end

  def test_returns_nil_for_no_content
    stub_request(:delete, URL).to_return(status: 204, body: "")

    assert_nil http.request(:delete, "/users")
  end

  def test_returns_the_raw_body_for_binary_responses
    stub_request(:get, URL).to_return(status: 200, body: "%PDF-1.4".b)

    assert_equal "%PDF-1.4", http.request(:get, "/users", binary: true)
  end

  def test_inflates_gzipped_responses
    buffer = StringIO.new(+"".b)
    Zlib::GzipWriter.new(buffer).tap { |gz| gz.write(%({"id":"u-1"})) }.close
    stub_request(:get, URL).to_return(
      status: 200, body: buffer.string, headers: { "Content-Encoding" => "gzip" }
    )

    assert_equal({ "id" => "u-1" }, http.request(:get, "/users"))
  end

  def test_omits_nil_query_params_and_stringifies_the_rest
    stub = stub_request(:get, URL).with(query: { "limit" => "10" })
      .to_return(status: 200, body: "{}")

    http.request(:get, "/users", query: { "limit" => 10, "cursor" => nil })

    assert_requested(stub)
  end

  def test_repeats_the_key_for_array_query_params
    stub = stub_request(:get, "#{URL}?status=active&status=locked").to_return(status: 200, body: "{}")

    http.request(:get, "/users", query: { "status" => %w[active locked] })

    assert_requested(stub)
  end

  def test_sends_json_bodies
    stub = stub_request(:post, URL)
      .with(body: { "firstName" => "Ada" }, headers: { "Content-Type" => "application/json" })
      .to_return(status: 200, body: "{}")

    http.request(:post, "/users", body: { "firstName" => "Ada" })

    assert_requested(stub)
  end

  def test_encodes_multipart_uploads
    stub_request(:put, URL).to_return(status: 204)

    http.request(
      :put, "/users",
      body: { "type" => "passport" },
      files: { "document" => Redrain::Upload.new("PNGDATA", filename: "id.png") }
    )

    assert_requested(:put, URL) { |request|
      assert_match(%r{\Amultipart/form-data; boundary=----RedrainFormBoundary}, request.headers["Content-Type"])
      assert_includes request.body, %(Content-Disposition: form-data; name="type")
      assert_includes request.body, "passport"
      assert_includes request.body, %(Content-Disposition: form-data; name="document"; filename="id.png")
      assert_includes request.body, "Content-Type: image/png"
      assert_includes request.body, "PNGDATA"
      true
    }
  end

  def test_omits_nil_multipart_fields
    stub_request(:put, URL).to_return(status: 204)

    http.request(:put, "/users", body: { "type" => nil }, files: { "document" => "bytes" })

    assert_requested(:put, URL) { |request| !request.body.include?(%(name="type")) }
  end

  {
    400 => Redrain::BadRequestError,
    401 => Redrain::AuthenticationError,
    403 => Redrain::PermissionDeniedError,
    404 => Redrain::NotFoundError,
    422 => Redrain::UnprocessableEntityError,
    418 => Redrain::APIStatusError
  }.each do |status, error_class|
    define_method(:"test_raises_#{error_class.name.split("::").last}_on_#{status}") do
      stub_request(:get, URL).to_return(status: status, body: %({"message":"nope"}))

      error = assert_raises(error_class) { http.request(:get, "/users") }

      assert_equal status, error.status
      assert_equal "nope", error.error_message
      assert_includes error.message, "nope"
    end
  end

  def test_exposes_the_request_id_from_the_response_headers
    stub_request(:get, URL).to_return(status: 404, body: "{}", headers: { "X-Request-Id" => "req-7" })

    error = assert_raises(Redrain::NotFoundError) { http.request(:get, "/users") }

    assert_equal "req-7", error.request_id
  end

  def test_keeps_an_unparseable_error_body_as_text
    stub_request(:get, URL).to_return(status: 502, body: "<html>gateway</html>")

    error = assert_raises(Redrain::InternalServerError) { http.request(:get, "/users") }

    assert_equal "<html>gateway</html>", error.body
  end

  def test_retries_server_errors_then_succeeds
    stub_request(:get, URL)
      .to_return(status: 500, body: "{}")
      .to_return(status: 200, body: %({"id":"u-1"}))

    without_sleeping do |slept|
      assert_equal({ "id" => "u-1" }, http.request(:get, "/users"))
      assert_equal 1, slept.size
    end
  end

  def test_gives_up_after_max_retries_and_raises
    stub_request(:get, URL).to_return(status: 500, body: "{}")

    without_sleeping do |slept|
      assert_raises(Redrain::InternalServerError) { http.request(:get, "/users") }
      assert_equal 2, slept.size
    end
  end

  def test_does_not_retry_client_errors
    stub_request(:get, URL).to_return(status: 400, body: "{}")

    without_sleeping do |slept|
      assert_raises(Redrain::BadRequestError) { http.request(:get, "/users") }
      assert_empty slept
    end
  end

  def test_honours_retry_after_seconds_on_429
    stub_request(:get, URL)
      .to_return(status: 429, body: "{}", headers: { "Retry-After" => "3" })
      .to_return(status: 200, body: "{}")

    without_sleeping do |slept|
      http.request(:get, "/users")
      assert_equal [3.0], slept
    end
  end

  def test_caps_retry_after_at_the_maximum_delay
    stub_request(:get, URL)
      .to_return(status: 429, body: "{}", headers: { "Retry-After" => "600" })
      .to_return(status: 200, body: "{}")

    without_sleeping do |slept|
      http.request(:get, "/users")
      assert_equal [Redrain::HTTPClient::MAX_RETRY_DELAY], slept
    end
  end

  def test_backoff_grows_and_stays_jittered_within_bounds
    stub_request(:get, URL).to_return(status: 503, body: "{}")

    without_sleeping do |slept|
      assert_raises(Redrain::InternalServerError) { http.request(:get, "/users") }
      assert_operator slept[0], :<=, Redrain::HTTPClient::INITIAL_RETRY_DELAY
      assert_operator slept[0], :>=, Redrain::HTTPClient::INITIAL_RETRY_DELAY / 2
      assert_operator slept[1], :>, slept[0]
    end
  end

  def test_retries_connection_failures_then_raises_a_connection_error
    stub_request(:get, URL).to_raise(Errno::ECONNRESET)

    without_sleeping do |slept|
      assert_raises(Redrain::APIConnectionError) { http.request(:get, "/users") }
      assert_equal 2, slept.size
    end
  end

  def test_reports_timeouts_as_timeout_errors
    stub_request(:get, URL).to_raise(Net::ReadTimeout)

    without_sleeping do
      assert_raises(Redrain::APITimeoutError) { http.request(:get, "/users") }
    end
  end

  def test_max_retries_zero_disables_retrying
    stub_request(:get, URL).to_return(status: 500, body: "{}")

    without_sleeping do |slept|
      assert_raises(Redrain::InternalServerError) { http(max_retries: 0).request(:get, "/users") }
      assert_empty slept
    end
  end

  def test_rejects_unsupported_http_methods
    assert_raises(ArgumentError) { http.request(:options, "/users") }
  end

  # A retried upload rebuilds the multipart body, which re-reads the source. An
  # IO already at EOF would hand back nothing and the retry would silently
  # upload a zero-byte file.
  def test_a_retried_upload_resends_the_same_bytes
    stub_request(:put, URL).to_return(status: 500, body: "{}").to_return(status: 204)
    bodies = []
    WebMock.after_request { |request, _| bodies << request.body }

    without_sleeping do
      http.request(:put, "/users", files: { "document" => StringIO.new("PAYLOAD") })
    end

    assert_equal 2, bodies.size
    assert_equal 2, bodies.count { |body| body.include?("PAYLOAD") },
      "both attempts must carry the bytes — a retry must not send an empty file"
  ensure
    WebMock.reset_callbacks
  end

  def test_multipart_survives_non_ascii_fields_and_filenames
    stub_request(:put, URL).to_return(status: 204)

    http.request(
      :put, "/users",
      body: { "name" => "café" },
      files: { "document" => Redrain::Upload.new("\xFF\xD8\xFF".b, filename: "identité.jpg") }
    )

    assert_requested(:put, URL) { |request|
      assert_includes request.body.b, "café".b
      assert_includes request.body.b, "identité.jpg".b
      true
    }
  end

  def test_serialises_times_in_query_params_as_iso8601
    stub = stub_request(:get, URL).with(query: { "postedAfter" => "2026-07-20T11:14:16Z" })
      .to_return(status: 200, body: "{}")

    http.request(:get, "/users", query: { "postedAfter" => Time.utc(2026, 7, 20, 11, 14, 16) })

    assert_requested(stub)
  end

  def test_wraps_every_syscall_failure_as_a_connection_error
    stub_request(:get, URL).to_raise(Errno::ETIMEDOUT)

    without_sleeping do
      assert_raises(Redrain::APIConnectionError) { http.request(:get, "/users") }
    end
  end

  def test_keeps_the_detail_when_the_error_body_has_no_message_key
    stub_request(:get, URL).to_return(status: 422, body: %({"errors":[{"field":"firstName"}]}))

    error = assert_raises(Redrain::UnprocessableEntityError) { http.request(:get, "/users") }

    assert_includes error.message, "firstName"
  end

  def test_an_elapsed_retry_after_still_backs_off
    stub_request(:get, URL)
      .to_return(status: 429, body: "{}", headers: { "Retry-After" => (Time.now - 60).httpdate })
      .to_return(status: 200, body: "{}")

    without_sleeping do |slept|
      http.request(:get, "/users")
      assert_equal [Redrain::HTTPClient::INITIAL_RETRY_DELAY], slept
    end
  end

  def test_caller_headers_override_the_inferred_content_type
    stub = stub_request(:post, URL).with(headers: { "Content-Type" => "application/vnd.rain+json" })
      .to_return(status: 200, body: "{}")

    http.request(:post, "/users", body: { "a" => 1 }, headers: { "Content-Type" => "application/vnd.rain+json" })

    assert_requested(stub)
  end

  def test_tolerates_a_gzip_header_on_an_empty_body
    stub_request(:delete, URL).to_return(status: 204, body: "", headers: { "Content-Encoding" => "gzip" })

    assert_nil http.request(:delete, "/users")
  end
end
