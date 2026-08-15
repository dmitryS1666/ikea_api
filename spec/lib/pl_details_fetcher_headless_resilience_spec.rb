# frozen_string_literal: true

require "rails_helper"

RSpec.describe PlDetailsFetcher do
  describe "headless resilience" do
    let(:fetcher) { described_class.new(scope_sku: "59502293") }

    after do
      described_class.reset_reused_headless_browser!
      described_class.reset_headless_circuit!
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
        process_timeout: 120,
        browser_path: "/usr/bin/chromium"
      )
    end

    it "honors a custom Chrome startup timeout" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("FERRUM_PROCESS_TIMEOUT", "120").and_return("90")

      expect(fetcher.send(:headless_process_timeout_seconds)).to eq(90)
    end

    it "falls back to 120 seconds for an invalid Chrome startup timeout" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("FERRUM_PROCESS_TIMEOUT", "120").and_return("0")

      expect(fetcher.send(:headless_process_timeout_seconds)).to eq(120)
    end

    it "does not auto-detect snap Chromium launchers" do
      allow(File).to receive(:executable?).and_call_original
      allow(File).to receive(:executable?).with("/snap/bin/chromium").and_return(true)

      expect(described_class.snap_chromium_launcher?("/snap/bin/chromium")).to eq(true)
      expect(described_class.usable_chromium_executable?("/snap/bin/chromium")).to eq(false)

      allow(File).to receive(:file?).with("/usr/bin/chromium-browser").and_return(true)
      allow(File).to receive(:size).with("/usr/bin/chromium-browser").and_return(2408)
      expect(described_class.snap_chromium_launcher?("/usr/bin/chromium-browser")).to eq(true)
    end

    it "ignores snap CHROME_PATH unless explicitly allowed" do
      original_chrome = ENV["CHROME_PATH"]
      original_browser = ENV["BROWSER_PATH"]
      original_allow = ENV["PL_FETCHER_ALLOW_SNAP_CHROME"]
      begin
        ENV["CHROME_PATH"] = "/usr/bin/chromium-browser"
        ENV.delete("BROWSER_PATH")
        ENV.delete("PL_FETCHER_ALLOW_SNAP_CHROME")

        allow(File).to receive(:executable?).and_call_original
        allow(File).to receive(:executable?).with("/usr/bin/chromium-browser").and_return(true)
        allow(File).to receive(:file?).with("/usr/bin/chromium-browser").and_return(true)
        allow(File).to receive(:size).with("/usr/bin/chromium-browser").and_return(2408)
        described_class::BROWSER_PATH_CANDIDATES.each do |path|
          allow(File).to receive(:executable?).with(path).and_return(false)
        end

        expect(described_class.resolved_chromium_path_for_headless).to eq(nil)
        expect(described_class.headless_browser_executable_available?).to eq(false)

        ENV["PL_FETCHER_ALLOW_SNAP_CHROME"] = "1"
        expect(described_class.resolved_chromium_path_for_headless).to eq("/usr/bin/chromium-browser")
      ensure
        original_chrome.nil? ? ENV.delete("CHROME_PATH") : ENV["CHROME_PATH"] = original_chrome
        original_browser.nil? ? ENV.delete("BROWSER_PATH") : ENV["BROWSER_PATH"] = original_browser
        original_allow.nil? ? ENV.delete("PL_FETCHER_ALLOW_SNAP_CHROME") : ENV["PL_FETCHER_ALLOW_SNAP_CHROME"] = original_allow
      end
    end

    it "opens the headless circuit after consecutive timeouts" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("PL_FETCHER_HEADLESS_CIRCUIT_THRESHOLD", "3").and_return("2")

      described_class.record_headless_failure!
      expect(described_class.headless_circuit_open?).to eq(false)
      described_class.record_headless_failure!
      expect(described_class.headless_circuit_open?).to eq(true)

      expect(fetcher.send(:fetch_modal_with_headless_browser, "https://www.ikea.com/pl/pl/p/-59502293/"))
        .to eq({})
    end
  end
end
