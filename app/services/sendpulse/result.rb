module Sendpulse
  class Result
    attr_reader :response, :error, :skipped

    def initialize(success:, response: nil, error: nil, skipped: false)
      @success = success
      @response = response
      @error = error
      @skipped = skipped
    end

    def success?
      @success
    end

    def skipped?
      @skipped
    end
  end
end
