require "filewatch/namespace"
require "filewatch/exception"
require "filewatch/tail"
require "filewatch/watchglob"
require "logger"

class FileWatch::TailGlob
  attr_accessor :logger

  public
  def initialize
    @glob = FileWatch::WatchGlob.new
    @watch = FileWatch::Tail.new
    @watching = []  # array of files we're watching
    @inodes = Hash.new { |h, k| h[k] = 0 }  # [maj,min,ino] => size

    self.logger = Logger.new(STDERR)
  end # def initialize

  def logger=(logger)
    @logger = logger
    @glob.logger = logger
    @watch.logger = logger
  end

  # Watch a path glob.
  #
  # Options is a hash of:
  #   :exclude => array of globs to ignore.
  public
  def tail(glob, options={})
    # TODO(petef): implement options[:exclude]
    @glob.watch(glob, :create)
  end # def watch

  public
  def subscribe(&block)
    # watch @glob for new files (every 5s), @watch for new lines (every 1s)

    glob_int = 5
    loop do
      if glob_int == 5
        @glob.each do |path, action, opts|
          # TODO(petef): @watch.watch() should deal with dupes
          # we don't care about :delete actions, since @watch will
          # get those, too
          if action == :create
            file_id, size = get_file_info(path)
            if size >= @inodes[file_id]
              @watch.watch(path, :position => @inodes[file_id])
            else
              @watch.watch(path, :position => 0)
            end
            @inodes[file_id] = size
          end
        end # @glob.each

        glob_int = 0
      end # glob_int == 5

      @watch.each do |path, data|
        yield(path, data)
      end

      sleep(1)
      glob_int += 1
    end # loop
  end # def subscribe

  private
  def get_file_info(path)
    s = File::Stat.new(path)
    return [s.dev_major, s.dev_minor, s.ino], s.size
  end
end # class FileWatch::Tail
