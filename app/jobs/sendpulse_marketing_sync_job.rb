class SendpulseMarketingSyncJob < ApplicationJob
  queue_as :default

  retry_on Sendpulse::Error, wait: :exponentially_longer, attempts: 3

  def perform(user_id, action)
    user = User.find_by(id: user_id)
    return unless user&.email.present?

    case action.to_s
    when "subscribe"
      Sendpulse::MailingListSync.subscribe(email: user.email, name: user.full_name)
    when "unsubscribe"
      Sendpulse::MailingListSync.unsubscribe(email: user.email)
    end
  end
end
