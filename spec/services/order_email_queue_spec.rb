# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrderEmailQueue do
  include ActiveJob::TestHelper

  let(:user) { create(:user, email: "customer@example.com") }
  let(:order) { create(:order, user: user, checkout_draft: false) }

  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
  end

  it "starts with order_created and keeps awaiting_payment queued" do
    described_class.enqueue!(order, %w[order_created order_awaiting_payment])

    expect(order.reload.pending_order_email_keys).to eq(%w[order_awaiting_payment])
    expect(order.email_dispatch_locked_at).to be_present
    expect(enqueued_jobs.count { |job| job[:job] == PrepareOrderEmailJob }).to eq(1)

    prepare_args = enqueued_jobs.find { |job| job[:job] == PrepareOrderEmailJob }[:args].first
    expect(prepare_args["template_key"] || prepare_args[:template_key]).to eq("order_created")
    expect(prepare_args["continue_order_queue"] || prepare_args[:continue_order_queue]).to eq(true)
  end

  it "waits about 20 seconds after order_created before awaiting_payment" do
    described_class.enqueue!(order, %w[order_created order_awaiting_payment])
    clear_enqueued_jobs

    described_class.complete_and_continue!(order.id, previous_template_key: "order_created")

    expect(order.reload.pending_order_email_keys).to eq([])
    next_job = enqueued_jobs.find { |job| job[:job] == PrepareOrderEmailJob }
    expect(next_job).to be_present
    expect(next_job[:args].first["template_key"] || next_job[:args].first[:template_key])
      .to eq("order_awaiting_payment")
    expect(next_job[:at]).to be_within(1.second).of(20.seconds.from_now.to_f)
  end

  it "appends status emails behind the checkout chain without starting a parallel job" do
    described_class.enqueue!(order, %w[order_created order_awaiting_payment])
    clear_enqueued_jobs

    described_class.enqueue!(order.reload, %w[order_placed])

    expect(order.reload.pending_order_email_keys).to eq(%w[order_awaiting_payment order_placed])
    expect(enqueued_jobs.count { |job| job[:job] == PrepareOrderEmailJob }).to eq(0)
  end

  it "sends queued status email only after the checkout chain finishes" do
    described_class.enqueue!(order, %w[order_created order_awaiting_payment])
    described_class.enqueue!(order.reload, %w[order_placed])
    clear_enqueued_jobs

    described_class.complete_and_continue!(order.id, previous_template_key: "order_created")
    clear_enqueued_jobs
    described_class.complete_and_continue!(order.id, previous_template_key: "order_awaiting_payment")

    next_job = enqueued_jobs.find { |job| job[:job] == PrepareOrderEmailJob }
    expect(next_job[:args].first["template_key"] || next_job[:args].first[:template_key])
      .to eq("order_placed")
    expect(next_job[:at]).to be_within(1.second).of(Time.current.to_f)
  end
end
