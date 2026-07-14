class MarketingSubscriptionService
  def self.subscribed?(user)
    user.email_marketing == true || user.newsletter_consent == true
  end

  def self.sync_user!(user)
    return unless user.email.present?

    if subscribed?(user)
      SendpulseMarketingSyncJob.perform_later(user.id, "subscribe")
    else
      SendpulseMarketingSyncJob.perform_later(user.id, "unsubscribe")
    end
  end
end
