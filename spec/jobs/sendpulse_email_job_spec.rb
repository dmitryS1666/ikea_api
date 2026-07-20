require "rails_helper"

RSpec.describe SendpulseEmailJob, type: :job do
  include ActiveJob::TestHelper

  let(:user) { create(:user, email: "customer@example.com") }
  let(:order) { create(:order, user: user, checkout_draft: false) }

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

  it "advances the per-order queue only after a successful send" do
    sender = instance_double(Sendpulse::EmailSender)
    allow(Sendpulse::EmailSender).to receive(:new).and_return(sender)
    allow(sender).to receive(:call).and_return(Sendpulse::Result.new(success: true, response: { "ok" => true }))

    order.update!(
      pending_order_email_keys: %w[order_awaiting_payment],
      email_dispatch_locked_at: Time.current
    )

    expect do
      described_class.perform_now(
        to_email: "user@example.com",
        subject: "Test",
        html: "<p>Test</p>",
        continue_order_queue: true,
        order_id: order.id,
        template_key: "order_created"
      )
    end.to have_enqueued_job(PrepareOrderEmailJob).with(
      hash_including(
        template_key: "order_awaiting_payment",
        order_id: order.id,
        continue_order_queue: true
      )
    )

    next_job = enqueued_jobs.find { |job| job[:job] == PrepareOrderEmailJob }
    expect(next_job[:at]).to be_within(1.second).of(20.seconds.from_now.to_f)
  end

  it "does not advance the queue when send fails" do
    sender = instance_double(Sendpulse::EmailSender)
    allow(Sendpulse::EmailSender).to receive(:new).and_return(sender)
    allow(sender).to receive(:call).and_return(Sendpulse::Result.new(success: false, error: "fail"))
    allow(Rails.logger).to receive(:error)

    order.update!(
      pending_order_email_keys: %w[order_awaiting_payment],
      email_dispatch_locked_at: Time.current
    )

    expect do
      described_class.perform_now(
        to_email: "user@example.com",
        subject: "Test",
        html: "<p>Test</p>",
        continue_order_queue: true,
        order_id: order.id,
        template_key: "order_created"
      )
    end.to have_enqueued_job(described_class)

    expect(enqueued_jobs.count { |job| job[:job] == PrepareOrderEmailJob }).to eq(0)
    expect(order.reload.pending_order_email_keys).to eq(%w[order_awaiting_payment])
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
