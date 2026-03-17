class AsteriskCallAuthService
  include HTTParty
  base_uri 'https://callauth.asterisk.by'

  AUTH_TOKEN = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJjYWxsLWF1dGgtYXBpIiwiYXVkIjoiZXh0ZXJuYWwtYXBpIiwiZXhwIjoyMDg4NTg3MTQ4fQ.Z8SCd_VPEwLs6GdUzmzQ9GV_QM-5DALfkOpHRO1pFmw'
  
  # Available prefixes with some default numbers
  # Based on user input: "+375291915806" and "+375447765806"
  FROM_PREFIXES = ['+37529191', '+37544776'].freeze

  def self.initiate_call(to_phone:, code:)
    # Normalizing phone
    to_phone = to_phone.to_s.gsub(/\D/, '')
    to_phone = "+#{to_phone}" unless to_phone.start_with?('+')

    # Randomly pick one of the available prefixes
    from_prefix = FROM_PREFIXES.sample
    from_number = "#{from_prefix}#{code}"

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
