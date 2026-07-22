# frozen_string_literal: true

require_relative "test_helper"

# Path params are interpolated into the URL, so they're the one place a caller's
# input can change which endpoint gets hit.
class ResourcePathTest < Minitest::Test
  def client = @client ||= Redrain::Client.new(api_key: TEST_API_KEY, environment: :dev)

  def test_escapes_characters_that_would_break_out_of_the_segment
    stub = stub_request(:get, "#{TEST_BASE_URL}/cards/a%2Fb%3Fc%23d").to_return(status: 200, body: "{}")

    client.cards.retrieve("a/b?c#d")

    assert_requested(stub)
  end

  def test_escapes_spaces_as_percent_twenty_not_plus
    stub = stub_request(:get, "#{TEST_BASE_URL}/cards/a%20b").to_return(status: 200, body: "{}")

    client.cards.retrieve("a b")

    assert_requested(stub)
  end

  # These survive percent-encoding intact, and a normalising proxy in front of
  # Rain would resolve them into a different endpoint.
  def test_rejects_dot_segments
    assert_raises(ArgumentError) { client.cards.retrieve("..") }
    assert_raises(ArgumentError) { client.cards.retrieve(".") }
  end

  def test_rejects_empty_and_nil_ids
    assert_raises(ArgumentError) { client.cards.retrieve("") }
    assert_raises(ArgumentError) { client.cards.retrieve(nil) }
  end

  def test_leaves_ordinary_uuids_alone
    stub = stub_request(:get, "#{TEST_BASE_URL}/cards/3fa85f64-5717-4562-b3fc-2c963f66afa6")
      .to_return(status: 200, body: "{}")

    client.cards.retrieve("3fa85f64-5717-4562-b3fc-2c963f66afa6")

    assert_requested(stub)
  end
end
