# frozen_string_literal: true

module HTTPX::Plugins::CircuitBreaker
  using HTTPX::URIExtensions

  class CircuitStore
    def initialize(options)
      @circuits = Hash.new do |h, k|
        h[k] = Circuit.new(
          options.circuit_breaker_max_attempts,
          options.circuit_breaker_reset_attempts_in,
          options.circuit_breaker_break_in,
          options.circuit_breaker_half_open_drip_rate
        )
      end
    end

    def try_open(uri, response)
      circuit = get_circuit_for_uri(uri)

      circuit.try_open(response)
    end

    # if circuit is open, it'll respond with the stored response.
    # if not, nil.
    def try_respond(request)
      circuit = get_circuit_for_uri(request.uri)

      circuit.respond
    end

    private

    def get_circuit_for_uri(uri)
      uri = URI(uri)

      if @circuits.key?(uri.origin)
        @circuits[uri.origin]
      else
        @circuits[uri.to_s]
      end
    end
  end
end
