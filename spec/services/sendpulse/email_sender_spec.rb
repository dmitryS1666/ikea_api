require "rails_helper"

RSpec.describe Sendpulse::EmailSender do
  let(:client) { instance_double(Sendpulse::Client) }
  let(:service) { described_class.new(client: client) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with("SENDPULSE_FROM_EMAIL").and_return("no-reply@example.com")
    allow(ENV).to receive(:fetch).with("SENDPULSE_FROM_NAME", "IKEA").and_return("IKEA")
  end

  it "forms payload for HTML email and encodes html in Base64" do
    html = "<p>Hello</p>"
    expected_encoded = Base64.strict_encode64(html)
    allow(client).to receive(:post).and_return({ "result" => true })

    service.call(to_email: "user@example.com", subject: "Hello", html: html, text: "Hello")

    expect(client).to have_received(:post).with(
      "/smtp/emails",
      hash_including(
        email: hash_including(
          subject: "Hello",
          html: expected_encoded,
          text: "Hello",
          from: { name: "IKEA", email: "no-reply@example.com" }
        )
      )
    )
  end

  it "forms payload for template_id with variables" do
    allow(client).to receive(:post).and_return({ "result" => true })

    service.call(
      to_email: "user@example.com",
      subject: "Template email",
      html: "<p>ignored</p>",
      template_id: "tpl-123",
      variables: { order_id: 10 }
    )

    expect(client).to have_received(:post).with(
      "/smtp/emails",
      hash_including(
        email: hash_including(
          template: { id: "tpl-123", variables: { order_id: 10 } }
        )
      )
    )
  end

  it "does not send without to_email" do
    allow(client).to receive(:post)

    result = service.call(to_email: nil, subject: "x", html: "<p>x</p>")

    expect(result.success?).to be(false)
    expect(client).not_to have_received(:post)
  end

  it "handles client error and returns failed result" do
    error = Sendpulse::Error.new(message: "boom", status: 500, response_body: { "error" => "boom" }, endpoint: "/smtp/emails")
    allow(client).to receive(:post).and_raise(error)

    result = service.call(to_email: "user@example.com", subject: "x", html: "<p>x</p>")

    expect(result.success?).to be(false)
    expect(result.error).to eq(error)
  end
end
