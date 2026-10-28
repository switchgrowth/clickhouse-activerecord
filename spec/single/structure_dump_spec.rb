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

  it 'loads back the same tables, and dumps them the same' do
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

  it 'keeps the database name inside a quoted string' do
    connection.execute(<<~SQL)
      CREATE TABLE structure_spec (id UInt64, source String DEFAULT '#{database}.example') ENGINE = MergeTree ORDER BY id
    SQL

    load_structure(dump)

    default = connection.select_value("SELECT default_expression FROM system.columns WHERE database = '#{database}' AND table = 'structure_spec' AND name = 'source'")
    expect(default).to eq("'#{database}.example'")
  end
end
