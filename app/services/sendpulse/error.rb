module Sendpulse
  class Error < StandardError
    attr_reader :status, :response_body, :endpoint

    def initialize(message:, status:, response_body:, endpoint:)
      super(message)
      @status = status
      @response_body = response_body
      @endpoint = endpoint
    end
  end
end
