# frozen_string_literal: true

require "active_record/refined/query_methods"

module ActiveRecord
  module Refined
    # The writing statements, which live on Relation rather than in
    # QueryMethods.  What a block adds here is the one thing their arguments
    # cannot carry: a value worked out from the row rather than given.
    module Writes
      # `UPDATE`, from a block that gives a hash of column to value, where a
      # value may be an expression built from the row: `{ likes: :likes + 1 }`.
      # Without a block it is Active Record's own, where `likes: :likes`
      # sets the column to the symbol.
      # @yieldreturn [Hash{Symbol => Object}]
      # @example
      #   Post.where { :published == true }.update_all { { likes: :likes + 1 } }
      #   Post.update_all { { title: upper(:title) } }
      def update_all(updates = nil, &block)
        return super(updates) unless block
        if updates
          raise ArgumentError, "update_all takes updates or a block, not both"
        end
        result = evaluate_block(&block)
        unless result.is_a?(::Hash)
          raise ArgumentError, "the block gives update_all a hash of column => value"
        end
        super(result.transform_values { |value| to_arel_field(value) })
      end

      # `INSERT ... ON CONFLICT DO UPDATE`, with a block for what happens to
      # a row that is already there: a hash of column to value, where
      # {BlockContext#excluded} is the row that could not be inserted.  Takes
      # the block or `on_duplicate:`, not both.
      # @yieldreturn [Hash{Symbol => Object}]
      # @example
      #   Tally.upsert_all(rows, unique_by: :page) { { hits: :hits + excluded(:hits) } }
      #
      # upsert_all's on_duplicate takes SQL text and nothing else, so this is
      # the one place the DSL writes the SQL out itself rather than handing
      # Arel a tree.
      def upsert_all(attributes, **options, &block)
        return super(attributes, **options) unless block
        if options.key?(:on_duplicate)
          raise ArgumentError, "upsert_all takes on_duplicate: or a block, not both"
        end
        result = evaluate_block(&block)
        unless result.is_a?(::Hash)
          raise ArgumentError, "the block gives upsert_all a hash of column => value"
        end
        if result.empty?
          raise ArgumentError, "the block gives upsert_all at least one column to set"
        end
        super(attributes, on_duplicate: Arel.sql(set_clause(result)), **options)
      end

      private
        # The left of each assignment is the column being written, which is bare
        # -- the statement is already about one table -- and the right is the
        # expression, compiled here because a string is what on_duplicate reads.
        def set_clause(updates)
          model.with_connection do |connection|
            updates.map do |column, value|
              expression = connection.visitor.compile(
                to_arel_field(value), Arel::Collectors::SQLString.new)
              "#{connection.quote_column_name(column)}=#{expression}"
            end.join(", ")
          end
        end
    end
  end
end
