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

  def round_trip(columns, order_by: 'tuple()')
    connection.execute("CREATE TABLE round_trip (#{columns}) ENGINE = MergeTree ORDER BY #{order_by}")
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

  it 'keeps DateTime64 precision other than 3 and a plain DateTime' do
    round_trip('id UInt64, happened_at DateTime64(9), logged_at DateTime')
  end

  it 'creates a DateTime64 when add_column gives a datetime precision' do
    connection.execute('CREATE TABLE round_trip (id UInt64) ENGINE = MergeTree ORDER BY tuple()')
    connection.add_column :round_trip, :seen_at, :datetime, precision: 6, null: false

    expect(connection.show_create_table('round_trip')).to include('`seen_at` DateTime64(6)')
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

    expect(schema).to include('as: "toUnixTimestamp(submitted_at) - toUnixTimestamp(event_at)", stored: true')
    expect(schema).not_to match(/"campaign_type".*default:/)
  end

  it 'keeps ALIAS columns' do
    schema = round_trip('id UInt64, amount UInt32, doubled UInt64 ALIAS amount * 2')

    expect(schema).to include('as: "amount * 2"')
    expect(schema).not_to match(/"doubled".*stored:/)
  end

  it 'keeps a codec after a DEFAULT or MATERIALIZED expression' do
    round_trip(<<~SQL)
      id UInt64,
      amount UInt32 DEFAULT 1 CODEC(ZSTD(1)),
      doubled UInt64 MATERIALIZED amount * 2 CODEC(ZSTD(1))
    SQL
  end

  it 'refuses a computed column with a default' do
    expect do
      connection.create_table(:round_trip, id: false, options: 'MergeTree ORDER BY tuple()') do |t|
        t.integer :amount, as: '1', default: 2
      end
    end.to raise_error(ArgumentError, /'as'/)
  end

  it 'keeps integer signedness' do
    round_trip('id UInt64, signed_count Int32, unsigned_count UInt32')
  end

  it 'keeps a whole-number Decimal or Float default as written' do
    round_trip('id UInt64, amount Decimal(18, 2) DEFAULT 0, ratio Float64 DEFAULT 0')
  end

  it 'dumps an id that is not the last column in place' do
    schema = round_trip('id UInt64, name String', order_by: 'id')

    expect(schema).to include('create_table "round_trip", id: false')
  end

  it 'keeps the id option for an id column that is last' do
    schema = round_trip('name String, id UInt64', order_by: 'id')

    expect(schema).to include('create_table "round_trip", id: :uint64')
  end
end
