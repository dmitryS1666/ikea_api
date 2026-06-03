module SeoHelper
  def self.meta_for(record, city_code = nil)
    personal = record.seo_meta
    target_type = case record
                  when Product then 'product'
                  when Category then 'category'
                  when ContentArticle then 'article'
                  else nil
                  end

    @global_settings ||= GlobalSeoSetting.all.index_by(&:target_type)
    global = @global_settings[target_type]
    city_in = Seo::CityMapper.call(city_code)

    {
      title: render_template(personal&.title.presence || build_global_title(global, record, city_in), record, city_in),
      description: render_template(personal&.description.presence || build_global_description(global, record, city_in), record, city_in),
      keywords: render_template(personal&.keywords.presence || global&.keywords_template, record, city_in),
      robots: personal&.robots.presence || global&.robots,
      seo_text: personal&.seo_text.presence || global&.seo_text,
      h1: render_template(personal&.h1.presence || global&.h1_template, record, city_in)
    }
  end

  def self.render_template_string(template_string, record, city_code = nil)
    city_in = Seo::CityMapper.call(city_code)
    render_template(template_string, record, city_in)
  end

  private

  def self.render_template(template_string, record, city_in)
    return nil if template_string.blank?

    template = template_string.to_s
    replacements = template_replacements(record, template, city_in)

    rendered = replacements.reduce(template) do |text, (token, value)|
      key = Regexp.escape(token.to_s.delete_prefix("{{").delete_suffix("}}"))
      text.gsub(/{{\s*#{key}\s*}}/, value.to_s)
    end

    sanitize_meta(normalize_city_preposition(rendered))
  end

  def self.template_replacements(record, template, city_in)
    base_name = record_base_name(record)
    small_desc_name = record_small_desc_name(record)
    full_name = record_full_name(record)

    # Если в шаблоне явно указан {{small_desc_name}} или {{full_name}},
    # {{name}} оставляем базовым названием, чтобы не получить дубль вида
    # "PAX Гардероб, комбинация Гардероб, комбинация".
    # Для старых шаблонов только с {{name}} подставляем полное товарное имя.
    name = if record.is_a?(Product) && template.match?(/{{\s*(small_desc_name|full_name)\s*}}/)
             base_name
           else
             full_name
           end

    {
      '{{name}}' => name,
      '{{base_name}}' => base_name,
      '{{product_name}}' => base_name,
      '{{small_desc_name}}' => small_desc_name,
      '{{full_name}}' => full_name,
      '{{city}}' => city_in,
      '{{store_name}}' => "Интернет-магазин IKEYA"
    }
  end

  def self.record_base_name(record)
    if record.is_a?(Product)
      record.name_ru.presence || record.name
    elsif record.is_a?(Category)
      record.translated_name.presence || record.name
    else
      record.respond_to?(:translated_name) ? record.translated_name : (record.respond_to?(:title) ? record.title : record.name)
    end
  end

  def self.record_small_desc_name(record)
    return "" unless record.respond_to?(:small_desc_name)

    record.small_desc_name.to_s.strip
  end

  def self.record_full_name(record)
    base_name = record_base_name(record).to_s.strip
    small_desc_name = record_small_desc_name(record)
    return base_name if small_desc_name.blank?
    return base_name if base_name.downcase.include?(small_desc_name.downcase)

    [base_name, small_desc_name].reject(&:blank?).join(" ")
  end

  # Шаблоны вида «купить в {{city}}», где {{city}} уже «в Минске» → «в в Минске».
  def self.normalize_city_preposition(text)
    text.gsub(/\bв\s+в\s+/i, "в ")
  end

  def self.sanitize_meta(text)
    return nil if text.blank?
    ActionController::Base.helpers.strip_tags(text).squish
  end

  def self.build_global_title(global, record, city_in)
    global&.title_template
  end

  def self.build_global_description(global, record, city_in)
    global&.description_template
  end
end
