module Seo
  class CityMapper
    CITIES = {
      'minsk' => { name: 'Минск', in_city: 'в Минске' },
      'gomel' => { name: 'Гомель', in_city: 'в Гомеле' },
      'mogilev' => { name: 'Могилев', in_city: 'в Могилеве' },
      'vitebsk' => { name: 'Витебск', in_city: 'в Витебске' },
      'grodno' => { name: 'Гродно', in_city: 'в Гродно' },
      'brest' => { name: 'Брест', in_city: 'в Бресте' }
    }.freeze

    DEFAULT_CITY = 'minsk'.freeze

    def self.call(city_code)
      city_data = CITIES[city_code.to_s.downcase] || CITIES[DEFAULT_CITY]
      city_data[:in_city]
    end

    def self.city_name(city_code)
      city_data = CITIES[city_code.to_s.downcase] || CITIES[DEFAULT_CITY]
      city_data[:name]
    end
  end
end
