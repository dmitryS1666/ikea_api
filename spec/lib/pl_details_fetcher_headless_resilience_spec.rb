# frozen_string_literal: true

require "rails_helper"

RSpec.describe PlDetailsFetcher do
  describe "headless resilience" do
    let(:fetcher) { described_class.new(scope_sku: "59502293") }

    after do
      described_class.reset_reused_headless_browser!
    end

    it "recognizes proxy block pages" do
      expect(fetcher.send(:headless_blocked_page?, "<title>403 Forbidden</title>")).to eq(true)
      expect(fetcher.send(:headless_blocked_page?, "<title>Just a moment...</title>")).to eq(true)
      expect(fetcher.send(:headless_blocked_page?, "<html>produkt IKEA</html>")).to eq(false)
    end

    it "closes Chrome when a headless request fails" do
      headers = double("Ferrum headers", set: nil)
      browser = double(
        "Ferrum browser",
        headers: headers,
        process: nil,
        quit: nil,
        contexts: []
      )

      allow(described_class).to receive(:resolved_chromium_path_for_headless).and_return("/usr/bin/chromium")
      allow(ProxyRotator).to receive(:get_proxy).and_return(nil)
      allow(Ferrum::Browser).to receive(:new).and_return(browser)
      allow(fetcher).to receive(:headless_timeout_seconds).and_return(120)
      allow(browser).to receive(:go_to).and_raise(
        PlDetailsFetcher::HeadlessTimeoutError,
        "headless timed out"
      )

      expect { fetcher.send(:fetch_modal_with_headless_browser, "https://www.ikea.com/pl/pl/p/-59502293/") }
        .to raise_error(PlDetailsFetcher::HeadlessTimeoutError, "headless timed out")
      expect(browser).to have_received(:quit)
    end

    it "keeps Chrome open after success and reuses it for the next call" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("PL_FETCHER_REUSE_BROWSER", "1").and_return("1")

      browser = double("Ferrum browser", quit: nil, contexts: [], process: nil)

      fetcher.send(
        :finalize_headless_browser_session!,
        browser,
        nil,
        "proxy|1|user",
        had_error: nil
      )
      expect(browser).not_to have_received(:quit)

      session = fetcher.send(:take_any_reused_headless_session!)
      expect(session[:browser]).to eq(browser)
      expect(session[:proxy_key]).to eq("proxy|1|user")

      # Second finalize without error keeps the same session
      fetcher.send(
        :finalize_headless_browser_session!,
        browser,
        nil,
        "proxy|1|user",
        had_error: nil
      )
      expect(browser).not_to have_received(:quit)
      expect(fetcher.send(:take_any_reused_headless_session!)[:browser]).to eq(browser)
    end

    it "allows enough time for Chrome to start" do
      headers = double("Ferrum headers", set: nil)
      browser = double(
        "Ferrum browser",
        headers: headers,
        process: nil,
        quit: nil,
        contexts: []
      )

      allow(described_class).to receive(:resolved_chromium_path_for_headless).and_return("/usr/bin/chromium")
      allow(ProxyRotator).to receive(:get_proxy).and_return(nil)
      allow(Ferrum::Browser).to receive(:new).and_return(browser)
      allow(fetcher).to receive(:headless_timeout_seconds).and_return(120)
      allow(browser).to receive(:go_to).and_raise(
        PlDetailsFetcher::HeadlessTimeoutError,
        "headless timed out"
      )

      expect { fetcher.send(:fetch_modal_with_headless_browser, "https://www.ikea.com/pl/pl/p/-59502293/") }
        .to raise_error(PlDetailsFetcher::HeadlessTimeoutError)
      expect(Ferrum::Browser).to have_received(:new).with(
        browser_options: kind_of(Hash),
        headless: false,
        timeout: 60,
        process_timeout: 60,
        browser_path: "/usr/bin/chromium"
      )
    end

    it "honors a custom Chrome startup timeout" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("FERRUM_PROCESS_TIMEOUT", "60").and_return("90")

      expect(fetcher.send(:headless_process_timeout_seconds)).to eq(90)
    end

    it "falls back to 60 seconds for an invalid Chrome startup timeout" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("FERRUM_PROCESS_TIMEOUT", "60").and_return("0")

      expect(fetcher.send(:headless_process_timeout_seconds)).to eq(60)
    end
  end
end
