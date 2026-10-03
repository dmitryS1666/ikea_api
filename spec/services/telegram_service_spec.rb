require 'rails_helper'

RSpec.describe TelegramService do
  describe '.send_message' do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('TELEGRAM_BOT_TOKEN').and_return('test_token')
      allow(ENV).to receive(:[]).with('TELEGRAM_CHAT_ID').and_return('123456')
      allow(ENV).to receive(:[]).with('TELEGRAM_ORDERS_BOT_TOKEN').and_return('orders_token')
      allow(ENV).to receive(:[]).with('TELEGRAM_ORDERS_CHAT_ID').and_return('654321')
    end

    it 'sends message via HTTP to the system bot by default' do
      allow(Net::HTTP).to receive(:post_form).and_return(double(is_a?: true, body: '{"ok":true}'))

      TelegramService.send_message('Test message')

      expect(Net::HTTP).to have_received(:post_form).with(
        URI('https://api.telegram.org/bottest_token/sendMessage'),
        hash_including(chat_id: '123456', text: 'Test message')
      )
    end

    it 'sends order messages via the orders bot' do
      allow(Net::HTTP).to receive(:post_form).and_return(double(is_a?: true, body: '{"ok":true}'))

      TelegramService.send_order_message('New order')

      expect(Net::HTTP).to have_received(:post_form).with(
        URI('https://api.telegram.org/botorders_token/sendMessage'),
        hash_including(chat_id: '654321', text: 'New order')
      )
    end

    it 'does not send if bot_token is missing' do
      allow(ENV).to receive(:[]).with('TELEGRAM_BOT_TOKEN').and_return(nil)

      expect(Net::HTTP).not_to receive(:post_form)
      TelegramService.send_message('Test message')
    end

    it 'does not send if chat_id is missing' do
      allow(ENV).to receive(:[]).with('TELEGRAM_CHAT_ID').and_return(nil)

      expect(Net::HTTP).not_to receive(:post_form)
      TelegramService.send_message('Test message')
    end

    it 'does not send order messages when orders credentials are missing' do
      allow(ENV).to receive(:[]).with('TELEGRAM_ORDERS_BOT_TOKEN').and_return(nil)

      expect(Net::HTTP).not_to receive(:post_form)
      TelegramService.send_order_message('New order')
    end

    it 'handles errors gracefully' do
      allow(Net::HTTP).to receive(:post_form).and_raise(StandardError.new('Network error'))
      allow(Rails.logger).to receive(:error)

      TelegramService.send_message('Test message')

      expect(Rails.logger).to have_received(:error).with(/Telegram error/)
    end
  end

  describe '.send_parser_started' do
    it 'sends formatted message' do
      allow(TelegramService).to receive(:send_message)

      TelegramService.send_parser_started('categories', limit: 100)

      expect(TelegramService).to have_received(:send_message).once
    end
  end

  describe '.send_parser_completed' do
    it 'sends formatted message with stats' do
      allow(TelegramService).to receive(:send_message)

      stats = { processed: 100, created: 50, updated: 30, errors: 5, duration: 3600 }
      TelegramService.send_parser_completed('products', stats)

      expect(TelegramService).to have_received(:send_message).once
    end
  end

  describe '.send_parser_error' do
    it 'sends formatted error message' do
      allow(TelegramService).to receive(:send_message)

      error = StandardError.new('Test error')
      TelegramService.send_parser_error('categories', error)

      expect(TelegramService).to have_received(:send_message).once
    end
  end

  describe '.send_product_video_stats' do
    it 'sends storage estimate' do
      allow(TelegramService).to receive(:send_message)

      TelegramService.send_product_video_stats(
        "products_checked" => 10,
        "unique_total_human" => "1.50 GB",
        "product_total_human" => "2.00 GB",
        "min_bytes" => 1024,
        "avg_bytes" => 2048,
        "max_bytes" => 4096
      )

      expect(TelegramService).to have_received(:send_message).with(
        a_string_including("1.50 GB")
      )
    end
  end

  describe '.send_product_document_stats' do
    it 'sends document storage estimate' do
      allow(TelegramService).to receive(:send_message)

      TelegramService.send_product_document_stats(
        "products_checked" => 10,
        "unique_total_human" => "800.00 MB",
        "product_total_human" => "1.20 GB",
        "min_bytes" => 1024,
        "avg_bytes" => 2048,
        "max_bytes" => 4096
      )

      expect(TelegramService).to have_received(:send_message).with(
        a_string_including("800.00 MB")
      )
    end
  end
end
