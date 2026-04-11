# frozen_string_literal: true

require "open3"

module Admin
  # Очистка очередей Sidekiq из админки + опциональный systemctl restart (см. ENV SIDEKIQ_SYSTEMD_*).
  class SidekiqAdminReset
    class << self
      def queue_names
        path = Rails.root.join("config/sidekiq.yml")
        return %w[parser default] unless File.exist?(path)

        raw = YAML.safe_load(
          File.read(path),
          permitted_classes: [Symbol],
          aliases: true
        )
        return %w[parser default] unless raw.is_a?(Hash)

        raw = raw.with_indifferent_access
        list = Array(raw[:queues])
        names = list.map(&:to_s).uniq.reject(&:blank?)
        names.presence || %w[parser default]
      end

      # @return [Hash] отчёт: { queues: { "name" => было_джоб }, retry:, scheduled:, dead: }
      def purge_queues_and_sets!
        require "sidekiq/api"

        report = { queues: {}, retry: 0, scheduled: 0, dead: 0 }

        queue_names.each do |name|
          q = Sidekiq::Queue.new(name)
          report[:queues][name] = q.size
          q.clear
        end

        r = Sidekiq::RetrySet.new
        report[:retry] = r.size
        r.clear

        s = Sidekiq::ScheduledSet.new
        report[:scheduled] = s.size
        s.clear

        d = Sidekiq::DeadSet.new
        report[:dead] = d.size
        d.clear

        report
      end

      # @return [Hash] :success, :stdout, :stderr, :unit
      def restart_systemd!
        unit = ENV.fetch("SIDEKIQ_SYSTEMD_UNIT", "ikea_back_sidekiq.service")
        stdout, stderr, status = Open3.capture3("sudo", "-n", "/bin/systemctl", "restart", unit.to_s)
        { success: status.success?, stdout: stdout.to_s, stderr: stderr.to_s, unit: unit.to_s }
      end
    end
  end
end
