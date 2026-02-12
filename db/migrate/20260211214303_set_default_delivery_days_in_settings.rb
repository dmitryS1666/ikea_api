class SetDefaultDeliveryDaysInSettings < ActiveRecord::Migration[7.1]
  def up
    # Используем метод set из модели CalculatorSetting, если она доступна
    # Или создаем запись напрямую через SQL для надежности миграции
    execute <<-SQL
      INSERT INTO calculator_settings (key, value, setting_type, description, created_at, updated_at)
      VALUES ('default_delivery_days', '30', 'integer', 'Срок доставки по умолчанию (дней)', NOW(), NOW())
      ON CONFLICT (key) DO UPDATE 
      SET value = '30', updated_at = NOW()
      WHERE calculator_settings.key = 'default_delivery_days';
    SQL
  end

  def down
    # Мы не удаляем настройку при откате, так как она может быть важна для работы системы,
    # но если нужно, можно раскомментировать:
    # execute "DELETE FROM calculator_settings WHERE key = 'default_delivery_days';"
  end
end
