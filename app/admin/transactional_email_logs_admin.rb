# frozen_string_literal: true

Trestle.resource(:transactional_email_logs, model: TransactionalEmailLog, readonly: true) do
  menu do
    item :transactional_email_logs,
         icon: "fa fa-envelope-open-text",
         group: :sales,
         label: "Письма клиентам",
         priority: 8,
         if: -> { current_user&.allowed_for_admin_resource?(:transactional_email_logs, :index) }
  end

  collection do
    TransactionalEmailLog.includes(:user, :order).recent_first
  end

  scopes do
    scope :all, default: true
    scope :queued, -> { TransactionalEmailLog.where(status: "queued") }
    scope :sent, -> { TransactionalEmailLog.where(status: "sent") }
    scope :delivered, -> { TransactionalEmailLog.where(status: "delivered") }
    scope :opened, -> { TransactionalEmailLog.where(status: %w[opened clicked]) }
    scope :failed, -> { TransactionalEmailLog.where(status: %w[failed undelivered soft_bounced hard_bounced spam]) }
    scope :order_delivered, -> { TransactionalEmailLog.where(template_key: "order_delivered") }
  end

  table do
    column :queued_at, label: "Когда", align: :center do |log|
      (log.sent_at || log.queued_at)&.strftime("%d.%m.%Y %H:%M")
    end
    column :to_email, label: "Кому" do |log|
      if current_user&.can_view_personal_data?
        parts = [log.to_email]
        parts << log.to_name if log.to_name.present?
        parts.join(" · ")
      else
        "Скрыто"
      end
    end
    column :template_key, label: "Письмо" do |log|
      log.template_label
    end
    column :subject, label: "Тема"
    column :preview_text, label: "Кратко" do |log|
      truncate(log.preview_text.to_s, length: 90)
    end
    column :status, label: "Статус" do |log|
      status_tag(log.status_label, email_status_color(log.status))
    end
    column :order, label: "Заказ" do |log|
      if log.order
        link_to(log.order.display_number, "/admin/orders/#{log.order.id}")
      else
        "—"
      end
    end
    actions do |toolbar|
      toolbar.show
    end
  end

  form do |log|
    tab :main, label: "Основное" do
      static_field :template_key, label: "Тип письма" do
        log.template_label
      end
      static_field :subject, label: "Тема"
      static_field :status, label: "Статус" do
        status_tag(log.status_label, email_status_color(log.status))
      end
      static_field :to_email, label: "Email" do
        current_user&.can_view_personal_data? ? log.to_email : "Скрыто"
      end
      static_field :to_name, label: "Имя" do
        current_user&.can_view_personal_data? ? (log.to_name.presence || "—") : "Скрыто"
      end
      static_field :preview_text, label: "Краткое содержание" do
        content_tag(:p, log.preview_text.presence || "—")
      end
      static_field :order, label: "Заказ" do
        if log.order
          link_to("№#{log.order.display_number}", "/admin/orders/#{log.order.id}")
        else
          "—"
        end
      end
      static_field :user, label: "Пользователь" do
        if log.user
          current_user&.can_view_personal_data? ? (log.user.username || log.user.id) : "Скрыто"
        else
          "—"
        end
      end
    end

    tab :delivery, label: "Доставка" do
      static_field :queued_at, label: "В очереди"
      static_field :sent_at, label: "Принято SendPulse"
      static_field :delivered_at, label: "Доставлено"
      static_field :opened_at, label: "Открыто"
      static_field :failed_at, label: "Ошибка"
      static_field :last_event_at, label: "Последнее событие"
      static_field :provider_message_id, label: "ID в SendPulse"
      static_field :error_message, label: "Текст ошибки" do
        content_tag(:pre, log.error_message.presence || "—")
      end
    end
  end

  controller do
    helper_method :email_status_color

    def email_status_color(status)
      case status.to_s
      when "delivered", "opened", "clicked" then :success
      when "sent", "queued" then :info
      when "failed", "undelivered", "hard_bounced", "spam" then :danger
      when "soft_bounced" then :warning
      else :secondary
      end
    end
  end
end
