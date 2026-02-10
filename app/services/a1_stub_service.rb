class A1StubService
  # A1 integration is not available yet.
  # This service provides a predictable stub:
  # - request_call: creates verification with a generated caller number
  # - verify_call: checks last4 and marks verified
  #
  # Later, replace this service with real A1 API calls.

  def self.request_call(user:, phone:, context:)
    last4 = rand(0000..9999).to_s.rjust(4, '0')
    record = A1Verification.create!(
      user: user,
      phone: phone,
      context: context,
      status: 'pending',
      expected_last4: last4,
      expires_at: 10.minutes.from_now
    )

    {
      verification_id: record.id,
      phone: phone,
      display_message: "Введите последние 4 цифры номера, с которого поступил звонок",
      # In stub we cannot call user, so we return a masked number. Front can show this.
      # Format: +375 (XX) ***-**-1234
      caller_number_masked: "+375 (***) ***-**-#{last4}",
      expires_at: record.expires_at.iso8601
    }
  end

  def self.verify_call(verification_id:, last4:)
    record = A1Verification.find_by(id: verification_id)
    return { success: false, error: 'verification_not_found' } unless record

    if record.expired?
      record.update!(status: 'expired') if record.status == 'pending'
      return { success: false, error: 'verification_expired' }
    end

    if record.expected_last4.to_s == last4.to_s
      record.update!(status: 'verified')
      { success: true }
    else
      { success: false, error: 'invalid_last4' }
    end
  end
end
