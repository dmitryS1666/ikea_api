class MarketingSubscriptionService
  def self.sync_user!(user)
    return unless user.email.present?

    subscribed = user.email_marketing == true || user.newsletter_consent == true
    if subscribed
      SendpulseMarketingSyncJob.perform_later(user.id, "subscribe")
    else
      SendpulseMarketingSyncJob.perform_later(user.id, "unsubscribe")
    end
  end
end
