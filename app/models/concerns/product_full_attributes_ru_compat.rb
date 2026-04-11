# frozen_string_literal: true

# Виртуальное поле full_attributes_ru (колонка снята): чтение через AR идёт в _read_attribute / сгенерированный геттер.
# Подключается в config/initializers/product_full_attributes_ru_compat.rb (to_prepare), чтобы prepend шёл
# после полной инициализации Active Record и переживал reload в development.
module ProductFullAttributesRuCompat
  def full_attributes_ru
    compute_virtual_full_attributes_ru
  end

  def read_attribute(attr_name, &block)
    return compute_virtual_full_attributes_ru if attr_name.to_s == "full_attributes_ru"

    super(attr_name, &block)
  end

  def _read_attribute(attr_name, &block)
    return compute_virtual_full_attributes_ru if attr_name.to_s == "full_attributes_ru"

    super(attr_name, &block)
  end

  private

  def compute_virtual_full_attributes_ru
    ProductSerializer.customer_full_attributes_payload(self)
  rescue ActiveModel::MissingAttributeError
    {}
  end
end
