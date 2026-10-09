# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin transactional email logs", type: :request do
  let!(:admin) { create(:user, role: "admin", username: "mail_admin", is_active: true) }
  let!(:delivered) do
    create(
      :transactional_email_log,
      template_key: "order_delivered",
      subject: "Ваш заказ доставлен",
      preview_text: "UNIQUE_PREVIEW_SNIPPET",
      html_body: "<p>Как ушло клиенту</p>",
      to_email: "anna@example.com",
      to_name: "Анна"
    )
  end
  let!(:welcome) do
    create(
      :transactional_email_log,
      template_key: "welcome",
      subject: "Подтвердите e-mail",
      to_email: "other@example.com",
      html_body: "<p>Welcome</p>"
    )
  end

  before do
    post "/admin/login", params: { user: { username: admin.username, password: "password" } }
    expect(response).to have_http_status(:redirect)
  end

  it "filters the list by letter type and hides the short preview" do
    get "/admin/transactional_email_logs"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Все типы писем")
    expect(response.body).to include("Email, имя, тема или номер заказа")
    expect(response.body).to include("Ваш заказ доставлен")
    expect(response.body).to include("Подтвердите e-mail")
    expect(response.body).not_to include("Кратко")
    expect(response.body).not_to include("UNIQUE_PREVIEW_SNIPPET")

    get "/admin/transactional_email_logs", params: { template_key: "welcome" }

    expect(response.body).to include("Подтвердите e-mail")
    expect(response.body).not_to include("Ваш заказ доставлен")

    get "/admin/transactional_email_logs", params: { q: "anna@example.com" }

    expect(response.body).to include("Ваш заказ доставлен")
    expect(response.body).not_to include("Подтвердите e-mail")
  end

  it "shows the sent html in a preview tab" do
    get "/admin/transactional_email_logs/#{delivered.id}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Превью")
    expect(response.body).to include("Как ушло клиенту")
    expect(response.body).to include("email-log-preview__frame")
    expect(response.body).not_to include("Краткое содержание")
  end
end
