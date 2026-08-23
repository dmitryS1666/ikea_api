# frozen_string_literal: true

require "rails_helper"

RSpec.describe CollectProductVideoStatsJob, type: :job do
  let(:size_fetcher) { class_double(Products::RemoteContentLength) }
  let(:html_fetcher) { class_double(Products::PipHtmlFetcher) }

  before do
    allow(TelegramService).to receive(:send_parser_started)
    allow(TelegramService).to receive(:send_parser_completed)
    allow(TelegramService).to receive(:send_parser_error)
    allow(TelegramService).to receive(:send_product_video_stats)
    allow(Products::RemoteContentLength).to receive(:fetch) do |url|
      size_fetcher.fetch(url)
    end
    allow(Products::PipHtmlFetcher).to receive(:fetch) do |url|
      html_fetcher.fetch(url)
    end
  end

  describe "#perform" do
    it "aggregates unique file sizes and skips live fetch when mp4 is already stored" do
      shared = "https://www.ikea.com/pvid/shared.mp4"
      create(:product, sku: "11111111", videos: [shared], url: "https://www.ikea.com/pl/pl/p/a-11111111/")
      create(:product, sku: "22222222", videos: [shared, "https://www.youtube.com/embed/x"], url: "https://www.ikea.com/pl/pl/p/b-22222222/")
      create(:product, sku: "33333333", videos: [], url: "https://www.ikea.com/pl/pl/p/c-33333333/")

      allow(size_fetcher).to receive(:fetch).with(shared).and_return(2_000_000)
      allow(html_fetcher).to receive(:fetch).with("https://www.ikea.com/pl/pl/p/c-33333333/").and_return("")

      described_class.perform_now(live: true)

      task = ParserTask.last
      expect(task.task_type).to eq("collect_product_video_stats")
      expect(task.status).to eq("completed")
      expect(task.payload["unique_sized_videos"]).to eq(1)
      expect(task.payload["unique_total_bytes"]).to eq(2_000_000)
      expect(task.payload["product_total_bytes"]).to eq(4_000_000)
      expect(task.payload["products_with_videos"]).to eq(2)
      expect(task.payload["unique_embeds"]).to eq(1)
      expect(html_fetcher).not_to have_received(:fetch).with("https://www.ikea.com/pl/pl/p/a-11111111/")
      expect(TelegramService).to have_received(:send_product_video_stats)
    end

    it "reads video urls from IKEA html when live is enabled and db has none" do
      create(
        :product,
        sku: "44444444",
        videos: [],
        url: "https://www.ikea.com/pl/pl/p/d-44444444/"
      )
      allow(html_fetcher).to receive(:fetch).and_return('<video src="https://www.ikea.com/pvid/live.mp4"></video>')
      allow(size_fetcher).to receive(:fetch).with("https://www.ikea.com/pvid/live.mp4").and_return(512)

      described_class.perform_now(live: true)

      expect(ParserTask.last.payload["unique_total_bytes"]).to eq(512)
      expect(ParserTask.last.payload["live_fetched"]).to eq(1)
    end

    it "does not hit IKEA pages when live is false" do
      create(:product, sku: "55555555", videos: [], url: "https://www.ikea.com/pl/pl/p/e-55555555/")
      allow(html_fetcher).to receive(:fetch)

      described_class.perform_now(live: false)

      expect(html_fetcher).not_to have_received(:fetch)
      expect(ParserTask.last.payload["live"]).to eq(false)
      expect(ParserTask.last.payload["products_with_videos"]).to eq(0)
    end
  end

  describe "Collector.human_bytes" do
    it "formats binary units" do
      expect(described_class::Collector.human_bytes(0)).to eq("0 B")
      expect(described_class::Collector.human_bytes(1536)).to eq("1.50 KB")
      expect(described_class::Collector.human_bytes(1_073_741_824)).to eq("1.00 GB")
    end
  end
end
