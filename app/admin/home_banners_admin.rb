Trestle.resource(:home_banners, model: HomeBanner) do
  menu do
    item :home_banners, icon: "fa fa-images", group: :content, label: "Баннеры на главной",
                        if: -> { current_user&.allowed_for_admin_resource?(:home_banners, :index) }
  end

  scopes do
    scope :all, default: true, label: "Все"
    scope :main, -> { HomeBanner.main }, label: "Главный слайдер"
    scope :horizontal, -> { HomeBanner.horizontal }, label: "Горизонтальный баннер"
    scope :advertising, -> { HomeBanner.advertising }, label: "Рекламные баннеры"
    scope :active, -> { HomeBanner.active }, label: "Активные"
  end

  table do
    column :id, label: "ID"
    column :image, label: "Изображение", align: :center do |banner|
      if banner.image.attached?
        image_tag(Rails.application.routes.url_helpers.rails_blob_path(banner.image, only_path: true), style: "max-width: 100px; max-height: 50px;")
      else
        "—"
      end
    end
    column :section do |banner|
      case banner.section
      when 'main'
        status_tag('Главный слайдер', :info)
      when 'horizontal'
        status_tag('Горизонтальный', :success)
      when 'advertising'
        status_tag('Рекламный', :warning)
      else
        banner.section
      end
    end
    column :slot_key, label: "Slot key"
    column :breakpoint do |banner|
      case banner.breakpoint
      when 'desktop' then 'Desktop'
      when 'tablet' then 'Tablet'
      when 'mobile' then 'Mobile'
      when 'all' then 'All'
      else banner.breakpoint
      end
    end
    column :variant do |banner|
      dims = banner.expected_dimensions
      dims ? "#{dims[0]}×#{dims[1]}" : banner.variant
    end
    column :description, link: true
    column :category do |banner|
      banner.category&.name || '—'
    end
    column :custom_url
    column :position, sortable: true
    column :active do |banner|
      status_tag(banner.active? ? 'Да' : 'Нет',
                 banner.active? ? :success : :danger)
    end
    column :created_at, align: :center
    actions do |actions|
      actions.show
      actions.edit
      actions.delete if current_user&.allowed_for_admin_resource?(:home_banners, :destroy)
    end
  end

  form do |banner|
    section_variants = {
      'main' => {
        '1500×516 (desktop)' => 'main_1500x516',
        '960×516 (планшет)' => 'main_960x516',
        '572×594 (mobile)' => 'main_572x594'
      },
      'horizontal' => {
        '1500×256 (desktop)' => 'horizontal_1500x256',
        '960×256 (планшет)' => 'horizontal_960x256',
        '742×256 (mobile)' => 'horizontal_742x256'
      },
      'advertising' => {
        '742×256 (desktop, 2 в ряд)' => 'advertising_742x256',
        '960×256 (планшет)' => 'advertising_960x256',
        '960×256 (mobile)' => 'advertising_mobile_960x256'
      }
    }

    sidebar do
      check_box :active, label: "Активен"
      number_field :position, label: "Позиция слота"
      text_field :slot_key, label: "Slot key", placeholder: "main-beds-1"
      content_tag :small, "Одинаковый slot_key объединяет desktop/tablet/mobile одного визуального слайда (включая рекламные).", class: "text-muted"
    end

    row do
      col(sm: 6) do
        row do
          col(sm: 6) do
            select :section, {
              'Главный слайдер' => 'main',
              'Горизонтальный баннер' => 'horizontal',
              'Рекламные баннеры' => 'advertising'
            }, label: "Секция", html: { id: "home_banner_section", data: { variants: section_variants.to_json } }
          end
          col(sm: 6) do
            current_section = banner.section.presence || 'main'
            variant_options = section_variants[current_section] || section_variants['main']

            select :variant, variant_options, { include_blank: false }, label: "Вариант размера", html: { id: "home_banner_variant", data: { selected: banner.variant } }
          end
        end
        row do
          col(sm: 6) do
            categories = Category.active.order(:name).map do |cat|
              name = cat.translated_name.presence || cat.name
              level_indicator = cat.is_important || (cat.parent_ids.blank? || (cat.parent_ids.is_a?(Array) && cat.parent_ids.empty?)) ? "★ " : "  "
              ["#{level_indicator}#{name}", cat.ikea_id]
            end
            select :category_id, categories, { include_blank: 'Выберите категорию...' }, label: "Категория"
          end
          col(sm: 6) do
            text_field :custom_url, label: "Кастомная ссылка (приоритетнее категории)", placeholder: "/catalog/beds или https://..."
          end
        end
        row do
          col(sm: 12) do
            text_area :description, label: "Описание", rows: 5, placeholder: "Технические заметки для админа"
          end
        end
      end

      col(sm: 6) do
        concat(content_tag(:script, type: "text/javascript") do
          raw <<-JS.strip_heredoc
            (function() {
              var sectionVariants = #{section_variants.to_json.html_safe};
              var sectionSelect = document.getElementById("home_banner_section");
              var variantSelect = document.getElementById("home_banner_variant");
              if (!sectionSelect || !variantSelect) { return; }

              function rebuildOptions() {
                var selectedSection = sectionSelect.value || Object.keys(sectionVariants)[0];
                var options = sectionVariants[selectedSection] || {};
                var prevValue = variantSelect.value || variantSelect.dataset.selected;
                variantSelect.innerHTML = "";

                Object.keys(options).forEach(function(label) {
                  var value = options[label];
                  var option = document.createElement("option");
                  option.value = value;
                  option.textContent = label;

                  if (value === prevValue) {
                    option.selected = true;
                  }

                  variantSelect.appendChild(option);
                });

                if (!variantSelect.value && variantSelect.options.length) {
                  variantSelect.selectedIndex = 0;
                }
              }

              sectionSelect.addEventListener("change", function() {
                rebuildOptions();
              });

              function init() {
                rebuildOptions();
              }

              document.addEventListener("turbo:load", init);
              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", init);
              } else {
                init();
              }
            })();
          JS
        end)

        row do
          col(sm: 12) do
            concat(content_tag(:div, id: "image-preview-container", style: "margin-bottom: 15px;") do
              content = +""
              if banner.persisted? && banner.image.attached?
                content << content_tag(:div, class: "current-image-preview", style: "margin-bottom: 15px; padding: 10px; background: #f8f9fa; border-radius: 4px;") do
                  image_tag(Rails.application.routes.url_helpers.rails_blob_path(banner.image, only_path: true),
                           style: "max-width: 400px; max-height: 300px; display: block; margin: 0 auto; border: 1px solid #ddd; border-radius: 4px;",
                           id: "current-image-preview") +
                  content_tag(:p, "Текущее изображение", style: "text-align: center; margin-top: 10px; color: #666; font-size: 12px;")
                end
              end
              content << content_tag(:div, id: "new-image-preview", style: "display: none; margin-bottom: 15px; padding: 10px; background: #e8f5e9; border-radius: 4px;") do
                content_tag(:img, "", id: "image-preview", style: "max-width: 400px; max-height: 300px; display: block; margin: 0 auto; border: 1px solid #4caf50; border-radius: 4px;") +
                content_tag(:p, "Предпросмотр нового изображения", style: "text-align: center; margin-top: 10px; color: #2e7d32; font-size: 12px; font-weight: bold;")
              end
              content.html_safe
            end)

            file_field :image, label: "Изображение"
            content_tag :small, "Разрешены: WebP, AVIF, PNG, JPEG. При сохранении автоматически конвертируется в WebP и сжимается до ~200KB. Размер в пикселях должен соответствовать выбранному варианту.", class: "text-muted"

            if banner.variant.present?
              expected = banner.expected_dimensions
              if expected
                content_tag :div, class: "alert alert-info", style: "margin-top: 10px;" do
                  "Требуемый размер: #{expected[0]}×#{expected[1]} пикселей"
                end
              end
            end

            concat(content_tag(:script, type: "text/javascript") do
              raw <<-JS.strip_heredoc
                (function() {
                  function initImagePreview() {
                    var fileInput = document.querySelector('input[type="file"][name*="[image]"]');
                    if (!fileInput) return;

                    var preview = document.getElementById('image-preview');
                    var container = document.getElementById('new-image-preview');
                    var currentPreview = document.querySelector('.current-image-preview');

                    fileInput.addEventListener('change', function(e) {
                      if (e.target.files && e.target.files[0]) {
                        var reader = new FileReader();

                        reader.onload = function(event) {
                          if (preview) preview.src = event.target.result;
                          if (container) container.style.display = 'block';
                          if (currentPreview) currentPreview.style.display = 'none';
                        };

                        reader.readAsDataURL(e.target.files[0]);
                      } else {
                        if (container) container.style.display = 'none';
                        if (currentPreview) currentPreview.style.display = 'block';
                      }
                    });
                  }

                  document.addEventListener('turbo:load', initImagePreview);
                  if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', initImagePreview);
                  } else {
                    initImagePreview();
                  }
                })();
              JS
            end)
          end
        end
      end
    end
  end

  controller do
    def create
      @instance = HomeBanner.new(home_banner_params)
      if @instance.save
        adjust_positions_on_create
        redirect_to admin.instance_path(@instance), notice: "Баннер успешно создан"
      else
        flash.now[:error] = @instance.errors.full_messages.to_sentence
        render :new
      end
    end

    def update
      @instance = admin.find_instance(params)
      old_position = @instance.position
      old_section = @instance.section
      old_slot_key = @instance.slot_key

      if @instance.update(home_banner_params)
        if old_position != @instance.position || old_section != @instance.section || old_slot_key != @instance.slot_key
          adjust_positions_on_update(@instance, old_position, old_section, old_slot_key)
        end
        redirect_to admin.instance_path(@instance), notice: "Баннер успешно обновлен"
      else
        flash.now[:error] = @instance.errors.full_messages.to_sentence
        render :edit
      end
    end

    def show
      @banner = admin.find_instance(params)
      render "trestle/home_banners/show"
    end

    private

    def home_banner_params
      normalize_home_banner_params(
        params.require(:home_banner).permit(
          :section, :variant, :slot_key, :description, :category_id, :custom_url, :position, :active, :image
        )
      )
    end

    def normalize_home_banner_params(permitted)
      permitted[:category_id] = nil if permitted[:category_id].blank?
      permitted[:slot_key] = permitted[:slot_key].to_s.strip.presence if permitted.key?(:slot_key)
      if permitted.key?(:active)
        permitted[:active] = case permitted[:active]
        when "1", "true", true
          true
        when "0", "false", false, nil
          false
        else
          permitted[:active]
        end
      end
      permitted
    end

    # Shift other visual slots only when creating a brand-new slot.
    # Adding tablet/mobile for an existing slot_key must not bump neighbors.
    def adjust_positions_on_create
      existing_slot = HomeBanner.where(section: @instance.section, slot_key: @instance.slot_key)
                                .where.not(id: @instance.id)
                                .exists?

      unless existing_slot
        other_slots = HomeBanner.where(section: @instance.section)
                                .where.not(id: @instance.id)
                                .where.not(slot_key: @instance.slot_key)
                                .where('position >= ?', @instance.position)

        other_slots.update_all('position = position + 1')
      end

      HomeBanner.where(section: @instance.section, slot_key: @instance.slot_key)
                .update_all(position: @instance.position)
    end

    def adjust_positions_on_update(banner, old_position, old_section, old_slot_key)
      new_position = banner.position

      if old_section != banner.section || old_slot_key != banner.slot_key
        HomeBanner.where(section: old_section)
                  .where.not(slot_key: old_slot_key)
                  .where('position > ?', old_position)
                  .update_all('position = position - 1')

        HomeBanner.where(section: banner.section)
                  .where.not(id: banner.id)
                  .where.not(slot_key: banner.slot_key)
                  .where('position >= ?', new_position)
                  .update_all('position = position + 1')
      elsif new_position > old_position
        HomeBanner.where(section: banner.section)
                  .where.not(slot_key: banner.slot_key)
                  .where('position > ? AND position <= ?', old_position, new_position)
                  .update_all('position = position - 1')
      elsif new_position < old_position
        HomeBanner.where(section: banner.section)
                  .where.not(slot_key: banner.slot_key)
                  .where('position >= ? AND position < ?', new_position, old_position)
                  .update_all('position = position + 1')
      end

      HomeBanner.where(section: banner.section, slot_key: banner.slot_key)
                .update_all(position: new_position)
    end
  end

  params do |params|
    permitted = params.require(:home_banner).permit(
      :section, :variant, :slot_key, :description, :category_id, :custom_url, :position, :active, :image
    )
    permitted[:category_id] = nil if permitted[:category_id].blank?
    permitted[:slot_key] = permitted[:slot_key].to_s.strip.presence if permitted.key?(:slot_key)
    if permitted.key?(:active)
      permitted[:active] = case permitted[:active]
      when "1", "true", true
        true
      when "0", "false", false, nil
        false
      else
        permitted[:active]
      end
    end
    permitted
  end
end
