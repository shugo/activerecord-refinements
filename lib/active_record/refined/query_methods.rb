# frozen_string_literal: true

require "active_record/refined/ast"
require "active_record/refined/dialect"
require "active_record/refined/block_syntax"
require "active_record/refined/block_context"

module ActiveRecord
  module Refined
    # The relation methods a block reaches, prepended to Active Record's
    # own: `where`, `select`, `having`, `order` and `group` take a block
    # beside what they take already, the joins take one for the ON, and
    # `from`, `from_cte`, `distinct_on` and `lateral` are here for what
    # Active Record has no spelling for.  Without a block each is Active
    # Record's own.
    #
    # @example
    #   Author.
    #     joins(:posts) { :posts[:author_id] == :authors[:id] }.
    #     where { :posts[:published] == true }.
    #     group { :authors[:id] }.
    #     having { count(:posts[:id]) > 1 }.
    #     order { count(:posts[:id]).desc }.
    #     select { [:name, count(:posts[:id]).as(:post_count)] }
    module QueryMethods
      # `WHERE`, from a block: a condition built with the comparisons of
      # {BlockSyntax}, combined with `&`, `|` and `!`.
      # @yieldreturn [AST::Predicate, AST::Sql, AST::Operation]
      # @example
      #   Author.where { (:age >= 18) & :country.in?(%w[JP US]) }
      #   Author.where { !:name.like?("A%") }
      def where(opts = nil, *rest, &block)
        if block
          super(to_arel_condition(evaluate_block(&block)))
        else
          super
        end
      end

      # `SELECT`, from a block: an expression, or an array of them, each
      # aliased with `as` or left to its own name.
      # @yieldreturn [Symbol, AST::Node, Array<Symbol, AST::Node>]
      # @example
      #   Author.select { [:name, upper(:name).as(:shouted), count(:*).as(:n)] }
      def select(*fields, &block)
        if block
          super(*to_arel_fields(evaluate_block(&block)), &nil)
        else
          super
        end
      end

      # `HAVING`, from a block: a condition over the aggregates of a group.
      # @yieldreturn [AST::Predicate, AST::Sql, AST::Operation]
      # @example
      #   Author.group { :country }.having { count(:*) > 1 }
      def having(opts = nil, *rest, &block)
        if block
          super(to_arel_condition(evaluate_block(&block)))
        else
          super
        end
      end

      # `ORDER BY`, from a block: an ordering, or an array of them --
      # `:age.desc`, `count(:*).desc.nulls_last`, or a bare column.
      # @yieldreturn [Symbol, AST::Node, Array<Symbol, AST::Node>]
      # @example
      #   Author.order { [:country.asc.nulls_last, :age.desc] }
      def order(*args, &block)
        if block
          super(*to_arel_fields(evaluate_block(&block)), &nil)
        else
          super
        end
      end

      # `GROUP BY`, from a block: a column or an expression, an array of
      # them, or one of {BlockContext#grouping_sets}, {BlockContext#rollup}
      # and {BlockContext#cube}.
      # @yieldreturn [Symbol, AST::Node, Array<Symbol, AST::Node>]
      # @example
      #   Post.group { date_trunc("day", :created_at) }.select { [date_trunc("day", :created_at).as(:day), count(:*)] }
      def group(*args, &block)
        if block
          result = evaluate_block(&block)
          check_rollup_stands_alone(result)
          super(*to_arel_fields(result), &nil)
        else
          super
        end
      end

      # `FROM`, with a table named as a symbol and, with `as:`, selected
      # under another name; anything else is Active Record's own `from`.
      # @param value [Symbol, String, ActiveRecord::Relation]
      # @param as [Symbol, nil] the name the table is selected under
      # @example
      #   Post.from(:archived_posts, as: :posts)
      #
      # A symbol names a table, which Active Record's own from only takes as
      # a string.  With `as` it is selected under another name; when that
      # name is the model's own, from_cte says the same thing without
      # repeating it.
      def from(value, subquery_name = nil, as: nil)
        unless value.is_a?(Symbol)
          if as
            raise ArgumentError, "as: needs the table named as a symbol"
          end
          return super(value, subquery_name)
        end
        arel_table = Arel::Table.new(value)
        arel_table = arel_table.alias(as) if as
        super(arel_table, subquery_name)
      end

      # Selects a CTE in place of the model's own table, under the model's
      # own name, so that the columns Active Record qualifies still resolve.
      # The name has to be one `with` or `with_recursive` declares.
      # @param name [Symbol] the CTE's name
      # @example
      #   Node.with_recursive(tree: [Node.where { :id == 1 }, Node.joins(...)]).from_cte(:tree)
      #
      # The alias is not a choice -- Active Record keeps qualifying columns
      # with the table name, so the model's is the only name that works --
      # which is why it is taken from the model rather than asked for.
      # The name is checked against what `with` declares, so that a typo is
      # not a query against a table nobody has.  Checked when the SQL is
      # built, since the CTE may be declared after this in the chain, or by a
      # scope merged into it.
      def from_cte(name)
        unless name.is_a?(Symbol)
          raise ArgumentError, "from_cte takes the CTE's name as a symbol"
        end
        relation = from(name, as: model.table_name)
        relation.from_cte_value = name
        relation
      end

      # @private
      def from_cte_value
        @values[:from_cte]
      end

      # @private
      def from_cte_value=(name)
        assert_modifiable!
        @values[:from_cte] = name
      end

      # `SELECT DISTINCT ON (columns)`: the first row of each group the
      # order brings up.  PostgreSQL has it; the portable shape is a
      # `row_number` window in a subquery.
      # @param columns [Array<Symbol>] the columns, unless a block gives them
      # @example
      #   Post.distinct_on { :author_id }.order { [:author_id, :likes.desc] }
      #
      # Arel carries the node and refuses to write it elsewhere, the way it
      # does a regexp, so there is nothing for this to check.
      def distinct_on(*columns, &block)
        spawn.distinct_on!(*columns, &block)
      end

      # {#distinct_on} on the relation itself.
      def distinct_on!(*columns, &block)
        columns = Array(evaluate_block(&block)) if block
        if columns.empty?
          raise ArgumentError, "distinct_on needs a column or an expression"
        end
        self.distinct_on_values += columns
        self
      end

      # Active Record generates these for the values it knows about; this one
      # is ours, and lives in the same place so that it survives a spawn.
      # @private
      def distinct_on_values
        @values.fetch(:distinct_on, ActiveRecord::QueryMethods::FROZEN_EMPTY_ARRAY)
      end

      # @private
      def distinct_on_values=(columns)
        assert_modifiable!
        @values[:distinct_on] = columns
      end

      # Marks the relation for a `LATERAL` join, which lets the subquery see
      # the row it is joined to -- the top few rows of each group, and the
      # like.  Said on the relation, since in SQL the keyword modifies the
      # subquery rather than the join.  SQLite and MariaDB have none.
      # @example
      #   top = Post.where { :posts[:author_id] == :authors[:id] }.order { :likes.desc }.limit(1)
      #   Author.left_outer_joins(top.lateral, as: :top).select { [:name, :top[:title]] }
      def lateral
        spawn.lateral!
      end

      # {#lateral} on the relation itself.
      def lateral!
        self.lateral_value = true
        self
      end

      # @private
      def lateral_value
        @values[:lateral]
      end

      # @private
      def lateral_value=(value)
        assert_modifiable!
        @values[:lateral] = value
      end

      # `INNER JOIN`, with the `ON` from a block: `joins(:posts) { ... }`
      # joins the table named, `joins(relation) { ... }` a subquery -- a
      # lateral one when the relation is marked {#lateral}.  `as:` names the
      # table within the query, which is what makes a self join expressible.
      # Without a block it is Active Record's own `joins`.
      # @param as [Symbol, nil]
      # @yieldreturn [AST::Predicate, AST::Sql, AST::Operation]
      # @example
      #   Author.joins(:posts) { :posts[:author_id] == :authors[:id] }
      #   Employee.joins(:employees, as: :managers) { :managers[:id] == :employees[:manager_id] }
      def joins(*args, as: nil, &block)
        if args.first.is_a?(ActiveRecord::Relation)
          super(build_lateral_join(args.first, Arel::Nodes::InnerJoin, as, &block))
        elsif block
          super(build_join_node(args.first, Arel::Nodes::InnerJoin, as, &block))
        else
          reject_join_alias(as)
          super(*args, &block)
        end
      end

      # `LEFT OUTER JOIN`, as {#joins} takes it.
      # @param as [Symbol, nil]
      # @yieldreturn [AST::Predicate, AST::Sql, AST::Operation]
      # @example
      #   Author.left_outer_joins(:posts) { :posts[:author_id] == :authors[:id] }
      def left_outer_joins(*args, as: nil, &block)
        if args.first.is_a?(ActiveRecord::Relation)
          joins(build_lateral_join(args.first, Arel::Nodes::OuterJoin, as, &block))
        elsif block
          joins(build_join_node(args.first, Arel::Nodes::OuterJoin, as, &block))
        else
          reject_join_alias(as)
          super(*args, &block)
        end
      end

      # `RIGHT OUTER JOIN`, as {#joins} takes it, of a table or a relation;
      # an association name is not among what it takes.
      # @param as [Symbol, nil]
      # @yieldreturn [AST::Predicate, AST::Sql, AST::Operation]
      # @example
      #   Post.right_outer_joins(:authors) { :posts[:author_id] == :authors[:id] }
      #
      # The other two outer joins, which Active Record has no method for and
      # Arel has the nodes for.  The rules are joins': the block is the ON,
      # `as` names the table within the query, a relation marked `lateral`
      # joins as one.  An association name is not among them -- what Active
      # Record reads out of one is an inner or a left join and nothing else.
      def right_outer_joins(*args, as: nil, &block)
        outer_joins(:right_outer_joins, Arel::Nodes::RightOuterJoin,
                    args, as, &block)
      end

      # `FULL OUTER JOIN`, as {#right_outer_joins} takes it.  The MySQL
      # family has none.
      # @param as [Symbol, nil]
      # @yieldreturn [AST::Predicate, AST::Sql, AST::Operation]
      def full_outer_joins(*args, as: nil, &block)
        check_full_outer_support
        outer_joins(:full_outer_joins, Arel::Nodes::FullOuterJoin,
                    args, as, &block)
      end

      # `CROSS JOIN`: every row of one table against every row of the
      # other, so there is no condition to give and no block to write it in.
      # @param as [Symbol, nil]
      # @example
      #   Post.cross_joins(:authors)
      #   Post.cross_joins(:posts, as: :others)
      def cross_joins(*args, as: nil, &block)
        if block
          raise ArgumentError,
            "a cross join has no condition; joins is the one that takes a block"
        end
        joins(build_cross_join(args.first, as))
      end

      private
        def build_arel(...)
          check_from_cte
          arel = super
          unless distinct_on_values.empty?
            arel.distinct_on(distinct_on_values.map { |column| to_arel_field(column) })
          end
          arel
        end

        # Only when every `with` is one this can read the names out of; anything
        # else and there is nothing to be sure about, so nothing is said.
        def check_from_cte
          name = from_cte_value
          return unless name
          return unless with_values.all? { |value| value.is_a?(::Hash) }

          declared = with_values.flat_map { |value| value.keys.map(&:to_sym) }
          return if declared.include?(name)

          raise ArgumentError,
            "from_cte(#{name.inspect}) names no CTE; " +
            (declared.empty? ? "this query declares none" :
                               "this query declares #{declared.map(&:inspect).join(', ')}")
        end

        def evaluate_block(&block)
          refined_block = block.refined(ActiveRecord::Refined::BlockSyntax)
          BlockContext.new(model).instance_exec(&refined_block)
        end

        # WITH ROLLUP trails the whole group list, so on the MySQL family a
        # rollup cannot stand beside other group entries the way PostgreSQL's
        # ROLLUP(...) can.
        def check_rollup_stands_alone(result)
          entries = Array(result)
          return if entries.size == 1
          return unless entries.any? { |node| node.is_a?(AST::GroupingSets) }
          return unless Dialect.for(model).grouping_by_with_rollup?

          raise ArgumentError,
            "WITH ROLLUP takes the whole group list; group by the rollup alone"
        end

        def to_arel_condition(result)
          return result if result.is_a?(Arel::Nodes::SqlLiteral)
          if result.is_a?(::String)
            raise ArgumentError,
              "#{result.inspect} is a string, not a condition; sql(...) " \
              "writes one as SQL"
          end
          result.to_arel(table, model)
        end

        # The top of a select, order or group list.  A bare string is refused
        # rather than passed to Active Record, where it would be SQL: inside a
        # block a string is a value in every other position, and a literal
        # whose meaning turns on where it stands is how an interpolation
        # becomes an injection.
        def to_arel_fields(result)
          fields =
            if result.nil? then []
            elsif result.is_a?(::Array) then result
            else [result]
            end
          fields.map do |node|
            if node.is_a?(::String) && !node.is_a?(Arel::Nodes::SqlLiteral)
              raise ArgumentError,
                "#{node.inspect} could mean SQL or a string; " \
                "sql(...) says the SQL, value(...) the string"
            end
            to_arel_field(node)
          end
        end

        def to_arel_field(node)
          case node
          when AST::Sql then node.field_arel(model)
          when AST::Node then node.to_arel(table, model)
          when Symbol then table[node]
          else node
          end
        end

        def reject_join_alias(alias_name)
          return unless alias_name
          raise ArgumentError, "as: needs a block to write the ON clause with"
        end

        # The subquery is written out rather than handed over as a tree: Arel has
        # a LATERAL node but only PostgreSQL's visitor writes it, and MySQL can
        # read what it will not write.  Without a block the join is ON TRUE,
        # which is the usual shape -- what the subquery is allowed to see is
        # what makes it lateral, and that is said inside it.
        def build_lateral_join(relation, join_class, alias_name, &block)
          unless relation.lateral_value
            raise ArgumentError,
              "a relation joins laterally; mark it: joins(sub.lateral, as: :top)"
          end
          unless alias_name
            raise ArgumentError, "a lateral join needs a name: joins(..., as: :top)"
          end
          check_lateral_support

          aliased = Arel::Nodes::TableAlias.new(
            Arel::Nodes::SqlLiteral.new("LATERAL (#{relation.to_sql})"), alias_name)
          on = block ? evaluate_block(&block).to_arel(table, model) : Arel::Nodes::True.new
          join_class.new(aliased, Arel::Nodes::On.new(on))
        end

        def check_lateral_support
          Dialect.for(model).check_lateral(model)
        end

        def check_full_outer_support
          return if Dialect.for(model).full_outer_join_supported?
          raise NotImplementedError, "a full outer join has no equivalent on MySQL"
        end

        def outer_joins(called, join_class, args, alias_name, &block)
          if args.first.is_a?(ActiveRecord::Relation)
            return joins(build_lateral_join(args.first, join_class, alias_name, &block))
          end
          return joins(build_join_node(args.first, join_class, alias_name, &block)) if block

          raise ArgumentError,
            "#{called} takes a table and the block that joins it; an association " \
            "is what joins and left_outer_joins read"
        end

        # Arel has a node for every other join and none for this one, and INNER
        # JOIN with no ON -- which is a cross join on SQLite and MySQL -- is a
        # syntax error on PostgreSQL.  So the SQL is written here, the second
        # place in the gem that writes any: the keyword is fixed and the names
        # are quoted by the adapter, so nothing of the caller's is in it.
        def build_cross_join(target_table, alias_name)
          joined = model.with_connection do |connection|
            name = connection.quote_table_name(target_table.to_s)
            alias_name ? "#{name} #{connection.quote_table_name(alias_name.to_s)}" : name
          end
          Arel::Nodes::StringJoin.new(Arel.sql("CROSS JOIN #{joined}"))
        end

        def build_join_node(target_table, join_class, alias_name, &block)
          ast = evaluate_block(&block)
          arel_table = Arel::Table.new(target_table)
          arel_table = arel_table.alias(alias_name) if alias_name
          join_class.new(arel_table, Arel::Nodes::On.new(ast.to_arel(table, model)))
        end
    end
  end
end
