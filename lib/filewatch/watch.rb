require "filewatch/namespace"
require "filewatch/stat"
require "filewatch/exception"

class FileWatch::Watch
  # This class exists to wrap inotify, kqueue, periodic polling, etc,
  # to provide you with a way to watch files and directories.
  #
  # For now, it only supports stat polling.
  def initialize
    @stat = FileWatch::Stat.new
  end

  public
  def watch(path, *what_to_watch)
    return @stat.watch(path, *what_to_watch)
  end # def watch

  def subscribe(handler=nil, &block)
    @stat.subscribe(handler, &block)
  end

  def each(&block)
    @stat.each(&block)
  end # def each
end # class FileWatch::Watch
