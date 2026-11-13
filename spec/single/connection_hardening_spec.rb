# frozen_string_literal: true

RSpec.describe 'Connection hardening' do
  let(:http_connection) { instance_double(Net::HTTP) }
  let(:success_body) { %(["result"]\n["UInt8"]\n[1]\n) }
  let(:success_response) { instance_double(Net::HTTPResponse, code: '200', body: success_body) }

  before do
    allow(http_connection).to receive(:use_ssl=)
    allow(http_connection).to receive(:verify_mode=)
    allow(http_connection).to receive(:open_timeout=)
    allow(http_connection).to receive(:keep_alive_timeout=)
    allow(http_connection).to receive(:read_timeout=)
    allow(http_connection).to receive(:write_timeout=)
    allow(http_connection).to receive(:ca_file=)
    allow(http_connection).to receive(:started?).and_return(true)
    allow(http_connection).to receive(:finish)
  end

  describe 'connect' do
    subject(:client) { ActiveRecord::Base.clickhouse_connection(config).instance_variable_get(:@connection) }

    let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db' } }

    it 'opens no socket until the first request' do
      expect(client).not_to be_started
    end

    context 'without open_timeout configured' do
      it "keeps Net::HTTP's own default" do
        expect(client.open_timeout).to eq(Net::HTTP.new('localhost').open_timeout)
      end
    end

    context 'with open_timeout configured' do
      let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db', open_timeout: 5 } }

      it 'sets it on the client' do
        expect(client.open_timeout).to eq(5)
      end
    end

    context 'by default' do
      it 'does not verify the TLS certificate, matching prior behavior' do
        expect(client.verify_mode).to eq(OpenSSL::SSL::VERIFY_NONE)
      end
    end

    context 'with insecure: false' do
      let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db', insecure: false } }

      it 'verifies the TLS certificate' do
        expect(client.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
      end
    end

    context 'with sslca configured' do
      let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db', sslca: '/path/to/ca.pem' } }

      it 'sets ca_file on the client' do
        expect(client.ca_file).to eq('/path/to/ca.pem')
      end
    end
  end

  describe 'session settings' do
    let(:config) do
      {
        adapter: 'clickhouse',
        host: 'localhost',
        database: 'db',
        max_execution_time: 25,
        cancel_http_readonly_queries_on_client_close: true
      }
    end

    subject(:adapter) { ActiveRecord::Base.clickhouse_connection(config) }

    before { allow(Net::HTTP).to receive(:new).and_return(http_connection) }

    it 'merges max_execution_time into the request params sent with every query' do
      expect(adapter.instance_variable_get(:@connection_config)[:max_execution_time]).to eq(25)
    end

    it 'merges cancel_http_readonly_queries_on_client_close into the request params' do
      expect(adapter.instance_variable_get(:@connection_config)[:cancel_http_readonly_queries_on_client_close]).to eq(true)
    end
  end

  shared_context 'with a stubbed client' do
    subject(:adapter) { ActiveRecord::Base.clickhouse_connection(config) }

    let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db' } }

    before { allow(Net::HTTP).to receive(:new).and_return(http_connection) }
  end

  connect_errors = [Net::OpenTimeout, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH]
  connection_lost_errors = [EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError]

  describe '#exec_query' do
    include_context 'with a stubbed client'

    connection_lost_errors.each do |error|
      context "when the connection drops (#{error})" do
        it 'retries a read once on a new connection and succeeds' do
          call_count = 0
          allow(http_connection).to receive(:post) do
            call_count += 1
            call_count == 1 ? raise(error) : success_response
          end

          expect(adapter.exec_query('SELECT 1').rows).to eq([[1]])
          expect(call_count).to eq(2)
        end

        it 'only retries once, then raises ActiveRecord::ConnectionFailed with the network error as its cause' do
          allow(http_connection).to receive(:post).and_raise(error)

          expect { adapter.exec_query('SELECT 1') }
            .to raise_error(ActiveRecord::ConnectionFailed) { |e| expect(e.cause).to be_a(error) }
          expect(http_connection).to have_received(:post).twice
        end
      end
    end

    context 'when the connection drops on a write' do
      it 'does not run it again' do
        allow(http_connection).to receive(:post).and_raise(Errno::ECONNRESET)

        expect { adapter.exec_query('INSERT INTO t SELECT 1') }.to raise_error(ActiveRecord::ConnectionFailed)
        expect(http_connection).to have_received(:post).once
      end
    end

    context 'when the connection drops on a statement that Rails passes with allow_retry' do
      it 'runs it again' do
        call_count = 0
        allow(http_connection).to receive(:post) do
          call_count += 1
          call_count == 1 ? raise(Errno::ECONNRESET) : success_response
        end

        adapter.internal_exec_query('OPTIMIZE TABLE t', 'SQL', [], allow_retry: true)

        expect(call_count).to eq(2)
      end
    end

    connect_errors.each do |error|
      context "when the connection fails to open (#{error}), without retry_on_connect_error" do
        it 'does not retry and raises ActiveRecord::ConnectionNotEstablished with the network error as its cause' do
          allow(http_connection).to receive(:post).and_raise(error)

          expect { adapter.exec_query('SELECT 1') }
            .to raise_error(ActiveRecord::ConnectionNotEstablished) { |e| expect(e.cause).to be_a(error) }
          expect(http_connection).to have_received(:post).once
        end
      end
    end

    context 'when the first request of a new adapter fails to open the connection' do
      before do
        allow(http_connection).to receive(:started?).and_return(false)
        allow(http_connection).to receive(:start).and_raise(SocketError)
      end

      it 'raises ActiveRecord::ConnectionNotEstablished' do
        expect { adapter.exec_query('SELECT 1') }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      end
    end

    context 'when retry_on_connect_error is the string "false", as Rails passes it from a URL' do
      let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db', retry_on_connect_error: 'false' } }

      it 'does not retry a refused connection' do
        allow(http_connection).to receive(:post).and_raise(Errno::ECONNREFUSED)

        expect { adapter.exec_query('SELECT 1') }.to raise_error(ActiveRecord::ConnectionNotEstablished)
        expect(http_connection).to have_received(:post).once
      end
    end

    context 'with retry_on_connect_error' do
      let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db', retry_on_connect_error: true } }

      connect_errors.each do |error|
        context "when the connection fails to open (#{error})" do
          it 'retries once and succeeds' do
            call_count = 0
            allow(http_connection).to receive(:post) do
              call_count += 1
              call_count == 1 ? raise(error) : success_response
            end

            expect(adapter.exec_query('SELECT 1').rows).to eq([[1]])
            expect(call_count).to eq(2)
          end

          it 'only retries once, then raises ActiveRecord::ConnectionNotEstablished' do
            allow(http_connection).to receive(:post).and_raise(error)

            expect { adapter.exec_query('SELECT 1') }.to raise_error(ActiveRecord::ConnectionNotEstablished)
            expect(http_connection).to have_received(:post).twice
          end
        end
      end

      context 'when a started session fails to reopen its socket' do
        before do
          started = true
          allow(http_connection).to receive(:started?) { started }
          allow(http_connection).to receive(:finish) { started = false }
          allow(http_connection).to receive(:start) { started = true }
        end

        it 'finishes the session and retries on a new one' do
          call_count = 0
          allow(http_connection).to receive(:post) do
            call_count += 1
            call_count == 1 ? raise(Errno::ECONNREFUSED) : success_response
          end

          expect(adapter.exec_query('SELECT 1').rows).to eq([[1]])
          expect(http_connection).to have_received(:finish).ordered
          expect(http_connection).to have_received(:start).once.ordered
        end
      end

      context 'when the first request of a new adapter fails to open the connection' do
        before do
          started = false
          start_count = 0
          allow(http_connection).to receive(:started?) { started }
          allow(http_connection).to receive(:start) do
            start_count += 1
            raise Errno::ECONNREFUSED if start_count == 1

            started = true
          end
        end

        it 'retries a query once and succeeds' do
          allow(http_connection).to receive(:post).and_return(success_response)

          expect(adapter.exec_query('SELECT 1').rows).to eq([[1]])
          expect(http_connection).to have_received(:start).twice
        end

        it 'retries a streamed query once and succeeds' do
          streaming_response = instance_double(Net::HTTPResponse, code: '200')
          allow(streaming_response).to receive(:read_body).and_yield("id\n1\n")
          allow(http_connection).to receive(:request) { |_request, _sql, &callback| callback.call(streaming_response) }

          file = adapter.execute_to_file('SELECT 1')

          expect(file.read).to eq("id\n1\n")
          expect(http_connection).to have_received(:start).twice
          file.close!
        end
      end
    end

    [Net::ReadTimeout, Net::WriteTimeout].each do |error|
      context "on #{error}" do
        it 'does not retry and raises ActiveRecord::AdapterTimeout instead' do
          allow(http_connection).to receive(:post).and_raise(error)

          expect { adapter.exec_query('SELECT 1') }.to raise_error(ActiveRecord::AdapterTimeout)
          expect(http_connection).to have_received(:post).once
        end
      end
    end

    context 'when the server cancels the query via max_execution_time' do
      it 'raises ActiveRecord::StatementTimeout' do
        response = instance_double(
          Net::HTTPResponse,
          code: '500',
          body: 'Code: 159. DB::Exception: Timeout exceeded (TIMEOUT_EXCEEDED)'
        )
        allow(http_connection).to receive(:post).and_return(response)

        expect { adapter.exec_query('SELECT 1') }.to raise_error(ActiveRecord::StatementTimeout)
      end
    end

    context 'when the server rejects the statement' do
      it 'raises ActiveRecord::StatementInvalid' do
        response = instance_double(
          Net::HTTPResponse,
          code: '400',
          body: 'Code: 62. DB::Exception: Syntax error: failed at position 1 (SYNTAX_ERROR)'
        )
        allow(http_connection).to receive(:post).and_return(response)

        expect { adapter.exec_query('SELEC 1') }.to raise_error(ActiveRecord::StatementInvalid, /SYNTAX_ERROR/)
      end
    end
  end

  describe '#exec_insert_all' do
    include_context 'with a stubbed client'

    let(:insert) { 'INSERT INTO t (id) VALUES (1)' }
    let(:insert_response) { instance_double(Net::HTTPResponse, code: '200', body: '') }

    connect_errors.each do |error|
      context "when the connection fails to open (#{error}), without retry_on_connect_error" do
        it 'does not retry and raises ActiveRecord::ConnectionNotEstablished' do
          allow(http_connection).to receive(:post).and_raise(error)

          expect { adapter.exec_insert_all(insert, 'Bulk Insert') }
            .to raise_error(ActiveRecord::ConnectionNotEstablished) { |e| expect(e.cause).to be_a(error) }
          expect(http_connection).to have_received(:post).once
        end
      end
    end

    connection_lost_errors.each do |error|
      context "when the connection drops (#{error})" do
        it 'does not retry, so the server cannot apply the insert twice, and raises ActiveRecord::ConnectionFailed' do
          allow(http_connection).to receive(:post).and_raise(error)

          expect { adapter.exec_insert_all(insert, 'Bulk Insert') }
            .to raise_error(ActiveRecord::ConnectionFailed) { |e| expect(e.cause).to be_a(error) }
          expect(http_connection).to have_received(:post).once
        end
      end
    end

    context 'when the server rejects the statement' do
      it 'raises ActiveRecord::StatementInvalid' do
        response = instance_double(
          Net::HTTPResponse,
          code: '400',
          body: 'Code: 168. DB::Exception: AST is too big. Maximum: 50000 (TOO_BIG_AST)'
        )
        allow(http_connection).to receive(:post).and_return(response)

        expect { adapter.exec_insert_all(insert, 'Bulk Insert') }.to raise_error(ActiveRecord::StatementInvalid, /TOO_BIG_AST/)
      end
    end

    context 'with retry_on_connect_error' do
      let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db', retry_on_connect_error: true } }

      connect_errors.each do |error|
        context "when the connection fails to open (#{error})" do
          it 'retries once and succeeds' do
            call_count = 0
            allow(http_connection).to receive(:post) do
              call_count += 1
              call_count == 1 ? raise(error) : insert_response
            end

            expect(adapter.exec_insert_all(insert, 'Bulk Insert')).to be(true)
            expect(call_count).to eq(2)
          end

          it 'only retries once, then raises ActiveRecord::ConnectionNotEstablished' do
            allow(http_connection).to receive(:post).and_raise(error)

            expect { adapter.exec_insert_all(insert, 'Bulk Insert') }.to raise_error(ActiveRecord::ConnectionNotEstablished)
            expect(http_connection).to have_received(:post).twice
          end
        end
      end

      context 'when the connection drops (Errno::ECONNRESET)' do
        it 'does not retry' do
          allow(http_connection).to receive(:post).and_raise(Errno::ECONNRESET)

          expect { adapter.exec_insert_all(insert, 'Bulk Insert') }.to raise_error(ActiveRecord::ConnectionFailed)
          expect(http_connection).to have_received(:post).once
        end
      end
    end
  end
end
