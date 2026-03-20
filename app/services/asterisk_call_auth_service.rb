class AsteriskCallAuthService
  include HTTParty
  base_uri 'https://callauth.asterisk.by'

  AUTH_TOKEN = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJjYWxsLWF1dGgtYXBpIiwiYXVkIjoiZXh0ZXJuYWwtYXBpIiwiZXhwIjoyMDg4NTg3MTQ4fQ.Z8SCd_VPEwLs6GdUzmzQ9GV_QM-5DALfkOpHRO1pFmw'
  
  # Available full caller numbers
  # Based on user input: "+375291915806" and "+375447765806"
  AVAILABLE_NUMBERS = ['+375291915806', '+375447765806'].freeze

  def self.get_caller_info
    number = AVAILABLE_NUMBERS.sample
    {
      number: number,
      code: number.to_s.last(4)
    }
  end

  def self.initiate_call(to_phone:, from_number:)
    # Normalizing phone
    to_phone = to_phone.to_s.gsub(/\D/, '')
    to_phone = "+#{to_phone}" unless to_phone.start_with?('+')

    options = {
      headers: {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{AUTH_TOKEN}"
      },
      body: {
        from: from_number,
        to: to_phone
      }.to_json
    }

    Rails.logger.info "\n[ASTERISK API CALL] URL: https://callauth.asterisk.by/call/auth, Body: #{options[:body]}\n"
    
    response = post('/call/auth', options)
    
    Rails.logger.info "\n[ASTERISK API RESPONSE] Status: #{response.code}, Body: #{response.body}\n"

    if response.success? && response.parsed_response['status'] == 'accepted'
      { success: true }
    else
      error_msg = response.parsed_response['error'] || response.parsed_response['message'] || response.parsed_response['status'] || "HTTP Error #{response.code}"
      { success: false, error: error_msg }
    end
  rescue => e
    Rails.logger.error "\n[ASTERISK API EXCEPTION] #{e.message}\n"
    { success: false, error: e.message }
  end
end
