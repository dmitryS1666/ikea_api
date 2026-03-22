Trestle.resource(:account, model: User, scope: Auth, singular: true) do
  instance do
    current_user
  end

  remove_action :new, :edit, :destroy

  form do |user|
    text_field :username, label: "Логин"
    text_field :email, label: "Электронная почта"

    row do
      col(sm: 6) { text_field :first_name, label: "Имя" }
      col(sm: 6) { text_field :last_name, label: "Фамилия" }
    end

    row do
      col(sm: 6) { password_field :password, label: "Пароль" }
      col(sm: 6) { password_field :password_confirmation, label: "Подтверждение пароля" }
    end

    sidebar do
      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата регистрации"
        static_field :updated_at, label: "Дата последнего обновления"
      end
    end
  end

  # Limit the parameters that are permitted to be updated by the user
  params do |params|
    params.require(:account).permit(:username, :email, :first_name, :last_name, :password, :password_confirmation)
  end
end
