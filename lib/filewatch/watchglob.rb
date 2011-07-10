require "filewatch/namespace"
require "filewatch/exception"
require "filewatch/watch"

class FileWatch::WatchGlob
  attr_accessor :logger

  public
  def initialize
    @globs = {}
    @logger = Logger.new(STDERR)
  end

  public
  def watch(glob, *what_to_watch)
    @globs[glob] = {
      :last => [],
      :watch => what_to_watch,
    }
  end

  public
  def each(&block)
    @globs.each do |glob, state|
      res = Dir.glob(glob)
      if res == state[:last]
        next
      end

      # created files
      if state[:watch].member?(:create)
        (res - state[:last]).each do |new_path|
          yield(new_path, :create)
        end
      end

      # deleted files
      if state[:watch].member?(:delete)
        (state[:last] - res).each do |old_path|
          yield(old_path, :delete)
        end
      end

      @globs[glob][:last] = res
    end
  end # def each

  def subscribe(opts, &block)
    opts[:poll_interval] ||= 1
    loop do
      each(&block)

      sleep(opts[:poll_interval])
    end
  end # def subscribe
end # class FileWatch::Watch
