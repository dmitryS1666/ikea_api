module Sendpulse
  class Result
    attr_reader :response, :error

    def initialize(success:, response: nil, error: nil)
      @success = success
      @response = response
      @error = error
    end

    def success?
      @success
    end
  end
end
