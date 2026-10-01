require "test_helper"

class VapiConfig::ClientTest < ActiveSupport::TestCase
  KEY = "TEST-PRIVATE-KEY-DO-NOT-LEAK".freeze

  def client(responses = nil, key: KEY, **routes)
    responses ||= routes
    @requests = []
    fetch = lambda do |path, used_key|
      @requests << [ path, used_key ]
      responses.fetch(path, [ 404, "{}" ])
    end
    VapiConfig::Client.new(private_key: key, fetch: fetch)
  end

  test "fetches the assistant and its tools: inline ones as given, referenced ones by id" do
    inline = { "id" => "t1", "function" => { "name" => "get_menu" } }
    referenced = { "id" => "t2", "function" => { "name" => "get_cart" } }
    assistant = { "id" => "a1", "model" => { "tools" => [ inline ], "toolIds" => [ "t1", "t2" ] } }
    c = client("/assistant/a1" => [ 200, assistant.to_json ], "/tool/t2" => [ 200, referenced.to_json ])

    got_assistant, tools = c.assistant_with_tools("a1")

    assert_equal "a1", got_assistant["id"]
    assert_equal [ inline, referenced ], tools
    assert_equal [ "/assistant/a1", "/tool/t2" ], @requests.map(&:first), "only GETs of the assistant and tools it references"
  end

  test "is read-only by construction: the only verb it has is GET of assistants and tools" do
    source = Rails.root.join("app/services/vapi_config/client.rb").read
    assert_no_match(/Net::HTTP::(Post|Put|Patch|Delete)/, source)
    assert_no_match(/\.(post|put|patch|delete)\b/, source)
  end

  test "refuses to run without a key or an assistant id, naming what to set and never a value" do
    error = assert_raises(VapiConfig::Client::Error) { client({}, key: nil).assistant_with_tools("a1") }
    assert_match(/VAPI_PRIVATE_KEY/, error.message)
    error = assert_raises(VapiConfig::Client::Error) { client({}).assistant_with_tools(nil) }
    assert_match(/VAPI_DEV_ASSISTANT_ID/, error.message)
  end

  test "errors mention the status and an anonymised path, never the key or the assistant id" do
    error = assert_raises(VapiConfig::Client::Error) { client("/assistant/secret-assistant-id" => [ 401, "unauthorized" ]).assistant_with_tools("secret-assistant-id") }
    assert_equal "Vapi returned HTTP 401 for GET /assistant/:id", error.message
    assert_no_match(/#{KEY}|secret-assistant-id/, error.message)

    error = assert_raises(VapiConfig::Client::Error) { client("/assistant/a1" => [ 200, "<html>" ]).assistant_with_tools("a1") }
    assert_match(/not JSON/, error.message)
  end

  test "the key is only ever passed to the fetcher" do
    c = client("/assistant/a1" => [ 200, { "model" => {} }.to_json ])
    c.assistant_with_tools("a1")
    assert_equal [ KEY ], @requests.map(&:last).uniq
    assert_no_match(/#{KEY}/, c.inspect.gsub(/@private_key=[^,>]*/, ""))
  end

  # --- the real transport (http_get), with Net::HTTP replaced: no network ---

  FakeResponse = Struct.new(:code, :body)

  def with_net_http(response: nil, raise_error: nil)
    seen = {}
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      seen[:request] = request
      response
    end
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |host, port, **options, &block|
      seen.merge!(host: host, port: port, options: options)
      raise raise_error if raise_error

      block.call(fake_http)
    end
    yield seen
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  test "the default transport sends one GET over TLS to api.vapi.ai with the key as a bearer token and bounded timeouts" do
    with_net_http(response: FakeResponse.new("200", { "id" => "a1", "model" => {} }.to_json)) do |seen|
      assistant, tools = VapiConfig::Client.new(private_key: KEY).assistant_with_tools("a1")

      assert_equal [ "a1", [] ], [ assistant["id"], tools ]
      assert_equal [ "api.vapi.ai", 443 ], seen.values_at(:host, :port)
      assert_equal({ use_ssl: true, open_timeout: 10, read_timeout: 20 }, seen[:options])
      assert_kind_of Net::HTTP::Get, seen[:request]
      assert_equal "/assistant/a1", seen[:request].path
      assert_equal "Bearer #{KEY}", seen[:request]["Authorization"]
    end
  end

  test "the default transport reports the HTTP status of a failed response" do
    with_net_http(response: FakeResponse.new("503", "unavailable")) do
      error = assert_raises(VapiConfig::Client::Error) { VapiConfig::Client.new(private_key: KEY).assistant_with_tools("a1") }
      assert_equal "Vapi returned HTTP 503 for GET /assistant/:id", error.message
    end
  end

  test "network failures become a Client::Error naming only the failure class, never the key or the error text" do
    [ SocketError.new("getaddrinfo #{KEY}"), Net::OpenTimeout.new(KEY), Errno::ECONNREFUSED.new(KEY), OpenSSL::SSL::SSLError.new(KEY) ].each do |failure|
      with_net_http(raise_error: failure) do
        error = assert_raises(VapiConfig::Client::Error) { VapiConfig::Client.new(private_key: KEY).assistant_with_tools("a1") }
        assert_equal "could not reach Vapi (#{failure.class})", error.message
        assert_no_match(/#{KEY}/, error.message)
      end
    end
  end
end
