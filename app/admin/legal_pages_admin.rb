Trestle.resource(:legal_pages, model: LegalPage) do
  menu do
    item :legal_pages, icon: "fa fa-gavel", group: :content, priority: 8, label: "Правовая информация"
  end

  scopes do
    scope :all, default: true
    scope :draft, -> { LegalPage.draft }
    scope :published, -> { LegalPage.published }
    scope :disabled, -> { LegalPage.disabled }
  end

  collection do
    LegalPage.order(:id)
  end

  table do
    column :title, link: true
    column :slug
    column :status do |page|
      LegalPage.human_attribute_name("statuses.#{page.status}")
    end
    column :updated_at, align: :center
    actions
  end

  form do |page|
    tab :content, label: "Содержимое" do
      row do
        col(sm: 12) { text_field :title, required: true, label: "Заголовок" }
      end
      row do
        col(sm: 12) { text_field :slug, label: "Slug", hint: "Латинский идентификатор для URL; если пусто — из заголовка" }
      end
      row do
        col(sm: 12) { tinymce :body, label: "Текст страницы" }
      end
    end

    sidebar do
      form_group :meta, label: "Метаданные" do
        select :status,
               LegalPage.statuses.keys.map { |key| [LegalPage.human_attribute_name("statuses.#{key}"), key] },
               label: "Статус"
        static_field :created_at, label: "Создано"
        static_field :updated_at, label: "Изменено"
      end
    end
  end

  params do |params|
    params.require(:legal_page).permit(:title, :slug, :body, :status)
  end
end
