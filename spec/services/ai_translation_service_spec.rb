# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AiTranslationService do
  let(:text) { 'Stół dębowy z litego drewna' }
  let(:translated_text) { 'Дубовый стол из цельного дерева' }
  let(:target_lang) { 'ru' }
  let(:source_lang) { 'pl' }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('OPENAI_API_KEY').and_return('sk-test-openai')
    allow(ENV).to receive(:[]).with('DEEPSEEK_API_KEY').and_return('sk-test-deepseek')
    allow(ENV).to receive(:fetch).with('OPENAI_MODEL', 'gpt-4o-mini').and_return('gpt-5')
  end

  describe '.translate' do
    context 'when using OpenAI' do
      it 'calls OpenAI API and returns translated text' do
        stub_request(:post, AiTranslationService::OPENAI_URL)
          .with do |request|
            body = JSON.parse(request.body)
            body['model'] == 'gpt-5' &&
              body['messages'].any? { |m| m['role'] == 'user' && m['content'] == text }
          end
          .to_return(
            status: 200,
            body: {
              choices: [
                { message: { content: translated_text } }
              ]
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        result = AiTranslationService.translate(text, provider: :openai)
        expect(result).to eq(translated_text)
      end
    end

    context 'when using DeepSeek' do
      it 'calls DeepSeek API and returns translated text' do
        stub_request(:post, AiTranslationService::DEEPSEEK_URL)
          .with do |request|
            body = JSON.parse(request.body)
            body['model'] == 'deepseek-chat' &&
              body['messages'].any? { |m| m['role'] == 'user' && m['content'] == text }
          end
          .to_return(
            status: 200,
            body: {
              choices: [
                { message: { content: translated_text } }
              ]
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        result = AiTranslationService.translate(text, provider: :deepseek)
        expect(result).to eq(translated_text)
      end
    end

    context 'when API returns error' do
      it 'logs error and returns nil' do
        stub_request(:post, AiTranslationService::OPENAI_URL)
          .to_return(status: 500, body: 'Internal Server Error')

        expect(Rails.logger).to receive(:error).with(/AI Translation Error \(openai\): 500/)
        
        result = AiTranslationService.translate(text)
        expect(result).to be_nil
      end
    end

    context 'when text is blank' do
      it 'returns empty string' do
        expect(AiTranslationService.translate('')).to eq('')
        expect(AiTranslationService.translate(nil)).to eq('')
      end
    end
  end
end
