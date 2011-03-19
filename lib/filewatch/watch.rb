require "filewatch/inotify/fd"
require "filewatch/namespace"

class FileWatch::Watch
  # This class exists to wrap inotify, kqueue, periodic polling, etc,
  # to provide you with a way to watch files and directories.
  #
  # For now, it only supports inotify.
  def initialize
    @inotify = FileWatch::Inotify::FD.new
  end

  public
  def watch(path, *what_to_watch)
    @inotify.watch(path, *what_to_watch)
  end # def watch

  def subscribe(handler=nil, &block)
    @inotify.subscribe(handler, &block)
  end

  def each(&block)
    @inotify.each(&block)
  end # def each
end # class FileWatch::Watch
