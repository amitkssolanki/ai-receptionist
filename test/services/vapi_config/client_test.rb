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
end
