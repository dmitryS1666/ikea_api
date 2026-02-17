module SeoHelper
  def self.meta_for(record)
    personal = record.seo_meta
    target_type = case record
                  when Product then 'product'
                  when Category then 'category'
                  when ContentArticle then 'article'
                  else nil
                  end

    global = GlobalSeoSetting.find_by(target_type: target_type) if target_type

    {
      title: personal&.title.presence || build_global_title(global, record),
      description: personal&.description.presence || build_global_description(global, record),
      keywords: personal&.keywords.presence || global&.keywords_template,
      robots: personal&.robots.presence || global&.robots,
      seo_text: personal&.seo_text.presence || global&.seo_text
    }
  end

  private

  def self.build_global_title(global, record)
    return nil unless global&.title_template.present?
    name = record.respond_to?(:translated_name) ? record.translated_name : record.title
    global.title_template.gsub('{{name}}', name.to_s)
  end

  def self.build_global_description(global, record)
    return nil unless global&.description_template.present?
    name = record.respond_to?(:translated_name) ? record.translated_name : record.title
    global.description_template.gsub('{{name}}', name.to_s)
  end
end
