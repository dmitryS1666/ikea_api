require 'rails_helper'

RSpec.describe SeoHelper, type: :helper do
  let(:product) { create(:product, name_ru: "Шкаф", collection: "SONGESAND") }
  let(:category) { create(:category, translated_name: "Стулья") }
  
  before do
    GlobalSeoSetting.create!(
      target_type: 'product',
      title_template: "{{name}} купить {{city}} | {{store_name}}",
      description_template: "Купить {{name}} {{city}} по выгодной цене в {{store_name}}."
    )
    GlobalSeoSetting.create!(
      target_type: 'category',
      title_template: "{{name}} купить {{city}}, выгодные цены | {{store_name}}",
      description_template: "Большой выбор {{name}} {{city}} в {{store_name}}."
    )
  end

  describe ".meta_for" do
    context "for product" do
      it "generates title with city" do
        meta = SeoHelper.meta_for(product, 'minsk')
        expect(meta[:title]).to eq("Шкаф купить в Минске | Интернет-магазин IKEYA")
      end

      it "generates description with city" do
        meta = SeoHelper.meta_for(product, 'brest')
        expect(meta[:description]).to eq("Купить Шкаф в Бресте по выгодной цене в Интернет-магазин IKEYA.")
      end

      it "uses manual SEO title if present" do
        create(:seo_metum, seoable: product, title: "Ручной заголовок")
        meta = SeoHelper.meta_for(product.reload, 'minsk')
        expect(meta[:title]).to eq("Ручной заголовок")
      end

      it "sanitizes output from HTML and extra spaces" do
        product.update(name_ru: "  Шкаф  \n  белый  ")
        meta = SeoHelper.meta_for(product, 'minsk')
        expect(meta[:title]).to eq("Шкаф белый купить в Минске | Интернет-магазин IKEYA")
      end
    end

    context "for category" do
      it "generates title with city" do
        meta = SeoHelper.meta_for(category, 'grodno')
        expect(meta[:title]).to eq("Стулья купить в Гродно, выгодные цены | Интернет-магазин IKEYA")
      end
    end

    context "with unknown city" do
      it "falls back to default city (Minsk)" do
        meta = SeoHelper.meta_for(product, 'unknown_city')
        expect(meta[:title]).to include("в Минске")
      end
    end
  end
end
