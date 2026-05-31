Trestle.resource(:return_requests, model: ReturnRequest) do
  menu do
    item :return_requests, icon: "fa fa-undo", group: :sales, label: "Возвраты"
  end

  collection do
    ReturnRequest
      .includes(:user, :order, attachments_attachments: :blob)
      .order(id: :desc)
  end

  table do
    column :id, header: "ID", link: true, sort: true

    column :user, header: "Пользователь" do |rr|
      rr.user&.full_name || "—"
    end

    column :order, header: "Заказ", sort: :order_id do |rr|
      rr.order ? "Заказ ##{rr.order_id}" : "—"
    end

    column :order_number, header: "№ заказа", sort: true do |rr|
      rr.order_number.presence || "—"
    end

    column :phone, header: "Телефон" do |rr|
      rr.phone.presence || "—"
    end

    column :reason, header: "Причина" do |rr|
      reason_label(rr.reason)
    end

    column :compensation_type, header: "Компенсация" do |rr|
      compensation_label(rr.compensation_type)
    end

    column :attachments, header: "Фото", align: :center do |rr|
      rr.attachments.attached? ? rr.attachments.count : "—"
    end

    column :status, header: "Статус" do |rr|
      status_label(rr.status)
    end

    column :created_at, header: "Дата", sort: true do |rr|
      rr.created_at&.strftime("%d.%m.%Y %H:%M")
    end

    actions
  end

  form do |rr|
    tab :basic, label: "Заявка" do
      row do
        col(sm: 4) do
          static_field :id, label: "ID заявки"
        end

        col(sm: 4) do
          static_field :user, label: "Пользователь" do
            rr.user&.full_name || "—"
          end
        end

        col(sm: 4) do
          static_field :order, label: "Заказ" do
            rr.order ? "Заказ ##{rr.order_id}" : "—"
          end
        end
      end

      divider

      row do
        col(sm: 4) { text_field :first_name, label: "Имя" }
        col(sm: 4) { text_field :patronymic, label: "Отчество" }
        col(sm: 4) { text_field :order_number, label: "Номер заказа" }
      end

      row do
        col(sm: 6) { text_field :phone, label: "Телефон" }
        col(sm: 6) { text_field :email, label: "Email" }
      end

      divider

      row do
        col(sm: 6) do
          select :reason,
            [
              ["Повреждён при доставке", "damaged"],
              ["Привезли не тот товар", "wrong"],
              ["Проблемы с качеством", "quality"],
              ["Не соответствует описанию", "description"],
              ["Другое", "other"]
            ],
            label: "Причина возврата"
        end

        col(sm: 6) do
          select :compensation_type,
            [
              ["Возврат денег", "refund"],
              ["Обмен товара", "exchange"]
            ],
            label: "Компенсация"
        end
      end

      text_area :comment, label: "Комментарий клиента", rows: 5

      divider

      static_field :attachments, label: "Вложения" do
        if rr.attachments.attached?
          safe_join(
            rr.attachments.map.with_index(1) do |attachment, index|
              blob = attachment.blob
              attachment_path = Rails.application.routes.url_helpers.rails_blob_path(
                attachment,
                only_path: true
              )
      
              content_tag(
                :div,
                class: "return-request-attachment",
                style: "display:inline-block; vertical-align:top; margin:0 12px 12px 0; padding:10px; border:1px solid #ddd; border-radius:6px; max-width:180px;"
              ) do
                preview =
                  if blob.content_type.to_s.start_with?("image/")
                    link_to attachment_path, target: "_blank", rel: "noopener" do
                      image_tag(
                        attachment_path,
                        style: "display:block; width:160px; max-height:160px; object-fit:cover; border-radius:4px; margin-bottom:8px;"
                      )
                    end
                  else
                    content_tag(
                      :div,
                      "Файл",
                      style: "width:160px; height:80px; display:flex; align-items:center; justify-content:center; background:#f5f5f5; border-radius:4px; margin-bottom:8px;"
                    )
                  end
      
                title = content_tag(
                  :div,
                  "Файл #{index}",
                  style: "font-weight:600; margin-bottom:4px;"
                )
      
                meta = content_tag(
                  :div,
                  [
                    blob.filename.to_s,
                    blob.content_type,
                    "#{(blob.byte_size.to_f / 1024 / 1024).round(2)} МБ"
                  ].compact.join("<br>").html_safe,
                  style: "font-size:12px; color:#666; word-break:break-word; margin-bottom:8px;"
                )
      
                open_link = link_to(
                  "Открыть",
                  attachment_path,
                  target: "_blank",
                  rel: "noopener",
                  class: "btn btn-default btn-xs"
                )
      
                preview + title + meta + open_link
              end
            end
          )
        else
          "Файлы не загружены"
        end
      end
    end

    sidebar do
      form_group :status, label: "Статус" do
        select :status,
          [
            ["Новая", "new"],
            ["В работе", "in_review"],
            ["Одобрена", "approved"],
            ["Отклонена", "rejected"],
            ["Завершена", "completed"]
          ],
          label: false
      end

      form_group :meta, label: "Данные" do
        static_field :created_at, label: "Создано" do
          rr.created_at&.strftime("%d.%m.%Y %H:%M")
        end

        static_field :updated_at, label: "Обновлено" do
          rr.updated_at&.strftime("%d.%m.%Y %H:%M")
        end

        static_field :attachments_count, label: "Фото" do
          rr.attachments.attached? ? rr.attachments.count : 0
        end
      end
    end
  end

  helper do
    def reason_label(value)
      {
        "damaged" => "Повреждён при доставке",
        "wrong" => "Привезли не тот товар",
        "quality" => "Проблемы с качеством",
        "description" => "Не соответствует описанию",
        "other" => "Другое"
      }[value] || value.presence || "—"
    end

    def compensation_label(value)
      {
        "refund" => "Возврат денег",
        "exchange" => "Обмен товара"
      }[value] || value.presence || "—"
    end

    def status_label(value)
      {
        "new" => "Новая",
        "in_review" => "В работе",
        "approved" => "Одобрена",
        "rejected" => "Отклонена",
        "completed" => "Завершена"
      }[value] || value.presence || "—"
    end
  end
end
