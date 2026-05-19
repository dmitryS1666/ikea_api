Trestle.resource(:return_requests, model: ReturnRequest) do
  menu do
    item :return_requests, icon: "fa fa-undo", group: :sales, label: "Возвраты"
  end

  table do
    column :id, link: true
    column :user do |r|
      link_to r.user.full_name, Trestle.lookup(:users).path(:show, id: r.user_id) if r.user
    end
    column :order do |r|
      link_to "Заказ ##{r.order_id}", Trestle.lookup(:orders).path(:show, id: r.order_id) if r.order
    end
    column :order_number, header: "№ заказа"
    column :phone
    column :reason
    column :compensation_type, header: "Компенсация"
    column :status do |r|
      status_tag(r.status, :info)
    end
    column :created_at, align: :center
    actions
  end

  form do |r|
    static_field :user, label: "Пользователь" do
      link_to r.user.full_name, Trestle.lookup(:users).path(:show, id: r.user_id) if r.user
    end
    static_field :order, label: "Заказ" do
      link_to "Заказ ##{r.order_id}", Trestle.lookup(:orders).path(:show, id: r.order_id) if r.order
    end
    text_field :first_name, label: "Имя"
    text_field :patronymic, label: "Отчество"
    text_field :order_number, label: "Номер заказа"
    text_field :phone, label: "Телефон"
    text_field :email, label: "Email"
    text_area :reason, label: "Причина возврата"
    select :compensation_type, ReturnRequest::COMPENSATION_TYPES.map { |s| [s, s] }, label: "Компенсация"
    text_area :comment, label: "Комментарий администратора"
    select :status, ReturnRequest::STATUSES.map { |s| [s, s] }, label: "Статус"
  end
end
