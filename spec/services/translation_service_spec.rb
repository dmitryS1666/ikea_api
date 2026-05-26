# frozen_string_literal: true

require "rails_helper"

RSpec.describe TranslationService do
  describe ".needs_polish_to_russian_translation?" do
    it "detects Polish diacritics in short small_desc_name" do
      expect(described_class.needs_polish_to_russian_translation?("beżowy/pomarańczowy")).to be(true)
    end

    it "returns false for Russian text" do
      expect(described_class.needs_polish_to_russian_translation?("светло-зеленый, 26x13x7 см")).to be(false)
    end

    it "returns false for IKEA latin names" do
      expect(described_class.needs_polish_to_russian_translation?("BESTÅ")).to be(false)
    end

    it "detects Polish materials without diacritics" do
      expect(described_class.needs_polish_to_russian_translation?("Rama: Stal")).to be(true)
      expect(described_class.needs_polish_to_russian_translation?("Odkurzać miękką szczotką")).to be(true)
    end

    it "detects Polish care blob with Russian Состав/Уход labels" do
      blob = <<~TEXT.strip
        Состав: 100% poliester (min. 90% z recyklingu)
        Уход: Prać ręcznie w temperaturze maks. 40°C.
        Nie wybielać.
        Nie suszyć w suszarce bębnowej.
        Nie prasować.
        Nie prać chemicznie.
      TEXT

      expect(described_class.needs_polish_to_russian_translation?(blob)).to be(true)
      expect(described_class.predominantly_russian?(blob)).to be(true)
    end
  end

  describe ".translate" do
    it "does not call Google Translate" do
      polish = "Szafka z 5 półkami, beżowy/pomarańczowy"
      expect(GoogleTranslateService).not_to receive(:translate)
      expect(AiTranslationService).to receive(:translate).with(polish, target_lang: "ru", source_lang: "pl")
        .and_return("Шкаф с 5 полками, бежевый/оранжевый")

      result = described_class.translate(polish, context: "spec")
      expect(result).to include("Шкаф")
    end

    it "returns original text when already Russian" do
      russian = "светло-зеленый, 26x13x7 см"
      expect(AiTranslationService).not_to receive(:translate)

      expect(described_class.translate(russian)).to eq(russian)
    end
  end
end
