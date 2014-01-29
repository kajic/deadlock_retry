require 'active_support/core_ext/module/attribute_accessors'

module DeadlockRetry
  def self.included(base)
    base.extend(ClassMethods)
    base.class_eval do
      class << self
        alias_method_chain :transaction, :deadlock_handling
      end
    end
  end

  module ClassMethods
    DEADLOCK_ERROR_MESSAGES = [
      "Deadlock found when trying to get lock",
      "Lock wait timeout exceeded",
      "deadlock detected"
    ]

    MAXIMUM_RETRIES_ON_DEADLOCK = 5

    def transaction_with_deadlock_handling(*objects, &block)
      retry_count = 0

      begin
        transaction_without_deadlock_handling(*objects, &block)
      rescue ActiveRecord::StatementInvalid => error
        raise if in_nested_transaction?
        if DEADLOCK_ERROR_MESSAGES.any? { |msg| error.message =~ /#{Regexp.escape(msg)}/ }
          raise if retry_count >= MAXIMUM_RETRIES_ON_DEADLOCK
          retry_count += 1
          logger.info "Deadlock detected on attempt #{retry_count}, restarting transaction."
          incremental_pause(retry_count)
          retry
        else
          raise
        end
      end
    end

    private

    WAIT_TIMES = [1, 2, 3, 4, 5]

    def incremental_pause(count)
      sec = WAIT_TIMES[count-1] || 5
      sleep(sec)
    end

    def in_nested_transaction?
      # open_transactions was added in 2.2's connection pooling changes.
      connection.open_transactions != 0
    end

  end
end

ActiveRecord::Base.send(:include, DeadlockRetry) if defined?(ActiveRecord)
