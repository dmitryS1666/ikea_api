# frozen_string_literal: true

# Ensures ordered/unordered list markers inherit bold when the whole list item is bold.
# Browsers render markers via ::marker on <li>, which does not inherit from nested <strong>.
class ContentArticleHtmlNormalizer
  BOLD_TAGS = %w[strong b].freeze

  def self.normalize(html)
    new(html).normalize
  end

  def initialize(html)
    @html = html.to_s
  end

  def normalize
    return @html if @html.blank?

    fragment = Nokogiri::HTML.fragment(@html)
    fragment.css("ol > li, ul > li").each do |li|
      next unless list_item_fully_bold?(li)

      li["style"] = merge_font_weight(li["style"])
    end
    fragment.to_html
  end

  private

  def list_item_fully_bold?(li)
    return false unless li.children.any? { |child| child.element? && child.name.in?(BOLD_TAGS) }

    li.children.each do |child|
      case child
      when Nokogiri::XML::Text
        return false if child.text.strip.present?
      when Nokogiri::XML::Element
        return false unless child.name.in?(BOLD_TAGS + %w[br])
      end
    end

    true
  end

  def merge_font_weight(existing_style)
    style = existing_style.to_s.strip
    return "font-weight:700" if style.blank?

    without_weight = style.gsub(/font-weight\s*:\s*[^;]+;?/i, "").strip.chomp(";").strip
    [without_weight, "font-weight:700"].reject(&:blank?).join(";")
  end
end
