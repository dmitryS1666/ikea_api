class SlugifyService
  CYRILLIC_TO_LATIN = {
    "а" => "a",  "б" => "b",   "в" => "v",  "г" => "g",  "д" => "d",
    "е" => "e",  "ё" => "yo",  "ж" => "zh", "з" => "z",  "и" => "i",
    "й" => "y",  "к" => "k",   "л" => "l",  "м" => "m",  "н" => "n",
    "о" => "o",  "п" => "p",   "р" => "r",  "с" => "s",  "т" => "t",
    "у" => "u",  "ф" => "f",   "х" => "h",  "ц" => "ts", "ч" => "ch",
    "ш" => "sh", "щ" => "shch","ъ" => "",   "ы" => "y",  "ь" => "",
    "э" => "e",  "ю" => "yu",  "я" => "ya"
  }.freeze

  def self.call(value)
    transliterated = value.to_s.downcase.chars.map { |ch| CYRILLIC_TO_LATIN.fetch(ch, ch) }.join
    transliterated
      .gsub(/[^a-z0-9]+/, "-")
      .gsub(/^-+|-+$/, "")
  end
end
