require "rspec_sequencing"

def formatted_puts(text)
  cfg = RSpec.configuration
  return unless cfg.formatters.first.is_a?(
        RSpec::Core::Formatters::DocumentationFormatter)
  txt = cfg.format_docstrings_block.call(text)
  cfg.output_stream.puts "    #{txt}"
end

unless RSpec::Matchers.method_defined?(:receive_call_and_args)
  RSpec::Matchers.define(:receive_call_and_args) do |m, args|
    match do |actual|
      actual.trace_for(m) == args
     end

    failure_message do
      "Expecting method #{m} to receive: #{args} but got: #{actual.trace_for(m)}"
    end
  end
end

module FileWatch

  def self.make_file_older(path, seconds)
    time = Time.now.to_f - seconds
    File.utime(time, time, path)
  end

  class TracerBase
    def initialize() @tracer = []; end

    def trace_for(symbol)
      params = @tracer.map {|k,v| k == symbol ? v : nil}.compact
      params.empty? ? false : params
    end

    def clear()
      @tracer.clear()
    end
  end

  class FileLogTracer < TracerBase
    def warn(*args) @tracer.push [:warn, args]; end
    def error(*args) @tracer.push [:error, args]; end
    def debug(*args) @tracer.push [:debug, args]; end
    def info(*args) @tracer.push [:info, args]; end

    def info?() true; end
    def debug?() true; end
    def warn?() true; end
    def error?() true; end
  end

  module NullCallable
    def self.call() end
  end

  class TailObserver
    class Listener
      attr_reader :path, :lines, :calls

      def initialize(path)
        @path = path
        @lines = []
        @calls = []
      end

      def accept(line)
        @lines << line
        @calls << :accept
      end

      def deleted()
        @calls << :delete
      end

      def created()
        @calls << :create
      end

      def error()
        @calls << :error
      end

      def eof()
        @calls << :eof
      end

      def timed_out()
        @calls << :timed_out
      end
    end

    attr_reader :listeners

    def initialize
      @listeners = Hash.new {|hash, key| hash[key] = Listener.new(key) }
    end

    def listener_for(path)
      @listeners[path]
    end

    def clear() @listeners.clear; end
  end
end
