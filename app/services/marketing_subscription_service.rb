class MarketingSubscriptionService
  # Согласие на маркетинг (флаги), без учёта верификации email.
  # Нужно для отписки: снимаем opt-in даже у неверифицированных.
  def self.opted_in?(user)
    user.email_marketing == true || user.newsletter_consent == true
  end

  # Можно слать маркетинговые письма: есть email + подтверждён + согласие.
  # Транзакционные письма этим методом не ограничиваются — достаточно наличия email.
  def self.subscribed?(user)
    user.email.present? && user.email_verified? && opted_in?(user)
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
