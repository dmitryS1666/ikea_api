require "rails_helper"

RSpec.describe SendpulseEmailJob, type: :job do
  include ActiveJob::TestHelper

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end

  it "calls Sendpulse::EmailSender" do
    sender = instance_double(Sendpulse::EmailSender)
    allow(Sendpulse::EmailSender).to receive(:new).and_return(sender)
    allow(sender).to receive(:call).and_return(Sendpulse::Result.new(success: true, response: { "ok" => true }))

    described_class.perform_now(
      to_email: "user@example.com",
      subject: "Test",
      html: "<p>Test</p>"
    )

    expect(sender).to have_received(:call).with(
      to_email: "user@example.com",
      subject: "Test",
      html: "<p>Test</p>",
      raise_on_error: true
    )
  end

  it "retries when the service returns a failed result" do
    sender = instance_double(Sendpulse::EmailSender)
    allow(Sendpulse::EmailSender).to receive(:new).and_return(sender)
    allow(sender).to receive(:call).and_return(Sendpulse::Result.new(success: false, error: "fail"))
    allow(Rails.logger).to receive(:error)

    expect do
      described_class.perform_now(to_email: "user@example.com", subject: "Test", html: "<p>Test</p>")
    end.to have_enqueued_job(described_class)

    expect(Rails.logger).to have_received(:error).with(/SendPulse.*failed result/)
  end

  it "retries unexpected exceptions instead of marking the email successful" do
    sender = instance_double(Sendpulse::EmailSender)
    allow(Sendpulse::EmailSender).to receive(:new).and_return(sender)
    allow(sender).to receive(:call).and_raise(StandardError.new("unexpected"))
    allow(Rails.logger).to receive(:error)

    expect do
      described_class.perform_now(to_email: "user@example.com", subject: "Test", html: "<p>Test</p>")
    end.to have_enqueued_job(described_class)

    expect(Rails.logger).to have_received(:error).with(/SendPulse.*unexpected/)
  end
end
