# activerecord-refined

[![gem](https://img.shields.io/gem/v/activerecord-refined.svg)](https://rubygems.org/gems/activerecord-refined)
[![test](https://github.com/shugo/activerecord-refined/actions/workflows/test.yml/badge.svg)](https://github.com/shugo/activerecord-refined/actions/workflows/test.yml)

Adding clean and powerful query syntax on Active Record using refinements.

```ruby
Author.
  joins(:posts) { :posts[:author_id] == :authors[:id] }.
  where { :authors[:age].in?(20..40) & (:posts[:published] == true) }
# SELECT "authors".* FROM "authors"
#   INNER JOIN "posts" ON "posts"."author_id" = "authors"."id"
#   WHERE "authors"."age" BETWEEN 20 AND 40 AND "posts"."published" = TRUE
```

**[Try it in your browser](https://shugo.github.io/activerecord-refined/)**

## Requirements

* Ruby 4.1 or later (for `Proc#refined`; not released yet, so a `ruby-master` build is needed for now)
* Active Record 7.2 or later

## Installation

Add this line to your application's Gemfile:

    gem 'activerecord-refined'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install activerecord-refined

## Usage

With Bundler — a Rails application — there is nothing to write: the gem in
the Gemfile is loaded, and `where`, `select`, `joins`, `left_outer_joins`,
`having`, `order` and `group` accept a block. Elsewhere, require it:

```ruby
require "activerecord-refined"
```

## Documentation

https://rubydoc.info/gems/activerecord-refined/

## Adapters

SQLite, PostgreSQL, MySQL, MariaDB, Oracle and SQL Server are supported: each
is a `Dialect`, one class per family of spellings, asked for whatever the
databases write differently, so that one block builds the right SQL on all
six. An adapter the gem does not know keeps the standard spellings, which
reach further than you might expect; where they fall short, a dialect of
your own says the rest. Subclass
`ActiveRecord::Refined::Dialect` — or the built-in family the database
descends from — override only what it spells differently, and register it
under the adapter's name:

```ruby
class ExampleDialect < ActiveRecord::Refined::Dialect
  # The example database spells char_length LEN, and has no random ordering.
  FUNCTIONS = { char_length: "LEN", rand: nil }.freeze

  def full_outer_join_supported? = false
end

ActiveRecord::Refined::Dialect.register("exampledb", ExampleDialect)
```

`register` also takes a block for an adapter whose dialect only the
connection can name — the way `mysql2` answers for MySQL and MariaDB both —
receiving the model and returning the class.

## Performance

`benchmark/query_building.rb` compares building the same queries through the
block DSL and through Active Record's other argument styles. Only query
construction (through `to_sql`) is measured — every style produces the same
SQL, so execution costs the same regardless.

Queries built per second (ruby 4.1.0dev, Active Record 8.1.3.1, one machine —
treat the ratios, not the absolute numbers, as the result):

| query | string | arel | block (this gem) | hash | relation and/or |
| --- | --- | --- | --- | --- | --- |
| simple equality | 40.9k | 40.5k | 36.1k | 31.5k | — |
| range (BETWEEN) | — | 33.7k | 31.8k | 24.7k | — |
| LIKE | 40.1k | 39.9k | 36.4k | — | — |
| compound AND/OR | 32.8k | 26.7k | 23.4k | — | 11.4k |

Allocated memory per built query:

| query | arel | block (this gem) | hash | string | relation and/or |
| --- | --- | --- | --- | --- | --- |
| simple equality | 2,176 B | 2,392 B | 2,576 B | 2,976 B | — |
| compound AND/OR | 2,744 B | 3,104 B | — | 4,144 B | 7,152 B |

In short: the block DSL is 6–13% slower than hand-written Arel (which it
compiles to), a little faster than hash conditions, and both faster and
leaner than `where(...).and(where(...).or(where(...)))` relation chains,
which pay for structural-compatibility checks and relation copies. The
`Proc#refined` call itself costs about 170 ns of the ~28 μs build — the
re-interpretation of the block is not where the time goes. Against a
database round trip of tens to hundreds of microseconds, none of these
differences are visible in an application.

One memory cost sits outside the per-query numbers above: to run a block
under the refinements, `Proc#refined` deep-copies its instruction sequence,
nested blocks included. The copy is made lazily on the refined proc's first
call and memoized per block and refinement list for the life of the process,
so it is paid once per `where { ... }` call site, not per query — the
benchmark measures the copy at the size of the original (552 bytes for the
simple-equality block, 872 bytes for the compound one), and a thousand
further calls from the same call site copy nothing. Steady state, an
application holds one extra copy of each distinct query block's bytecode:
a few hundred bytes per call site. "Per call site" assumes blocks compiled
once, as normal code is — building query blocks with a string `eval` mints
a fresh instruction sequence per pass, each earning a copy of its own, and
the memo keeps both alive for the life of the process.

## History

This gem was formerly known as **activerecord-refinements**, created by Akira Matsuda
to experiment with the initial implementation of Ruby 2.0 Refinements. Because of the
Refinements' spec change, that implementation stopped working on Ruby 2.0.0 stable, and
the project was left dormant for a long time.

It has now been renamed to **activerecord-refined** and reimplemented on top of
[`Proc#refined`](https://docs.ruby-lang.org/en/master/Proc.html#method-i-refined),
which will be introduced in Ruby 4.1. `Proc#refined` returns a new proc that
is evaluated with the given refinements activated, so a block written by the caller can
be re-interpreted under the query DSL's refinements:

```ruby
def evaluate_block(&block)
  refined_block = block.refined(ActiveRecord::Refined::BlockSyntax)
  BlockContext.new.instance_exec(&refined_block)
end
```

This is exactly what the old implementation needed and could not do, so the query syntax
works again without monkey-patching `Symbol` globally.

## Running the tests

The tests only build SQL, but they need a live connection to do it. SQLite is
the default; set `ADAPTER` to run the same suite against another one.

```sh
rake test                    # sqlite3
ADAPTER=postgresql rake test
ADAPTER=mysql2 rake test     # MariaDB
rake test:mysql8             # Oracle's MySQL, on port 3307
rake test:all                # all of the above; MySQL skipped when 3307 is empty
```

PostgreSQL and the MySQLs are reached on `127.0.0.1` as the current user with
no password, which is how the devcontainer sets them up — MariaDB on its own
port and Oracle's MySQL on 3307, since the two answer the `mysql2` adapter
differently and CI runs both. Override with `DB_HOST`, `DB_PORT`,
`DB_USERNAME` and `DB_PASSWORD`. The `activerecord_refined_test` database is
created on first use.

The client gems sit in optional Gemfile groups named after their adapters,
since building each needs its client library installed. A plain bundle
serves SQLite with nothing extra; opt in to the adapters you will reach:

```sh
bundle config set --local with postgresql mysql2 trilogy
```

CI runs one job per adapter with the servers as service containers, Oracle
and SQL Server included — those two have no local server here and run on CI
alone, their clients opted in the same way.

Coverage is opt-in: `COVERAGE=1 rake test` writes an HTML report to
`coverage/`, and `COVERAGE=1 rake test:all` merges the adapters' runs into
one — the number worth reading, since a dialect's lines are reached only by
its own adapter's leg. The Oracle and SQL Server dialects stay mostly
uncovered locally for the same reason their tests run on CI alone.

## Releasing

Pushing a `v*` tag runs `.github/workflows/push_gem.yml`, which builds the gem
and publishes it through RubyGems.org's trusted publishing, so no API key is
stored anywhere.

```sh
bundle exec bump patch --tag # or bump {major,minor} etc.
git push --follow-tags
```
