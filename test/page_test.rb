# frozen_string_literal: true

require_relative "test_helper"

class PageTest < Minitest::Test
  # Records the cursor/limit it was called with so the tests can assert on how
  # the pager walked, not just on what it yielded.
  class FakeCards
    include Redrain::Page

    attr_reader :calls

    def initialize(pages)
      @pages = pages
      @calls = []
    end

    def list(cursor: nil, limit: nil, **filters)
      @calls << { cursor: cursor, limit: limit, **filters }
      @pages.shift || []
    end
  end

  Card = Struct.new(:id)

  def cards(*ids) = ids.map { |id| Card.new(id) }

  def test_walks_pages_until_a_short_one
    pager = FakeCards.new([cards("a", "b"), cards("c")])

    assert_equal %w[a b c], pager.auto_paging_each(limit: 2).map(&:id)
  end

  def test_advances_the_cursor_to_the_last_id_of_each_page
    pager = FakeCards.new([cards("a", "b"), cards("c", "d"), cards("e")])

    pager.auto_paging_each(limit: 2) { |_| nil }

    assert_equal [nil, "b", "d"], pager.calls.map { |call| call[:cursor] }
  end

  def test_forwards_filters_to_every_page
    pager = FakeCards.new([cards("a", "b"), cards("c")])

    pager.auto_paging_each(limit: 2, status: "active") { |_| nil }

    assert_equal %w[active active], pager.calls.map { |call| call[:status] }
  end

  def test_stops_on_an_empty_first_page
    pager = FakeCards.new([[]])

    assert_empty pager.auto_paging_each(limit: 2).to_a
    assert_equal 1, pager.calls.size
  end

  def test_returns_an_enumerator_without_a_block
    pager = FakeCards.new([cards("a", "b"), cards("c")])

    assert_equal %w[a b], pager.auto_paging_each(limit: 2).lazy.map(&:id).first(2)
  end

  # Without an id there's no cursor to advance to, so keep going would mean
  # fetching the same page forever.
  def test_stops_rather_than_looping_when_records_have_no_id
    pager = FakeCards.new([[Object.new, Object.new], cards("c")])

    assert_equal 2, pager.auto_paging_each(limit: 2).to_a.size
    assert_equal 1, pager.calls.size
  end

  def test_generated_list_resources_are_pageable
    stub_request(:get, "#{TEST_BASE_URL}/cards").with(query: { "limit" => "2" })
      .to_return(status: 200, body: JSON.generate([{ "id" => "c-1" }, { "id" => "c-2" }]))
    stub_request(:get, "#{TEST_BASE_URL}/cards").with(query: { "limit" => "2", "cursor" => "c-2" })
      .to_return(status: 200, body: JSON.generate([{ "id" => "c-3" }]))

    client = Redrain::Client.new(api_key: TEST_API_KEY, environment: :dev)

    assert_equal %w[c-1 c-2 c-3], client.cards.auto_paging_each(limit: 2).map(&:id)
  end

  def test_only_collection_resources_get_the_pager
    client = Redrain::Client.new(api_key: TEST_API_KEY, environment: :dev)

    assert_respond_to client.transactions, :auto_paging_each
    refute_respond_to client.balances, :auto_paging_each
  end

  # Rain caps limit at 100. Passing 500 and then treating the capped page as
  # "short" would end the walk after one page.
  def test_clamps_the_page_size_to_rains_maximum
    pager = FakeCards.new([cards(*Array.new(100) { |i| "c#{i}" }), cards("last")])

    assert_equal 101, pager.auto_paging_each(limit: 500).to_a.size
    assert_equal [100, 100], pager.calls.map { |call| call[:limit] }
  end
end
