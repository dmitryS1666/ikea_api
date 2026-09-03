# frozen_string_literal: true

Trestle.resource :webpay_setting, model: WebpaySetting, singleton: true do
  menu do
    item :webpay_setting, icon: "fa fa-credit-card", label: "WebPay шлюз", group: :finance,
                          priority: 2,
                          if: -> { current_user&.allowed_for_admin_resource?(:webpay_setting, :index) }
  end

  controller do
    def update
      setting = admin.find_instance(params)

      if setting.update(webpay_setting_params)
        mode_label = setting.test_mode? ? "тестовый (sandbox)" : "боевой (production)"
        flash[:message] = "Режим WebPay сохранён: #{mode_label}"
        redirect_to admin.instance_path(setting)
      else
        flash.now[:error] = "Ошибка: #{setting.errors.full_messages.join(', ')}"
        render :edit
      end
    end

    private

    def webpay_setting_params
      params.require(:webpay_setting).permit(:test_mode)
    end
  end

  form do |setting|
    row do
      col(sm: 12) do
        check_box :test_mode, label: "Тестовый шлюз (sandbox)"
      end
    end

    row do
      col(sm: 12) do
        current_mode = setting.test_mode? ? "тестовый" : "боевой"
        content_tag :p do
          "Сейчас выбран #{current_mode} режим. " \
            "Включённый чекбокс отправляет оплату на https://securesandbox.webpay.by " \
            "(wsb_test=1, учётные данные WEBPAY_TEST_* или sandbox по умолчанию). " \
            "Выключенный — на https://payment.webpay.by " \
            "(wsb_test=0, WEBPAY_LIVE_* или WEBPAY_STORE_ID / WEBPAY_SECRET_KEY). " \
            "Не переключайте режим, пока есть незавершённые ссылки на оплату: " \
            "подпись и notify привязаны к секрету выбранного шлюза."
        end
      end
    end
  end
end
