require "net/http"

module VapiConfig
  # Read-only Vapi API client for vapi:check: GET /assistant/:id and GET /tool/:id, nothing else. The private key
  # is used as a bearer token and is never printed, logged or included in an error message.
  class Client
    class Error < StandardError; end

    API = "https://api.vapi.ai".freeze

    def initialize(private_key: VapiConfig.private_key, fetch: nil)
      @private_key = private_key
      @fetch = fetch || method(:http_get)
    end

    # Returns [assistant, tools]: the assistant body and every tool it uses (inline plus model.toolIds).
    def assistant_with_tools(assistant_id)
      raise Error, "no Vapi private key configured (VAPI_PRIVATE_KEY or credentials vapi.private_key)" if @private_key.blank?
      raise Error, "no development assistant id configured (VAPI_DEV_ASSISTANT_ID or credentials vapi.dev_assistant_id)" if assistant_id.blank?

      assistant = get("/assistant/#{assistant_id}")
      model = assistant["model"] || {}
      inline = Array(model["tools"])
      inline_ids = inline.filter_map { |t| t["id"] }
      referenced = Array(model["toolIds"]).reject { |id| inline_ids.include?(id) }.map { |id| get("/tool/#{id}") }
      [ assistant, inline + referenced ]
    end

    private

    def get(path)
      status, body = @fetch.call(path, @private_key)
      raise Error, "Vapi returned HTTP #{status} for GET #{path.sub(%r{/[^/]+\z}, '/:id')}" unless status == 200

      JSON.parse(body)
    rescue JSON::ParserError
      raise Error, "Vapi returned a response that is not JSON for GET #{path.sub(%r{/[^/]+\z}, '/:id')}"
    end

    def http_get(path, key)
      uri = URI("#{API}#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{key}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |http| http.request(request) }
      [ response.code.to_i, response.body ]
    rescue SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, "could not reach Vapi (#{e.class})"
    end
  end
end
