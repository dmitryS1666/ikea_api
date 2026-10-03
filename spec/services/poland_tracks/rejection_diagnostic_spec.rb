require "rails_helper"

RSpec.describe PolandTracks::RejectionDiagnostic do
  def summary(data)
    described_class.summary(JSON.generate(data))
  end

  it "extracts Laravel field errors without copying free-text values" do
    result = summary(errors: { "recipient.email" => ["The recipient.email field is required."],
                               "recipient.passport_number" => ["MP1234567 is invalid"],
                               "nomerikea" => ["The nomerikea has already been taken."] })
    expect(result).to eq("fields=recipient.email(required),recipient.passport_number(details_redacted),nomerikea(already_exists)")
  end

  it "supports nested recipient errors" do
    expect(summary(errors: { recipient: { city: ["required"] } })).to eq("fields=recipient.city(required)")
  end

  it "supports FastAPI locations and codes without input or message disclosure" do
    result = summary(detail: [{ loc: ["body", "items", 0, "price"], type: "greater_than_equal", input: "secret", msg: "secret" }])
    expect(result).to eq("fields=items.0.price(out_of_range)")
  end

  it "supports a list of field/code errors" do
    expect(summary(errors: [{ field: "pvz", code: "invalid" }])).to eq("fields=pvz(invalid_format)")
  end

  it "recognizes root weight validation errors" do
    expect(summary(errors: { "weight" => ["The weight field is required."] }))
      .to eq("fields=weight(required)")
  end

  it "supports top-level known fields but never arbitrary keys or message text" do
    expect(summary("pvz" => ["invalid"], "secret@example.com" => "required", "message" => "secret"))
      .to eq("fields=pvz(invalid_format)")
  end

  it "does not accept unknown field paths or codes even when they contain secrets" do
    result = summary(errors: { "recipient.secret@example.com" => ["required"],
                               "recipient.email" => [{ code: "Bearer secret" }] })
    expect(result).to eq("fields=recipient.email(details_redacted)")
  end

  it "marks HTML and invalid JSON unreadable without copying the body" do
    expect(described_class.summary('<html>secret</html>')).to eq("validation=unreadable_response")
  end

  it "handles unexpected JSON shapes" do
    [nil, [], 42, "secret", { errors: 123 }, { errors: [{ loc: nil }] }].each do |data|
      expect(summary(data)).to eq("validation=unrecognized_response")
    end
  end

  it "rejects oversized bodies without parsing or retaining them" do
    expect(described_class.summary("x" * 65_537)).to eq("validation=body_too_large")
  end

  it "limits diagnostic fields" do
    result = summary(errors: 30.times.to_h { |i| ["items.#{i}.price", "min"] })
    expect(result.scan(/out_of_range/).size).to eq(20)
    expect(result.length).to be < 1000
  end
end
