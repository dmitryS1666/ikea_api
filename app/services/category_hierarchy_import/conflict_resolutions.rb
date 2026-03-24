# frozen_string_literal: true

module CategoryHierarchyImport
  module ConflictResolutions
    CATEGORY_CONFLICT_RESOLUTIONS = {
      "55031" => { parent_ids: %w[st001 46053], translated_name: "Напольные шкафы BESTÅ" },
      "16274" => { parent_ids: %w[st007], translated_name: "Плечики и вешалки для одежды" },
      "21829" => { parent_ids: %w[fu004], translated_name: "Раскладные столы" },
      "700386" => { parent_ids: %w[ka001 ka005 23598 50005], translated_name: "Фасады для кухни коричнево-бежевые HAVSTORP" },
      "700175" => { parent_ids: %w[ka001], translated_name: "Портативная бытовая техника" },
      "20535" => { parent_ids: %w[tl001 20533], translated_name: "Пуховые подушки" },
      "fu003" => { parent_ids: %w[700640], translated_name: "Диваны нераскладные" },
      "700220" => { parent_ids: %w[tl002], translated_name: "Тюль" },
      "10732" => { parent_ids: %w[li001], translated_name: "Настольные лампы" },
      "36812" => { parent_ids: %w[li001], translated_name: "Системы умного освещения" },
      "10757" => { parent_ids: %w[de001], translated_name: "Настенные украшения" },
      "fu004" => { parent_ids: [], translated_name: "Рабочие столы и кресла" },
      "20636" => { parent_ids: %w[16043], translated_name: "Посуда, формы для выпечки и запекания" },
      "700610" => { parent_ids: %w[16043], translated_name: "Контейнеры для хранения продуктов" },
      "700513" => { parent_ids: %w[bm001], translated_name: "Кровати" },

      "50005" => { parent_ids: %w[ka001 ka005 23598], translated_name: "Готовые комбинации кухонь METOD" },
      "ka004" => { parent_ids: %w[ka001], translated_name: "Модульные кухни ENHET" },
      "700712" => { parent_ids: %w[ka001], translated_name: "Варочные панели" },
      "50388" => { parent_ids: %w[ka001 ka005 ka002], translated_name: "Холодильники и морозильные камеры METOD" },
      "700536" => { parent_ids: %w[ka001 700533], translated_name: "Раковины, краны и смесители для кухни ÖNNERUP" },
      "de001" => { parent_ids: [], translated_name: "Декор" },
      "20631" => { parent_ids: %w[16043], translated_name: "Вок-сковороды" },
      "15947" => { parent_ids: %w[16043], translated_name: "Разделочные доски" },
      "18860" => { parent_ids: %w[16043], translated_name: "Посуда для сервировки" },
      "21957" => { parent_ids: %w[hi001], translated_name: "Полы, настилы для балконов и террас" },
      "18692" => { parent_ids: %w[bc001 18690], translated_name: "Детское постельное белье" },
      "10573" => { parent_ids: %w[st007], translated_name: "Товары, принадлежности для офиса" },
      "54992" => { parent_ids: %w[bm001], translated_name: "Комплекты мебели для спальни" },
      "21967" => { parent_ids: %w[od001], translated_name: "Мебель для дачи, сада и балкона" },
      "21960" => { parent_ids: %w[od001 21967 21964], translated_name: "Стулья и табуреты для балкона и террасы" },
      "20498" => { parent_ids: %w[ba001], translated_name: "Зеркала для ванной" },
      "20615" => { parent_ids: %w[st007], translated_name: "Полки и аксессуары для ванной комнаты" },
      "700491" => { parent_ids: %w[ba001 700458], translated_name: "Комплекты мебели для ванной комнаты ENHET" },
      "20808" => { parent_ids: %w[ba001], translated_name: "Навесные шкафы в ванную комнату" },
      "20649" => { parent_ids: %w[fu004], translated_name: "Офисные столы" },
      "11844" => { parent_ids: %w[fu004 47423 11811], translated_name: "Столешницы для офисных столов" },
      "47423" => { parent_ids: %w[fu004], translated_name: "Офисные и письменные системы" }
    }.freeze
  end
end
