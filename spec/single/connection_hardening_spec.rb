# frozen_string_literal: true

RSpec.describe 'Connection hardening' do
  let(:http_connection) { instance_double(Net::HTTP) }
  let(:success_body) { %(["result"]\n["UInt8"]\n[1]\n) }
  let(:success_response) { instance_double(Net::HTTPResponse, code: '200', body: success_body, '[]': nil) }

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

    context 'without keep_alive_timeout configured' do
      it "keeps Net::HTTP's own default until a response gives the server's timeout" do
        expect(client.keep_alive_timeout).to eq(Net::HTTP.new('localhost').keep_alive_timeout)
      end
    end

    context 'with open_timeout configured' do
      let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db', open_timeout: 5 } }

      it 'sets it on the client' do
        expect(client.open_timeout).to eq(5)
      end
    end

    context 'by default' do
      it 'does not verify the TLS certificate' do
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

  connect_errors = [Net::OpenTimeout, SocketError, Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL]
  connection_lost_errors = [
    EOFError, IOError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE, Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ENETDOWN, OpenSSL::SSL::SSLError
  ]

  describe 'keep-alive timeout' do
    subject(:adapter) { ActiveRecord::Base.clickhouse_connection(config) }

    let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db' } }
    let(:client) { Net::HTTP.new('localhost', 8123) }

    before do
      real_client = client
      allow(Net::HTTP).to receive(:new).and_return(real_client)
      allow(real_client).to receive(:started?).and_return(true)
    end

    def response_with(keep_alive, code: '200', body: success_body)
      instance_double(Net::HTTPResponse, code: code, body: body, '[]': nil).tap do |response|
        allow(response).to receive(:[]).with('Keep-Alive').and_return(keep_alive)
      end
    end

    def respond_with(*responses)
      allow(client).to receive(:post).and_return(*responses)
    end

    it "stops reusing the socket one second before the server's timeout" do
      respond_with(response_with('timeout=6, max=9999'))

      adapter.exec_query('SELECT 1')

      expect(client.keep_alive_timeout).to eq(5)
    end

    it 'follows the header on an error response, which can leave the socket open' do
      respond_with(response_with('timeout=6, max=9999', code: '400', body: 'Code: 62. DB::Exception: Syntax error (SYNTAX_ERROR)'))

      expect { adapter.exec_query('SELEC 1') }.to raise_error(ActiveRecord::StatementInvalid)
      expect(client.keep_alive_timeout).to eq(5)
    end

    it 'follows the header on a streamed query too' do
      streaming_response = response_with('timeout=6, max=9999')
      allow(streaming_response).to receive(:read_body).and_yield("id\n1\n")
      allow(client).to receive(:request) do |_request, _sql, &callback|
        callback.call(streaming_response)
        streaming_response
      end

      adapter.execute_to_file('SELECT 1').close!

      expect(client.keep_alive_timeout).to eq(5)
    end

    it 'keeps its timeout when a later response has no Keep-Alive header, as behind a proxy that removes it' do
      respond_with(response_with('timeout=6, max=9999'), response_with(nil))

      2.times { adapter.exec_query('SELECT 1') }

      expect(client.keep_alive_timeout).to eq(5)
    end

    it 'ignores a Keep-Alive header without a timeout' do
      respond_with(response_with('timeout=6, max=9999'), response_with('max=9999'))

      2.times { adapter.exec_query('SELECT 1') }

      expect(client.keep_alive_timeout).to eq(5)
    end

    it 'turns reuse off when the server keeps an idle connection for 1 second' do
      respond_with(response_with('timeout=1, max=9999'))

      adapter.exec_query('SELECT 1')

      expect(client.keep_alive_timeout).to eq(0)
    end

    context 'with keep_alive_timeout configured' do
      let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db', keep_alive_timeout: configured } }

      context 'above the server timeout' do
        let(:configured) { 300 }

        it "lowers it to one second before the server's timeout" do
          respond_with(response_with('timeout=6, max=9999'))

          adapter.exec_query('SELECT 1')

          expect(client.keep_alive_timeout).to eq(5)
        end
      end

      context 'below the server timeout' do
        let(:configured) { 3 }

        it 'keeps the configured value' do
          respond_with(response_with('timeout=6, max=9999'))

          adapter.exec_query('SELECT 1')

          expect(client.keep_alive_timeout).to eq(3)
        end
      end

      context 'when no response has a Keep-Alive header' do
        let(:configured) { 30 }

        it 'uses the configured value' do
          respond_with(response_with(nil))

          adapter.exec_query('SELECT 1')

          expect(client.keep_alive_timeout).to eq(30)
        end
      end
    end
  end

  describe '#verify!' do
    subject(:adapter) { ActiveRecord::Base.clickhouse_connection(config) }

    let(:config) { { adapter: 'clickhouse', host: '127.0.0.1', port: 1, database: 'db' } }

    it 'raises ActiveRecord::ConnectionNotEstablished when the server is unreachable' do
      expect { adapter.verify! }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    end
  end

  describe '#write_query?' do
    subject(:adapter) { ActiveRecord::Base.clickhouse_connection(config) }

    let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db' } }

    [
      'SELECT 1', 'with t AS (SELECT 1) SELECT * FROM t', 'SHOW TABLES', 'DESC t', 'DESCRIBE TABLE t',
      'EXISTS TABLE t', 'EXPLAIN SELECT 1', '/* comment */ SELECT 1', '(SELECT 1) UNION ALL (SELECT 2)'
    ].each do |sql|
      it "reads #{sql.inspect} as a read" do
        expect(adapter.write_query?(sql)).to be(false)
      end
    end

    ['INSERT INTO t SELECT 1', 'ALTER TABLE t DELETE WHERE 1', 'OPTIMIZE TABLE t', 'CREATE TABLE t (id UInt8) ENGINE = Memory'].each do |sql|
      it "reads #{sql.inspect} as a write" do
        expect(adapter.write_query?(sql)).to be(true)
      end
    end
  end

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
        it 'retries a read once and succeeds' do
          call_count = 0
          allow(http_connection).to receive(:post) do
            call_count += 1
            call_count == 1 ? raise(error) : success_response
          end

          expect(adapter.exec_query('SELECT 1').rows).to eq([[1]])
          expect(call_count).to eq(2)
        end

        it 'only retries once, then raises ActiveRecord::ConnectionNotEstablished with the network error as its cause' do
          allow(http_connection).to receive(:post).and_raise(error)

          expect { adapter.exec_query('SELECT 1') }
            .to raise_error(ActiveRecord::ConnectionNotEstablished) { |e| expect(e.cause).to be_a(error) }
          expect(http_connection).to have_received(:post).twice
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

      it 'does not retry a write on a refused connection' do
        allow(http_connection).to receive(:post).and_raise(Errno::ECONNREFUSED)

        expect { adapter.exec_query('INSERT INTO t SELECT 1') }.to raise_error(ActiveRecord::ConnectionNotEstablished)
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

          it 'retries in the session, then once more as a read, then raises ActiveRecord::ConnectionNotEstablished' do
            allow(http_connection).to receive(:post).and_raise(error)

            expect { adapter.exec_query('SELECT 1') }.to raise_error(ActiveRecord::ConnectionNotEstablished)
            expect(http_connection).to have_received(:post).exactly(4).times
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
          streaming_response = instance_double(Net::HTTPResponse, code: '200', '[]': nil)
          allow(streaming_response).to receive(:read_body).and_yield("id\n1\n")
          allow(http_connection).to receive(:request) do |_request, _sql, &callback|
            callback.call(streaming_response)
            streaming_response
          end

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

    context 'on an interrupt' do
      it 'finishes the session and raises the interrupt unchanged' do
        allow(http_connection).to receive(:post).and_raise(Interrupt)

        expect { adapter.exec_query('SELECT 1') }.to raise_error(Interrupt)
        expect(http_connection).to have_received(:finish)
        expect(http_connection).to have_received(:post).once
      end
    end

    context 'when the server cancels the query via max_execution_time' do
      it 'raises ActiveRecord::StatementTimeout' do
        response = instance_double(
          Net::HTTPResponse,
          '[]': nil,
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
          '[]': nil,
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
    let(:insert_response) { instance_double(Net::HTTPResponse, code: '200', body: '', '[]': nil) }

    context 'when the connection fails to open, without retry_on_connect_error' do
      it 'does not retry and raises ActiveRecord::ConnectionNotEstablished' do
        allow(http_connection).to receive(:post).and_raise(Errno::ECONNREFUSED)

        expect { adapter.exec_insert_all(insert, 'Bulk Insert') }
          .to raise_error(ActiveRecord::ConnectionNotEstablished) { |e| expect(e.cause).to be_a(Errno::ECONNREFUSED) }
        expect(http_connection).to have_received(:post).once
      end
    end

    context 'when the connection drops' do
      it 'does not retry, so the server cannot apply the insert twice, and raises ActiveRecord::ConnectionFailed' do
        allow(http_connection).to receive(:post).and_raise(Errno::ECONNRESET)

        expect { adapter.exec_insert_all(insert, 'Bulk Insert') }
          .to raise_error(ActiveRecord::ConnectionFailed) { |e| expect(e.cause).to be_a(Errno::ECONNRESET) }
        expect(http_connection).to have_received(:post).once
      end
    end

    context 'when the server rejects the statement' do
      it 'raises ActiveRecord::StatementInvalid' do
        response = instance_double(
          Net::HTTPResponse,
          '[]': nil,
          code: '400',
          body: 'Code: 168. DB::Exception: AST is too big. Maximum: 50000 (TOO_BIG_AST)'
        )
        allow(http_connection).to receive(:post).and_return(response)

        expect { adapter.exec_insert_all(insert, 'Bulk Insert') }.to raise_error(ActiveRecord::StatementInvalid, /TOO_BIG_AST/)
      end
    end

    context 'with retry_on_connect_error' do
      let(:config) { { adapter: 'clickhouse', host: 'localhost', database: 'db', retry_on_connect_error: true } }

      context 'when the connection fails to open' do
        it 'retries once and succeeds' do
          call_count = 0
          allow(http_connection).to receive(:post) do
            call_count += 1
            call_count == 1 ? raise(Errno::ECONNREFUSED) : insert_response
          end

          expect(adapter.exec_insert_all(insert, 'Bulk Insert')).to be(true)
          expect(call_count).to eq(2)
        end

        it 'only retries once, then raises ActiveRecord::ConnectionNotEstablished' do
          allow(http_connection).to receive(:post).and_raise(Errno::ECONNREFUSED)

          expect { adapter.exec_insert_all(insert, 'Bulk Insert') }.to raise_error(ActiveRecord::ConnectionNotEstablished)
          expect(http_connection).to have_received(:post).twice
        end
      end

      context 'when the host becomes unreachable, which the system also reports on an open connection' do
        it 'does not retry' do
          allow(http_connection).to receive(:post).and_raise(Errno::EHOSTUNREACH)

          expect { adapter.exec_insert_all(insert, 'Bulk Insert') }.to raise_error(ActiveRecord::ConnectionFailed)
          expect(http_connection).to have_received(:post).once
        end
      end
    end
  end

  describe 'other statements' do
    include_context 'with a stubbed client'

    it 'raises ActiveRecord::ConnectionFailed from #exec_update, #exec_delete and #execute_to_file, without a retry' do
      allow(http_connection).to receive(:post).and_raise(Errno::ECONNRESET)
      allow(http_connection).to receive(:request).and_raise(Errno::ECONNRESET)

      expect { adapter.exec_update('ALTER TABLE t UPDATE id = 1 WHERE 1') }.to raise_error(ActiveRecord::ConnectionFailed)
      expect { adapter.exec_delete('DELETE FROM t WHERE 1') }.to raise_error(ActiveRecord::ConnectionFailed)
      expect { adapter.execute_to_file('SELECT 1') }.to raise_error(ActiveRecord::ConnectionFailed)
      expect(http_connection).to have_received(:post).twice
      expect(http_connection).to have_received(:request).once
    end

    it 'does not report a full disk during #execute_to_file as a dropped connection' do
      streaming_response = instance_double(Net::HTTPResponse, code: '200', '[]': nil)
      allow(streaming_response).to receive(:read_body).and_yield("id\n1\n")
      allow(http_connection).to receive(:request) do |_request, _sql, &callback|
        callback.call(streaming_response)
        streaming_response
      end
      allow_any_instance_of(Tempfile).to receive(:write).and_raise(Errno::ENOSPC)

      expect { adapter.execute_to_file('SELECT 1') }.to raise_error(ActiveRecord::ActiveRecordError) { |e|
        expect(e).not_to be_a(ActiveRecord::ConnectionFailed)
        expect(e.cause).to be_a(Errno::ENOSPC)
      }
    end
  end
end
