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

  collection do |params|
    scope = TransactionalEmailLog.includes(:user, :order).recent_first

    template_key = params[:template_key].to_s
    if TransactionalEmailLog::TEMPLATE_LABELS.key?(template_key)
      scope = scope.where(template_key: template_key)
    end

    q = params[:q].to_s.strip
    if q.present?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
      conditions = [
        "transactional_email_logs.to_email ILIKE :like",
        "transactional_email_logs.to_name ILIKE :like",
        "transactional_email_logs.subject ILIKE :like",
        "orders.public_uid ILIKE :like"
      ]
      binds = { like: like }

      if q.match?(/\A\d+\z/)
        conditions << "transactional_email_logs.id = :exact_id"
        conditions << "orders.id = :exact_id"
        binds[:exact_id] = q.to_i
      end

      scope = scope.left_joins(:order).where(conditions.join(" OR "), binds)
    end

    scope
  end

  hook("resource.index.header") do
    render partial: "trestle/transactional_email_logs/search_panel", locals: { admin: admin }
  end

  scopes do
    scope :all, label: "Все", default: true
    scope :queued, -> { TransactionalEmailLog.where(status: "queued") }, label: "В очереди"
    scope :sent, -> { TransactionalEmailLog.where(status: "sent") }, label: "Отправлено"
    scope :delivered, -> { TransactionalEmailLog.where(status: "delivered") }, label: "Доставлено"
    scope :opened, -> { TransactionalEmailLog.where(status: %w[opened clicked]) }, label: "Открыто"
    scope :failed, -> { TransactionalEmailLog.where(status: %w[failed undelivered soft_bounced hard_bounced spam]) }, label: "Ошибки"
  end

  table do
    column :queued_at, label: "Когда", align: :center do |log|
      (log.sent_at || log.queued_at)&.strftime("%d.%m.%Y %H:%M")
    end
    column :to_email, label: "Кому" do |log|
      if current_user&.can_view_personal_data?
        parts = [log.to_email]
        parts << log.to_name if log.to_name.present?
        safe_join(parts, " · ")
      else
        "Скрыто"
      end
    end
    column :template_key, label: "Письмо" do |log|
      status_tag(log.template_label, :primary)
    end
    column :subject, label: "Тема" do |log|
      content_tag(:span, log.subject, title: log.subject)
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

    tab :preview, label: "Превью" do
      row do
        col(sm: 12) do
          render partial: "trestle/transactional_email_logs/preview", locals: { log: log }
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
