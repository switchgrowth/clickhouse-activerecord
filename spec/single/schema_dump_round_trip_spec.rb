# frozen_string_literal: true

require 'clickhouse-activerecord/schema_dumper'

RSpec.describe 'Schema dump round trip', :migrations do
  let(:connection) { ActiveRecord::Base.connection }

  def dump
    ClickhouseActiverecord::SchemaDumper.dump(connection, StringIO.new).string
  end

  # Loads the dump from a file, the way Rails loads a schema file into an empty database.
  def load_dump(schema)
    Tempfile.create(['schema', '.rb']) do |file|
      file.write(schema)
      file.flush
      clear_db
      quietly { load file.path }
    end
  end

  def round_trip(columns)
    connection.execute("CREATE TABLE round_trip (#{columns}) ENGINE = MergeTree ORDER BY tuple()")
    original = connection.show_create_table('round_trip')
    first_dump = dump

    load_dump(first_dump)

    expect(connection.show_create_table('round_trip')).to eq(original)
    expect(dump).to eq(first_dump)
    first_dump
  end

  it 'keeps DateTime64 precision 6' do
    schema = round_trip('id UInt64, version DateTime64(6) DEFAULT now64(6)')

    expect(schema).to include('t.datetime "version", precision: 6')
  end

  it 'keeps DateTime64 precision other than 3' do
    round_trip('id UInt64, happened_at DateTime64(9), logged_at DateTime')
  end

  it 'keeps MATERIALIZED columns' do
    schema = round_trip(<<~SQL)
      id UInt64,
      submitted_at DateTime,
      event_at DateTime,
      metadata String,
      age_seconds Int32 MATERIALIZED toUnixTimestamp(submitted_at) - toUnixTimestamp(event_at),
      campaign_type LowCardinality(String) MATERIALIZED JSONExtractString(metadata, 'campaign_type'),
      enabled Bool MATERIALIZED JSONExtractBool(metadata, 'enabled')
    SQL

    expect(schema).to include('materialized: "toUnixTimestamp(submitted_at) - toUnixTimestamp(event_at)"')
  end

  it 'keeps ALIAS columns' do
    schema = round_trip('id UInt64, amount UInt32, doubled UInt64 ALIAS amount * 2')

    expect(schema).to include('alias: "amount * 2"')
  end

  it 'keeps integer signedness' do
    round_trip('id UInt64, signed_count Int32, unsigned_count UInt32')
  end

  it 'keeps a whole-number Decimal default as written' do
    round_trip('id UInt64, amount Decimal(18, 2) DEFAULT 0')
  end

  it 'keeps an id column that is not last in its position' do
    schema = round_trip('id UInt64, name String')

    expect(schema).to include('create_table "round_trip", id: false')
  end

  it 'keeps the id option for an id column that is last' do
    schema = round_trip('name String, id UInt64')

    expect(schema).to include('create_table "round_trip", id: :uint64')
  end
end
