# frozen_string_literal: true

# Виртуальная модель для раздела выгрузки таможенного реестра.
class CustomsRegistryExport
  include ActiveModel::Model

  attr_accessor :id

  def self.find(id)
    new(id: id)
  end

  def persisted?
    true
  end

  def to_param
    id.to_s
  end

  def self.all
    [new(id: "show")]
  end
end
