Trestle.resource :phone_auth_setting, model: PhoneAuthSetting, singleton: true do
  menu do
    item :phone_auth_setting, icon: "fa fa-phone", label: "Авторизация по телефону", group: "Клиенты", priority: 5
  end

  controller do
    def update
      setting = admin.find_instance(params)

      if setting.update(phone_auth_setting_params)
        flash[:message] = "Настройки сохранены"
        redirect_to admin.instance_path(setting)
      else
        flash.now[:error] = "Ошибка: #{setting.errors.full_messages.join(', ')}"
        render :edit
      end
    end

    private

    def phone_auth_setting_params
      params.require(:phone_auth_setting).permit(:asterisk_enabled)
    end
  end

  form do |_setting|
    row do
      col(sm: 12) do
        check_box :asterisk_enabled, label: "Использовать ASTERISK для звонков"
      end
    end

    row do
      col(sm: 12) do
        content_tag :p do
          "Если опция выключена, звонок в ASTERISK не выполняется, а код подтверждения всегда статичный: #{PhoneAuthSetting::STATIC_TEST_CODE}. Для боевого режима должны быть заданы ENV ASTERISK_CALL_AUTH_TOKEN и, при необходимости, ASTERISK_CALL_AUTH_URL / ASTERISK_CALL_AUTH_FROM_NUMBERS."
        end
      end
    end
  end
end
