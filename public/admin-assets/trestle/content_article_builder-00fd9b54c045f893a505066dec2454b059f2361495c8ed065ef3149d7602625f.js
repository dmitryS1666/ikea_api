(function() {
  const BUILDER_SELECTOR = "[data-content-article-block-builder]";
  const builderInstances = new WeakMap();

  function initBuilders() {
    document.querySelectorAll(BUILDER_SELECTOR).forEach(container => {
      const existing = builderInstances.get(container);
      if (existing && typeof existing.destroy === "function") {
        existing.destroy();
      }
      builderInstances.set(container, new ContentArticleBlockBuilder(container));
    });
  }

  // Trestle-specific approach: use their internal init if available
  if (typeof Trestle !== "undefined" && Trestle.ready) {
    Trestle.ready(initBuilders);
  }

  document.addEventListener("turbo:before-cache", () => {
    if (window.tinymce) {
      tinymce.remove();
    }
  });

  document.addEventListener("DOMContentLoaded", initBuilders);
  document.addEventListener("turbolinks:load", initBuilders);
  document.addEventListener("turbo:load", initBuilders);
  // Also hook into Trestle's internal navigation if needed
  document.addEventListener("trestle:init", initBuilders);

  document.addEventListener("direct-upload:success", event => {
    const input = event.target;
    const container = input.closest(BUILDER_SELECTOR);
    if (!container) return;
    const builder = builderInstances.get(container);
    if (builder) {
      builder.handleDirectUploadSuccess(input, event.detail);
    }
  });

  class ContentArticleBlockBuilder {
    constructor(container) {
      this.container = container;
      this.blockList = container.querySelector(".builder-block-list");
      this.templateSelect = container.querySelector(".builder-template-select");
      this.addButton = container.querySelector(".builder-add-block");
      const form = container.closest("form");
      this.hiddenField = form ? form.querySelector(".content-article-body-blocks-json") : null;
      this.directUploadUrl = container.dataset.directUploadUrl;
      this.templates = this.safeParse(container.dataset.blockTemplates);
      this.categories = this.safeParse(container.dataset.buttonCategories);
      this.blocks = this.safeParse(container.dataset.initialBlocks);

      this.productsByCategoryUrl = container.dataset.productsByCategoryUrl;
      this.productsSearchUrl = container.dataset.productsSearchUrl;
      this.productsCache = new Map();

      if (this.addButton) {
        this.addButton.addEventListener("click", () => {
          const templateValue = this.templateSelect ? this.templateSelect.value : null;
          this.addBlock(templateValue);
        });
      }

      this.renderBlocks();
      this.attachSubmitSync();
    }

    safeParse(value) {
      if (!value) {
        return [];
      }
      try {
        return JSON.parse(value);
      } catch (_error) {
        return [];
      }
    }

    addBlock(templateId) {
      if (!templateId && this.templates.length > 0) {
        templateId = this.templates[0].id;
      }
      const template = this.templates.find(t => t.id === templateId);
      if (!template) return;

      const block = this.createBlockFromTemplate(template.id);
      this.blocks.push(block);
      this.renderBlocks();
    }

    createBlockFromTemplate(templateId, existing = {}) {
      const template = this.templates.find(t => t.id === templateId) || this.templates[0];
      if (!template) return null;

      return {
        type: template.id,
        content: existing.content || "",
        button_text: existing.button_text || "",
        button_category_id: existing.button_category_id || null,
        slider_enabled: template.slider_enabled,
        button_enabled: template.button_enabled,
        products_grid_enabled: template.products_grid_enabled,
        categories_grid_enabled: template.categories_grid_enabled,
        slider_category_id: existing.slider_category_id || null,
        slider_product_skus: Array.isArray(existing.slider_product_skus) ? existing.slider_product_skus : [],
        grid_category_ids: Array.isArray(existing.grid_category_ids) ? existing.grid_category_ids : [],
        selected_products: Array.isArray(existing.selected_products) ? existing.selected_products : [],
        images: template.image_slots.map(slot => {
          const matched = (existing.images || []).find(image => image.slot === slot.name);
          return {
            slot: slot.name,
            label: slot.label,
            signed_id: matched ? matched.signed_id : null,
            url: matched ? matched.url : null,
            filename: matched ? matched.filename : null
          };
        })
      };
    }

    renderBlocks() {
      if (!this.blockList) return;
      
      // 1. Тщательно удаляем старые экземпляры TinyMCE перед очисткой DOM
      if (window.tinymce) {
        this.blockList.querySelectorAll('.content-article-block-content').forEach(el => {
          tinymce.remove(`#${el.id}`);
        });
      }

      this.blockList.innerHTML = "";
      this.blocks.forEach((block, index) => {
        const blockEl = this.buildBlockElement(block, index);
        this.blockList.appendChild(blockEl);
      });
      this.syncHiddenField();

      // 2. Используем небольшую задержку, чтобы DOM успел обновиться
      setTimeout(() => {
        this.initTinyMCE();
      }, 100);
    }

    initTinyMCE() {
      if (!window.tinymce) {
        // If TinyMCE is not loaded yet, wait a bit and try again, up to 10 seconds
        if (!this._tinymce_retries) this._tinymce_retries = 0;
        this._tinymce_retries++;
        
        if (this._tinymce_retries < 50) { // 50 * 200ms = 10s
          setTimeout(() => this.initTinyMCE(), 200);
        }
        return;
      }
      this._tinymce_retries = 0;

      const self = this;
      this.blockList.querySelectorAll('.content-article-block-content').forEach(el => {
        // Пропускаем, если уже инициализирован
        if (tinymce.get(el.id)) return;

        const isTinyMce6 = parseInt(tinymce.majorVersion || "0", 10) >= 6;
        tinymce.init({
          target: el,
          menubar: false,
          branding: false,
          height: 300,
          plugins: 'lists link code autolink',
          toolbar: isTinyMce6
            ? 'undo redo | blocks fontsize | bold italic underline | bullist numlist | link code'
            : 'undo redo | formatselect fontsizeselect | bold italic underline | bullist numlist | link code',
          block_formats: 'Текст=p; Заголовок 2=h2; Заголовок 3=h3; Заголовок 4=h4;',
          font_size_formats: '8pt 9pt 10pt 11pt 12pt 14pt 16pt 18pt 20pt 22pt 24pt 28pt 32pt 36pt',
          fontsize_formats: '8pt 9pt 10pt 11pt 12pt 14pt 16pt 18pt 20pt 22pt 24pt 28pt 32pt 36pt',
          content_style: 'body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; font-size: 14px; } h2 { font-size: 1.5rem; font-weight: bold; } h3 { font-size: 1.25rem; font-weight: bold; } h4 { font-size: 1.1rem; font-weight: bold; }',
          setup: function(editor) {
            const syncEditorContent = function() {
              const index = editor.getElement().dataset.blockIndex;
              const content = editor.getContent();
              self.updateBlockContent(parseInt(index), content);
            };
            editor.on('change keyup input undo redo SetContent ExecCommand NodeChange', syncEditorContent);
            editor.on('init', function() {
              editor.setContent(el.value);
              syncEditorContent();
            });
          }
        });
      });
    }

    buildBlockElement(block, index) {
      const blockWrapper = document.createElement("div");
      blockWrapper.className = "content-article-block-card";
      blockWrapper.dataset.blockIndex = index;

      const header = this.buildBlockHeader(block, index);
      blockWrapper.appendChild(header);

      const contentField = this.buildContentField(block, index);
      blockWrapper.appendChild(contentField);

      if (block.button_enabled) {
        const buttonSettings = this.buildButtonSettings(block, index);
        blockWrapper.appendChild(buttonSettings);
      }

      const imageFields = this.buildImageFields(block, index);
      blockWrapper.appendChild(imageFields);

      if (block.slider_enabled) {
        const sliderSettings = this.buildSliderSettings(block, index);
        blockWrapper.appendChild(sliderSettings);
      } else if (block.products_grid_enabled) {
        const gridSettings = this.buildSliderSettings(block, index, { title: "Настройки сетки товаров", hint: "Выберите категорию и товары для сетки." });
        blockWrapper.appendChild(gridSettings);
      } else if (block.categories_grid_enabled) {
        const categoriesSettings = this.buildCategoriesGridSettings(block, index);
        blockWrapper.appendChild(categoriesSettings);
      } else {
        const tmpl = this.templates.find(t => t.id === block.type);
        if (!tmpl || !tmpl.omit_slider_placeholder) {
          const sliderNote = document.createElement("p");
          sliderNote.className = "block-slider-note";
          sliderNote.textContent = "Этот блок не отображает слайдер или сетку товаров/категорий.";
          blockWrapper.appendChild(sliderNote);
        }
      }

      return blockWrapper;
    }

    async fetchProductsByCategory(categoryId) {
      if (!categoryId || !this.productsByCategoryUrl) return [];
      if (this.productsCache.has(categoryId)) return this.productsCache.get(categoryId);
    
      const url = new URL(this.productsByCategoryUrl, window.location.origin);
      url.searchParams.set("category_id", categoryId);
    
      const resp = await fetch(url.toString(), { headers: { "Accept": "application/json" } });
      if (!resp.ok) return [];
    
      const data = await resp.json();
    
      // поддержка двух форматов:
      // 1) массив [{sku,name}]
      // 2) объект {results:[{id,text,sku,name}]}
      let rawItems = [];
      if (Array.isArray(data)) {
        rawItems = data;
      } else if (data && Array.isArray(data.results)) {
        rawItems = data.results;
      }
    
      // нормализуем к виду {sku,name}
      const products = rawItems
        .map(item => {
          const sku = item.sku || item.id || item.value;
          let name = item.name || item.text || item.label;
    
          // если text = "Name (SKU)" — можно убрать хвост, чтобы фильтр по имени работал чище
          if (name && typeof name === "string") {
            name = name.replace(/\s*\(\s*[\w-]+\s*\)\s*$/, "");
          }
    
          return sku ? {
            sku: String(sku),
            name: String(name || sku),
            small_desc_name: item.small_desc_name ? String(item.small_desc_name) : ""
          } : null;
        })
        .filter(Boolean);
    
      this.productsCache.set(categoryId, products);
      return products;
    }

    async searchProductsGlobal(query) {
      if (!query || query.length < 3 || !this.productsSearchUrl) return [];

      const url = new URL(this.productsSearchUrl, window.location.origin);
      url.searchParams.set("q", query);

      const resp = await fetch(url.toString(), { headers: { "Accept": "application/json" } });
      if (!resp.ok) return [];

      const data = await resp.json();
      const results = Array.isArray(data) ? data : (data.results || []);

      return results.map(item => ({
        sku: String(item.sku || item.id),
        name: String(item.name || item.text || item.sku),
        small_desc_name: item.small_desc_name ? String(item.small_desc_name) : ""
      }));
    }
    
    buildSliderSettings(block, index, options = {}) {
      const container = document.createElement("div");
      container.className = "block-slider-settings";
      container.style.marginTop = "12px";
      container.style.padding = "12px";
      container.style.border = "1px solid #e5e5e5";
      container.style.borderRadius = "6px";
      container.style.background = "#fafafa";
    
      const title = document.createElement("strong");
      title.textContent = options.title || "Настройки слайдера товаров";
      container.appendChild(title);
    
      // --- CATEGORY SELECT ---
      const categoryWrap = document.createElement("div");
      categoryWrap.className = "block-field";
      categoryWrap.style.marginTop = "10px";
    
      const categoryLabel = document.createElement("label");
      categoryLabel.textContent = "Категория товаров";
      categoryWrap.appendChild(categoryLabel);
    
      const categorySelect = document.createElement("select");
      categorySelect.className = "form-control";
      categorySelect.style.width = "100%";
    
      const emptyOption = document.createElement("option");
      emptyOption.value = "";
      emptyOption.textContent = "Выберите категорию";
      categorySelect.appendChild(emptyOption);
    
      // используем this.categories (у тебя там top_level категории)
      this.categories.forEach(ctg => {
        const opt = document.createElement("option");
        opt.value = ctg.ikea_id;
        opt.textContent = ctg.name;
        if (String(block.slider_category_id || "") === String(ctg.ikea_id)) {
          opt.selected = true;
        }
        categorySelect.appendChild(opt);
      });
    
      categoryWrap.appendChild(categorySelect);
      container.appendChild(categoryWrap);
    
      // --- PRODUCTS SEARCH + LIST ---
      const productsWrap = document.createElement("div");
      productsWrap.className = "block-field";
      productsWrap.style.marginTop = "12px";
    
      const productsLabel = document.createElement("label");
      productsLabel.textContent = "Товары";
      productsWrap.appendChild(productsLabel);
    
      const hint = document.createElement("div");
      hint.className = "text-muted";
      hint.style.fontSize = "12px";
      hint.style.marginBottom = "6px";
      hint.textContent = options.hint || "Выберите категорию или начните вводить название или SKU (минимум 3 символа) для глобального поиска.";
      productsWrap.appendChild(hint);
    
      const searchInput = document.createElement("input");
      searchInput.type = "text";
      searchInput.placeholder = "Поиск товара (название или SKU)...";
      searchInput.className = "form-control";
      searchInput.style.width = "100%";
      productsWrap.appendChild(searchInput);
    
      const dropdown = document.createElement("div");
      dropdown.className = "block-products-dropdown";
      dropdown.style.position = "relative";
      dropdown.style.width = "100%";
    
      const list = document.createElement("div");
      list.className = "block-products-dropdown-list";
      list.style.border = "1px solid #ddd";
      list.style.borderTop = "none";
      list.style.background = "#fff";
      list.style.maxHeight = "240px";
      list.style.overflow = "auto";
      list.style.display = "none";
      list.style.zIndex = "10";
    
      dropdown.appendChild(list);
      productsWrap.appendChild(dropdown);
    
      const selectedWrap = document.createElement("div");
      selectedWrap.className = "block-products-selected";
      selectedWrap.style.display = "flex";
      selectedWrap.style.flexWrap = "wrap";
      selectedWrap.style.gap = "6px";
      selectedWrap.style.marginTop = "10px";
      productsWrap.appendChild(selectedWrap);
    
      container.appendChild(productsWrap);
    
      // локальное состояние
      let currentProducts = [];
      const selectedSkus = new Set(Array.isArray(block.slider_product_skus) ? block.slider_product_skus : []);
      let selectedProducts = Array.isArray(block.selected_products) ? block.selected_products.slice() : [];
    
      const renderSelected = () => {
        selectedWrap.innerHTML = "";
        if (selectedSkus.size === 0) {
          const empty = document.createElement("div");
          empty.className = "text-muted";
          empty.style.fontSize = "12px";
          empty.textContent = "Товары не выбраны";
          selectedWrap.appendChild(empty);
          return;
        }
    
        selectedSkus.forEach(sku => {
          const chip = document.createElement("span");
          chip.style.display = "inline-flex";
          chip.style.alignItems = "center";
          chip.style.gap = "6px";
          chip.style.padding = "6px 10px";
          chip.style.borderRadius = "14px";
          chip.style.border = "1px solid #ddd";
          chip.style.background = "#fff";
          chip.style.fontSize = "12px";
    
          const product = currentProducts.find(p => String(p.sku) === String(sku)) || selectedProducts.find(p => String(p.sku) === String(sku));
          const label = document.createElement("span");
          label.textContent = product ? `${product.name} (${product.sku})` : String(sku);
          chip.appendChild(label);
    
          const removeBtn = document.createElement("button");
          removeBtn.type = "button";
          removeBtn.textContent = "×";
          removeBtn.style.border = "none";
          removeBtn.style.background = "transparent";
          removeBtn.style.cursor = "pointer";
          removeBtn.style.fontSize = "16px";
          removeBtn.style.lineHeight = "1";
          removeBtn.addEventListener("click", () => {
            selectedSkus.delete(sku);
            selectedProducts = selectedProducts.filter(product => String(product.sku) !== String(sku));
            this.blocks[index].slider_product_skus = Array.from(selectedSkus);
            this.blocks[index].selected_products = selectedProducts.slice();
            this.syncHiddenField();
            renderSelected();
          });
    
          chip.appendChild(removeBtn);
          selectedWrap.appendChild(chip);
        });
      };
    
      const closeList = () => { list.style.display = "none"; };
      const openList = () => { if (list.childElementCount > 0) list.style.display = "block"; };
    
      const renderList = (items) => {
        list.innerHTML = "";
        if (!items || items.length === 0) {
          const empty = document.createElement("div");
          empty.style.padding = "10px";
          empty.className = "text-muted";
          empty.style.fontSize = "12px";
          empty.textContent = "Ничего не найдено";
          list.appendChild(empty);
          return;
        }
    
        items.forEach(item => {
          const row = document.createElement("div");
          row.style.padding = "10px";
          row.style.cursor = "pointer";
          row.style.borderBottom = "1px solid #f0f0f0";
          row.textContent = `${item.name} (${item.sku})`;
    
          if (selectedSkus.has(item.sku)) {
            row.style.opacity = "0.5";
          }
    
          row.addEventListener("click", () => {
            if (selectedSkus.has(item.sku)) return;
            selectedSkus.add(item.sku);
    
            // добавляем в локальный кэш, чтобы renderSelected знал имя
            if (!currentProducts.find(p => p.sku === item.sku)) {
              currentProducts.push(item);
            }
            if (!selectedProducts.find(p => String(p.sku) === String(item.sku))) {
              selectedProducts.push(item);
            }

            this.blocks[index].slider_product_skus = Array.from(selectedSkus);
            this.blocks[index].selected_products = selectedProducts.slice();
            this.syncHiddenField();
            renderSelected();
    
            searchInput.value = "";
            closeList();
          });
    
          list.appendChild(row);
        });
      };
    
      let searchTimeout = null;

      const applyFilter = async () => {
        const q = (searchInput.value || "").trim().toLowerCase();
        if (!q) {
          closeList();
          return;
        }

        // Если категория выбрана — фильтруем локально
        if (categorySelect.value) {
          const filtered = currentProducts
            .filter(p => {
              const haystack = [p.name, p.sku, p.small_desc_name]
                .map(value => String(value || "").toLowerCase());
              return haystack.some(value => value.includes(q));
            })
            .slice(0, 50);
          renderList(filtered);
          openList();
          return;
        }

        // Если категория не выбрана — глобальный поиск (с дебаунсом)
        if (q.length < 3) {
          closeList();
          return;
        }

        if (searchTimeout) clearTimeout(searchTimeout);
        searchTimeout = setTimeout(async () => {
          const globalResults = await this.searchProductsGlobal(q);
          renderList(globalResults);
          openList();
        }, 300);
      };
    
      // события поиска
      searchInput.addEventListener("input", applyFilter);
      searchInput.addEventListener("focus", applyFilter);
      if (this._documentClickHandler) {
        document.removeEventListener("click", this._documentClickHandler);
      }
      this._documentClickHandler = (e) => {
        if (!container.contains(e.target)) closeList();
      };
      document.addEventListener("click", this._documentClickHandler);
    
      // подгружаем товары при выборе категории
      const loadCategory = async (categoryId) => {
        // фиксируем в блок
        this.blocks[index].slider_category_id = categoryId || null;
    
        // при смене категории логично сбросить выбранные товары
        selectedSkus.clear();
        selectedProducts = [];
        this.blocks[index].slider_product_skus = [];
        this.blocks[index].selected_products = [];
        this.syncHiddenField();
    
        currentProducts = [];
        renderSelected();
    
        searchInput.value = "";
        closeList();
    
        if (!categoryId) return;
    
        const products = await this.fetchProductsByCategory(categoryId);
        currentProducts = Array.isArray(products) ? products : [];
        renderSelected(); // теперь чипы будут показывать name (если вдруг что-то восстановится)
      };
    
      categorySelect.addEventListener("change", async (e) => {
        await loadCategory(e.target.value);
      });
    
      // initial load если категория уже была сохранена
      (async () => {
        const initialCategory = block.slider_category_id;
        if (initialCategory) {
          // важно: НЕ сбрасываем выбранное при первом рендере
          const products = await this.fetchProductsByCategory(initialCategory);
          currentProducts = Array.isArray(products) ? products : [];
          selectedProducts = selectedProducts.concat(
            currentProducts.filter(product => selectedSkus.has(String(product.sku)))
          ).filter((product, idx, arr) => arr.findIndex(other => String(other.sku) === String(product.sku)) === idx);
          this.blocks[index].selected_products = selectedProducts.slice();
          renderSelected();
        } else {
          renderSelected();
        }
      })();
    
      return container;
    }    

    buildCategoriesGridSettings(block, index) {
      const container = document.createElement("div");
      container.className = "block-categories-grid-settings";
      container.style.marginTop = "12px";
      container.style.padding = "12px";
      container.style.border = "1px solid #e5e5e5";
      container.style.borderRadius = "6px";
      container.style.background = "#fafafa";

      const title = document.createElement("strong");
      title.textContent = "Настройки сетки категорий";
      container.appendChild(title);

      const gridWrap = document.createElement("div");
      gridWrap.className = "block-field";
      gridWrap.style.marginTop = "10px";

      const label = document.createElement("label");
      label.textContent = "Выберите категории для отображения";
      gridWrap.appendChild(label);

      const selectedIds = new Set(Array.isArray(block.grid_category_ids) ? block.grid_category_ids : []);

      const selectedWrap = document.createElement("div");
      selectedWrap.style.display = "flex";
      selectedWrap.style.flexWrap = "wrap";
      selectedWrap.style.gap = "6px";
      selectedWrap.style.marginTop = "10px";
      selectedWrap.style.marginBottom = "10px";

      const renderSelected = () => {
        selectedWrap.innerHTML = "";
        if (selectedIds.size === 0) {
          selectedWrap.textContent = "Категории не выбраны";
          return;
        }

        selectedIds.forEach(id => {
          const ctg = this.categories.find(c => String(c.ikea_id) === String(id));
          const chip = document.createElement("span");
          chip.style.display = "inline-flex";
          chip.style.alignItems = "center";
          chip.style.gap = "6px";
          chip.style.padding = "4px 8px";
          chip.style.background = "#fff";
          chip.style.border = "1px solid #ddd";
          chip.style.borderRadius = "4px";
          chip.style.fontSize = "12px";

          chip.textContent = ctg ? ctg.name : id;

          const removeBtn = document.createElement("button");
          removeBtn.type = "button";
          removeBtn.textContent = "×";
          removeBtn.style.border = "none";
          removeBtn.style.background = "transparent";
          removeBtn.style.cursor = "pointer";
          removeBtn.addEventListener("click", () => {
            selectedIds.delete(id);
            this.blocks[index].grid_category_ids = Array.from(selectedIds);
            this.syncHiddenField();
            renderSelected();
          });
          chip.appendChild(removeBtn);
          selectedWrap.appendChild(chip);
        });
      };

      const select = document.createElement("select");
      select.className = "form-control";
      select.style.width = "100%";
      const emptyOpt = document.createElement("option");
      emptyOpt.value = "";
      emptyOpt.textContent = "Добавить категорию...";
      select.appendChild(emptyOpt);

      this.categories.forEach(ctg => {
        const opt = document.createElement("option");
        opt.value = ctg.ikea_id;
        opt.textContent = ctg.name;
        select.appendChild(opt);
      });

      select.addEventListener("change", (e) => {
        const id = e.target.value;
        if (id && !selectedIds.has(id)) {
          selectedIds.add(id);
          this.blocks[index].grid_category_ids = Array.from(selectedIds);
          this.syncHiddenField();
          renderSelected();
        }
        e.target.value = "";
      });

      gridWrap.appendChild(selectedWrap);
      gridWrap.appendChild(select);
      container.appendChild(gridWrap);

      renderSelected();
      return container;
    }

    buildBlockHeader(block, index) {
      const header = document.createElement("div");
      header.className = "block-card-header";

      const title = document.createElement("strong");
      title.textContent = `Блок ${index + 1}`;
      header.appendChild(title);

      const select = document.createElement("select");
      select.className = "block-card-template-select";
      this.templates.forEach(template => {
        const option = document.createElement("option");
        option.value = template.id;
        option.textContent = template.label;
        if (template.id === block.type) {
          option.selected = true;
        }
        select.appendChild(option);
      });
      select.addEventListener("change", event => {
        this.changeBlockTemplate(index, event.target.value);
      });
      header.appendChild(select);

      const moveControls = document.createElement("div");
      moveControls.className = "block-move-controls";

      const upButton = document.createElement("button");
      upButton.type = "button";
      upButton.className = "block-move-button";
      upButton.textContent = "↑";
      upButton.title = "Переместить вверх";
      upButton.addEventListener("click", () => this.moveBlock(index, -1));
      moveControls.appendChild(upButton);

      const downButton = document.createElement("button");
      downButton.type = "button";
      downButton.className = "block-move-button";
      downButton.textContent = "↓";
      downButton.title = "Переместить вниз";
      downButton.addEventListener("click", () => this.moveBlock(index, 1));
      moveControls.appendChild(downButton);

      header.appendChild(moveControls);

      const removeButton = document.createElement("button");
      removeButton.type = "button";
      removeButton.className = "block-card-remove";
      removeButton.textContent = "Удалить";
      removeButton.addEventListener("click", () => this.removeBlock(index));
      header.appendChild(removeButton);

      return header;
    }

    buildContentField(block, index) {
      const container = document.createElement("div");
      container.className = "block-content-field";

      const label = document.createElement("label");
      label.textContent = "Контент блока";
      container.appendChild(label);

      const textarea = document.createElement("textarea");
      textarea.id = `block-content-${index}`;
      textarea.dataset.blockIndex = index;
      textarea.className = "content-article-block-content";
      textarea.value = block.content || "";
      textarea.addEventListener("input", () => {
        this.updateBlockContent(index, textarea.value);
      });
      textarea.placeholder = "Введите текст блока";
      container.appendChild(textarea);

      return container;
    }

    buildButtonSettings(block, index) {
      const container = document.createElement("div");
      container.className = "block-button-settings";

      const textWrapper = document.createElement("div");
      textWrapper.className = "block-field";
      const textLabel = document.createElement("label");
      textLabel.textContent = "Текст кнопки";
      textWrapper.appendChild(textLabel);

      const textInput = document.createElement("input");
      textInput.type = "text";
      textInput.value = block.button_text || "";
      textInput.placeholder = "Например, Подробнее";
      textInput.addEventListener("input", event => {
        this.blocks[index].button_text = event.target.value;
        this.syncHiddenField();
      });
      textWrapper.appendChild(textInput);
      container.appendChild(textWrapper);

      const selectWrapper = document.createElement("div");
      selectWrapper.className = "block-field";
      const selectLabel = document.createElement("label");
      selectLabel.textContent = "Категория";
      selectWrapper.appendChild(selectLabel);

      const select = document.createElement("select");
      const emptyOption = document.createElement("option");
      emptyOption.value = "";
      emptyOption.textContent = "Категория не выбрана";
      select.appendChild(emptyOption);
      this.categories.forEach(category => {
        const option = document.createElement("option");
        option.value = category.ikea_id;
        option.textContent = category.name;
        if (category.ikea_id === block.button_category_id) {
          option.selected = true;
        }
        select.appendChild(option);
      });
      select.addEventListener("change", event => {
        this.blocks[index].button_category_id = event.target.value || null;
        this.syncHiddenField();
      });
      selectWrapper.appendChild(select);
      container.appendChild(selectWrapper);

      return container;
    }

    pullSignedIdsFromForm() {
      // пробегаем по всем карточкам блоков в DOM
      const cards = this.container.querySelectorAll(".content-article-block-card");
    
      cards.forEach(card => {
        const blockIndex = Number(card.dataset.blockIndex);
        if (Number.isNaN(blockIndex)) return;
    
        // все file inputs (по слотам)
        const fileInputs = card.querySelectorAll("input[type='file'][data-block-image-slot]");
    
        fileInputs.forEach(fileInput => {
          const slot = fileInput.dataset.blockImageSlot;
          if (!slot) return;
    
          // ActiveStorage создаёт hidden с тем же name, что и у file input
          // либо рядом, либо внутри поля
          let hidden =
            card.querySelector(`input[type="hidden"][name="${fileInput.name}"]`) ||
            (fileInput.nextElementSibling?.type === "hidden" ? fileInput.nextElementSibling : null);
    
          if (!hidden || !hidden.value) return;
    
          // НЕ ререндерим блоки на сабмите — просто обновляем данные
          const block = this.blocks[blockIndex];
          if (!block) return;
    
          block.images = (block.images || []).map(img => {
            if (img.slot === slot) {
              return { ...img, signed_id: hidden.value };
            }
            return img;
          });
        });
      });
    }

    buildImageFields(block, index) {
      const container = document.createElement("div");
      container.className = "block-image-grid";

      block.images.forEach(image => {
        const field = document.createElement("div");
        field.className = "block-image-field";

      const template = this.templates.find(t => t.id === block.type);
      const slotInfo =
        template && Array.isArray(template.image_slots)
          ? template.image_slots.find(slot => slot.name === image.slot)
          : null;
      const label = document.createElement("label");
      label.textContent = (slotInfo && slotInfo.label) || image.slot;
        field.appendChild(label);

        const previewContainer = document.createElement("div");
        previewContainer.className = "block-image-preview-container";
        previewContainer.dataset.slot = image.slot;
        previewContainer.style.marginBottom = "10px";
        
        // CURRENT preview (gray)
        const currentPreview = document.createElement("div");
        currentPreview.className = "block-image-preview-current";
        currentPreview.style.marginBottom = "10px";
        currentPreview.style.padding = "10px";
        currentPreview.style.background = "#f8f9fa";
        currentPreview.style.borderRadius = "4px";
        
        const currentImg = document.createElement("img");
        currentImg.className = "block-image-preview-current-img";
        currentImg.style.maxWidth = "400px";
        currentImg.style.maxHeight = "300px";
        currentImg.style.display = "block";
        currentImg.style.margin = "0 auto";
        currentImg.style.border = "1px solid #ddd";
        currentImg.style.borderRadius = "4px";
        
        const currentCaption = document.createElement("p");
        currentCaption.textContent = "Текущее изображение";
        currentCaption.style.textAlign = "center";
        currentCaption.style.marginTop = "10px";
        currentCaption.style.color = "#666";
        currentCaption.style.fontSize = "12px";
        
        currentPreview.appendChild(currentImg);
        currentPreview.appendChild(currentCaption);
        
        // NEW preview (green, hidden by default)
        const newPreview = document.createElement("div");
        newPreview.className = "block-image-preview-new";
        newPreview.style.display = "none";
        newPreview.style.marginBottom = "10px";
        newPreview.style.padding = "10px";
        newPreview.style.background = "#e8f5e9";
        newPreview.style.borderRadius = "4px";
        
        const newImg = document.createElement("img");
        newImg.className = "block-image-preview-new-img";
        newImg.style.maxWidth = "400px";
        newImg.style.maxHeight = "300px";
        newImg.style.display = "block";
        newImg.style.margin = "0 auto";
        newImg.style.border = "1px solid #4caf50";
        newImg.style.borderRadius = "4px";
        
        const newCaption = document.createElement("p");
        newCaption.textContent = "Предпросмотр нового изображения";
        newCaption.style.textAlign = "center";
        newCaption.style.marginTop = "10px";
        newCaption.style.color = "#2e7d32";
        newCaption.style.fontSize = "12px";
        newCaption.style.fontWeight = "bold";
        
        newPreview.appendChild(newImg);
        newPreview.appendChild(newCaption);
        
        // Fill CURRENT if present, else show placeholder
        const persistedUrl = (!image.url && image.signed_id) ? this.blobRedirectUrl(image) : null;

        if (image.url || persistedUrl) {
          currentImg.src = image.url || persistedUrl;
          currentPreview.style.display = "block";
        } else {
          currentPreview.style.display = "block";
          currentImg.remove();
          const placeholder = document.createElement("span");
          placeholder.textContent = "Нет изображения";
          placeholder.className = "text-muted";
          currentPreview.insertBefore(placeholder, currentCaption);
          currentCaption.textContent = "Текущее изображение отсутствует";
        }
        
        previewContainer.appendChild(currentPreview);
        previewContainer.appendChild(newPreview);
        field.appendChild(previewContainer);

        const fileInput = document.createElement("input");
        fileInput.name = `content_article[body_block_images_uploads][${index}][${image.slot}]`;
        fileInput.type = "file";
        fileInput.accept = "image/*";
        fileInput.dataset.blockImageSlot = image.slot;
        fileInput.dataset.blockIndex = index;
        if (this.directUploadUrl) {
          fileInput.dataset.directUploadUrl = this.directUploadUrl;
        }
        field.appendChild(fileInput);

        // Instant preview on file select (before direct upload success)
        fileInput.addEventListener("change", (e) => {
          const file = e.target.files && e.target.files[0];
          const container = field.querySelector(".block-image-preview-container");
          if (!container) return;

          const curr = container.querySelector(".block-image-preview-current");
          const next = container.querySelector(".block-image-preview-new");
          const nextImg = container.querySelector(".block-image-preview-new-img");

          if (!file) {
            // no file selected -> revert to current
            if (next) next.style.display = "none";
            if (curr) curr.style.display = "block";
            return;
          }

          // show new preview and hide current
          if (curr) curr.style.display = "none";
          if (next) next.style.display = "block";

          // preview via object URL (fast) + revoke later
          const objectUrl = URL.createObjectURL(file);
          if (nextImg) nextImg.src = objectUrl;

          // avoid memory leak
          if (nextImg) {
            nextImg.onload = () => {
              try { URL.revokeObjectURL(objectUrl); } catch (_) {}
            };
          }
        });

        const actions = document.createElement("div");
        actions.className = "block-image-actions";
        const clearButton = document.createElement("button");
        clearButton.type = "button";
        clearButton.textContent = "Удалить изображение";
        clearButton.addEventListener("click", () => this.clearImage(index, image.slot));
        actions.appendChild(clearButton);
        field.appendChild(actions);

        container.appendChild(field);
      });

      return container;
    }

    changeBlockTemplate(index, templateId) {
      const existing = this.blocks[index];
      const nextBlock = this.createBlockFromTemplate(templateId, existing);
      if (!nextBlock) return;
      this.blocks[index] = nextBlock;
      this.renderBlocks();
    }

    updateBlockContent(index, value, options = {}) {
      this.blocks[index].content = value;
      this.syncHiddenField();
    }

    removeBlock(index) {
      this.blocks.splice(index, 1);
      this.renderBlocks();
    }

    moveBlock(index, direction) {
      const newIndex = index + direction;
      if (newIndex < 0 || newIndex >= this.blocks.length) return;
      const [block] = this.blocks.splice(index, 1);
      this.blocks.splice(newIndex, 0, block);
      this.renderBlocks();
    }

    clearImage(blockIndex, slot) {
      const block = this.blocks[blockIndex];
      block.images = block.images.map(image => {
        if (image.slot === slot) {
          return { ...image, signed_id: null, url: null };
        }
        return image;
      });
      this.renderBlocks();
    }

    setImageValue(blockIndex, slot, signedId, previewUrl, filename) {
      const block = this.blocks[blockIndex];
      block.images = block.images.map(image => {
        if (image.slot === slot) {
          return { ...image, signed_id: signedId, url: previewUrl || image.url, filename: filename || image.filename };
        }
        return image;
      });
      this.renderBlocks();
    }

    handleDirectUploadSuccess(input, detail) {
      const blockEl = input.closest(".content-article-block-card");
      const slot = input.dataset.blockImageSlot;
      if (!blockEl || !slot) return;
    
      const blockIndex = Number(blockEl.dataset.blockIndex);
      if (Number.isNaN(blockIndex)) return;
    
      const uploadId = detail?.id;
    
      // 1) сначала пробуем достать signed_id напрямую из detail (на случай если версия rails его кладёт)

      const hidden = input
        .closest(".block-image-field")
        ?.querySelector(`input[type="hidden"][name="${input.name}"]`);

      let signedId = detail?.signed_id || detail?.signedId || hidden?.value;
    
      // 2) если нет — ищем hidden, который ActiveStorage добавляет при direct upload
      if (!signedId) {
        // чаще всего hidden выглядит как:
        // <input type="hidden" value="SIGNED_ID" data-direct-upload-id="...">
        const field = input.closest(".block-image-field");
    
        let hiddenInput = null;
    
        if (uploadId && field) {
          hiddenInput = field.querySelector(`input[type="hidden"][data-direct-upload-id="${uploadId}"]`);
        }
    
        // fallback: иногда hidden просто рядом
        if (!hiddenInput && input.nextElementSibling && input.nextElementSibling.type === "hidden") {
          hiddenInput = input.nextElementSibling;
        }
    
        // fallback: любой hidden внутри поля
        if (!hiddenInput && field) {
          hiddenInput = field.querySelector(`input[type="hidden"][data-direct-upload-id]`) || field.querySelector(`input[type="hidden"]`);
        }
    
        signedId = hiddenInput ? hiddenInput.value : null;
      }
    
      if (!signedId) {
        // чтобы не гадать — можно временно включить лог
        console.warn("No signed_id found for direct upload", { detail, input });
        return;
      }
    
      const file = detail?.file || input.files?.[0];
      const previewUrl = file ? URL.createObjectURL(file) : null;
      const filename = file ? file.name : null;
      
      this.setImageValue(blockIndex, slot, signedId, previewUrl, filename);
    
      // очищаем input чтобы не было повторной отправки
      input.value = "";
    }

    flushBodyBlockEditorsToState() {
      if (!this.blockList || !Array.isArray(this.blocks)) return;
      if (window.tinymce && typeof tinymce.triggerSave === "function") {
        tinymce.triggerSave();
      }
      this.blockList.querySelectorAll(".content-article-block-content").forEach(el => {
        const idx = parseInt(el.dataset.blockIndex, 10);
        if (Number.isNaN(idx) || idx < 0 || idx >= this.blocks.length) return;
        const ed = window.tinymce && typeof tinymce.get === "function" ? tinymce.get(el.id) : null;
        if (ed) {
          if (typeof ed.save === "function") {
            ed.save();
          }
          this.blocks[idx].content = ed.getContent();
        } else if (el.value !== undefined) {
          this.blocks[idx].content = el.value;
        }
      });
    }

    serializeBlocks() {
      this.flushBodyBlockEditorsToState();
      return this.blocks.map((block, index) => ({
        type: block.type,
        content: block.content,
        button_text: block.button_text,
        button_category_id: block.button_category_id || null,
        slider_enabled: !!block.slider_enabled,
        button_enabled: !!block.button_enabled,
        products_grid_enabled: !!block.products_grid_enabled,
        categories_grid_enabled: !!block.categories_grid_enabled,
        slider_category_id: block.slider_category_id || null,
        slider_product_skus: Array.isArray(block.slider_product_skus) ? block.slider_product_skus : [],
        grid_category_ids: Array.isArray(block.grid_category_ids) ? block.grid_category_ids : [],
        images: block.images.map(image => ({
          slot: image.slot,
          signed_id: image.signed_id,
          filename: image.filename || null
        })),
        position: index
      }));
    }

    destroy() {
      if (this._submitHandler && this._boundForm) {
        this._boundForm.removeEventListener("submit", this._submitHandler, true);
        this._boundForm.removeEventListener("turbo:submit-start", this._submitHandler);
      }
      if (this._documentClickHandler) {
        document.removeEventListener("click", this._documentClickHandler);
      }
      if (window.tinymce && this.blockList) {
        this.blockList.querySelectorAll('.content-article-block-content').forEach(el => {
          tinymce.remove(`#${el.id}`);
        });
      }
    }

    syncHiddenField() {
      if (!this.hiddenField) return;
      this.hiddenField.value = JSON.stringify(this.serializeBlocks());
    }

    attachSubmitSync() {
      const form = this.container.closest("form");
      if (!form) return;

      if (this._submitHandler && this._boundForm) {
        this._boundForm.removeEventListener("submit", this._submitHandler, true);
        this._boundForm.removeEventListener("turbo:submit-start", this._submitHandler);
      }

      this._boundForm = form;
      this._submitHandler = () => {
        this.flushBodyBlockEditorsToState();
        this.pullSignedIdsFromForm();
        this.syncHiddenField();
      };

      // capture: true — до других обработчиков (в т.ч. Turbo), чтобы скрытое JSON-поле уже содержало актуальный HTML
      form.addEventListener("submit", this._submitHandler, true);
      form.addEventListener("turbo:submit-start", this._submitHandler);
    }

    blobRedirectUrl(image) {
      if (!image?.signed_id) return null;
      const filename = image.filename || "image";
      return `/rails/active_storage/blobs/redirect/${encodeURIComponent(image.signed_id)}/${encodeURIComponent(filename)}`;
    }
  }
})();
