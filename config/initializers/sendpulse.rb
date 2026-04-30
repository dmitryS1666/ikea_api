# SendPulse transactional email configuration.
# Secrets (API key) must be provided via ENV/credentials on backend only.
SENDPULSE_CONFIG = {
  api_base_url: ENV.fetch("SENDPULSE_API_BASE_URL", "https://api.sendpulse.com"),
  from_email: ENV["SENDPULSE_FROM_EMAIL"],
  from_name: ENV.fetch("SENDPULSE_FROM_NAME", "IKEA")
}.freeze
