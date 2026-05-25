# Человекочитаемые названия доп. услуг заказа (коды из checkout → services).
class OrderServicesFormatter
  I18N_SCOPE = "activerecord.attributes.order.services"

  class << self
    def label(code)
      return if code.blank?

      I18n.t("#{I18N_SCOPE}.#{code}", default: code.to_s)
    end

    def labels(codes)
      Array(codes).filter_map { |code| label(code) }
    end

    def labels_joined(codes, separator: ", ")
      labels(codes).join(separator)
    end
  end
end
