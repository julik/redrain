# frozen_string_literal: true

module Redrain
  # Cursor pagination helper. Rain's list endpoints take `cursor` and `limit`
  # and return a bare array; the cursor for the next page is the id of the last
  # item you got. The Python SDK makes you write that loop yourself — this
  # doesn't.
  #
  #   rain.transactions.auto_paging_each(user_id: uid) { |txn| ... }
  #   rain.cards.auto_paging_each.lazy.select { |c| c.status == "active" }.first(5)
  module Page
    # Rain's `limit` caps at 100; the API's own default is 20. Page as large as
    # allowed, since the caller asked to walk the whole collection.
    DEFAULT_PAGE_SIZE = 100

    # Walks every page of a cursor-paginated collection.
    #
    # Included into generated list resources; +list+ must accept +cursor:+ and
    # +limit:+ and return an Array.
    #
    # @param limit [Integer] page size, clamped to {DEFAULT_PAGE_SIZE}
    # @param params [Hash] filters forwarded to +list+ on every page
    # @yieldparam record [Redrain::Model] each record, across all pages
    # @return [Enumerator, void] an Enumerator when no block is given
    def auto_paging_each(limit: DEFAULT_PAGE_SIZE, **params, &block)
      return enum_for(:auto_paging_each, limit: limit, **params) unless block

      # Rain silently caps `limit` at 100. Asking for more and then treating the
      # capped page as "short" would end the walk after a single page.
      limit = limit.clamp(1, DEFAULT_PAGE_SIZE)
      cursor = params.delete(:cursor)
      loop do
        page = list(**params, cursor: cursor, limit: limit)
        break if page.nil? || page.empty?

        page.each(&block)
        # A short page means we've reached the end — one fewer round trip than
        # waiting for an empty one.
        break if page.size < limit

        next_cursor = page.last.respond_to?(:id) ? page.last.id : nil
        # Without an id there's no cursor to advance to; stop rather than loop
        # forever on the same page.
        break if next_cursor.nil? || next_cursor == cursor

        cursor = next_cursor
      end
    end
  end
end
