require "filewatch/yielding_tail"
require "filewatch/observing_tail"
require "forwardable"

module FileWatch
  class Tail
    extend Forwardable

    def_delegators :@target, :tail, :logger=, :subscribe, :sincedb_record_uid, :sincedb_write, :quit, :close_file

    attr_writer :target

    def self.new_observing(opts = {})
      new.tap do |instance|
        instance.target = ObservingTail.new(opts)
      end
    end

    def initialize(opts = {})
      @target = YieldingTail.new(opts)
    end
  end
end
