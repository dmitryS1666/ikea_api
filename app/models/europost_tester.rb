# frozen_string_literal: true

# Виртуальная модель для админского тестера API Европочты.
class EuropostTester
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
