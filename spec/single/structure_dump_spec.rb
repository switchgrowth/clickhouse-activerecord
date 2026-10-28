# frozen_string_literal: true

require 'clickhouse-activerecord/tasks'

RSpec.describe 'Structure dump', :migrations do
  let(:connection) { ActiveRecord::Base.connection }
  let(:database) { ActiveRecord::Base.connection_db_config.database }
  let(:tasks) { ClickhouseActiverecord::Tasks.new(ActiveRecord::Base.connection_db_config) }

  after { connection.execute('DROP FUNCTION IF EXISTS structure_spec_double', nil, format: nil) }

  def dump
    Tempfile.create(['structure', '.sql']) do |file|
      tasks.structure_dump(file.path)
      File.read(file.path)
    end
  end

  # Loads the structure into an empty database. The suite shares one database, so this empties it
  # table by table and keeps the database itself.
  def load_structure(structure)
    Tempfile.create(['structure', '.sql']) do |file|
      file.write(structure)
      file.flush
      connection.execute('DROP VIEW IF EXISTS structure_spec_view')
      clear_db
      tasks.structure_load(file.path)
    end
  end

  def show_create_tables
    connection.tables.sort.to_h { |name| [name, connection.show_create_table(name)] }
  end

  it 'loads back computed columns, codecs, time zones and views, and dumps them the same' do
    connection.execute(<<~SQL)
      CREATE TABLE structure_spec (
        id UInt64,
        version DateTime64(6) DEFAULT now64(6),
        happened_at DateTime64(6, 'UTC'),
        metadata String,
        campaign_type LowCardinality(String) MATERIALIZED JSONExtractString(metadata, 'campaign_type'),
        compressed UInt32 MATERIALIZED length(metadata) CODEC(ZSTD(1)),
        doubled UInt64 ALIAS id * 2,
        amount Decimal(18, 2) DEFAULT 0
      ) ENGINE = ReplacingMergeTree(version) ORDER BY id
    SQL
    connection.execute('CREATE VIEW structure_spec_view AS SELECT id FROM structure_spec')
    tables = show_create_tables
    structure = dump

    load_structure(structure)

    expect(show_create_tables).to eq(tables)
    expect(dump).to eq(structure)
  end

  it 'keeps a quoted string that mentions the database' do
    connection.execute(<<~SQL)
      CREATE TABLE structure_spec (id UInt64, source String DEFAULT 'copied from #{database}.example') ENGINE = MergeTree ORDER BY id
    SQL

    load_structure(dump)

    default = connection.select_value("SELECT default_expression FROM system.columns WHERE database = '#{database}' AND table = 'structure_spec' AND name = 'source'")
    expect(default).to eq("'copied from #{database}.example'")
  end

  it 'loads into a database with another name, with names qualified for that database' do
    other = "#{database}_structure_spec"
    connection.execute('CREATE TABLE structure_spec (id UInt64, name String) ENGINE = MergeTree ORDER BY id')
    connection.execute(<<~SQL)
      CREATE DICTIONARY structure_spec_dict (id UInt64, name String) PRIMARY KEY id
      SOURCE(CLICKHOUSE(TABLE 'structure_spec')) LIFETIME(0) LAYOUT(FLAT())
    SQL
    connection.execute(<<~SQL)
      CREATE VIEW structure_spec_view AS SELECT dictGet('#{database}.structure_spec_dict', 'name', id) AS name FROM structure_spec
    SQL
    structure = dump

    connection.execute("CREATE DATABASE #{other}")
    ActiveRecord::Base.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash.merge(database: other))
    Tempfile.create(['structure', '.sql']) do |file|
      file.write(structure)
      file.flush
      tasks.structure_load(file.path)
    end

    view = ActiveRecord::Base.connection.select_value(
      "SELECT create_table_query FROM system.tables WHERE database = '#{other}' AND name = 'structure_spec_view'"
    )
    expect(view).to include("dictGet('#{other}.structure_spec_dict'")
  ensure
    ActiveRecord::Base.establish_connection(:default)
    ActiveRecord::Base.connection.execute("DROP DATABASE IF EXISTS #{other}")
    ActiveRecord::Base.connection.execute('DROP VIEW IF EXISTS structure_spec_view')
    ActiveRecord::Base.connection.execute('DROP DICTIONARY IF EXISTS structure_spec_dict')
  end

  it 'loads while the server already has its user-defined functions' do
    connection.execute('CREATE FUNCTION structure_spec_double AS (x) -> x * 2', nil, format: nil)

    expect { load_structure(dump) }.not_to raise_error
  end

  it 'leaves out the tables that the schema dumper ignores' do
    connection.execute('CREATE TABLE structure_spec (id UInt64) ENGINE = MergeTree ORDER BY id')
    connection.execute('CREATE TABLE structure_spec_ignored (id UInt64) ENGINE = MergeTree ORDER BY id')
    ignore_tables = ActiveRecord::SchemaDumper.ignore_tables
    ActiveRecord::SchemaDumper.ignore_tables = [/ignored/]

    structure = dump

    expect(structure).to match(/CREATE TABLE structure_spec\s/)
    expect(structure).not_to include('structure_spec_ignored')
  ensure
    ActiveRecord::SchemaDumper.ignore_tables = ignore_tables
  end
end
