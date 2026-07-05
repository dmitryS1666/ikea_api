# SendPulse transactional email configuration.
# Authentication uses static SENDPULSE_API_KEY.
SENDPULSE_CONFIG = {
  api_base_url: ENV.fetch("SENDPULSE_API_BASE_URL", "https://api.sendpulse.com"),
  from_email: ENV["SENDPULSE_FROM_EMAIL"],
  from_name: ENV.fetch("SENDPULSE_FROM_NAME", "IKEYA"),
  api_key: ENV["SENDPULSE_API_KEY"]
}.freeze
