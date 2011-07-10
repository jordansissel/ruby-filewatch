require "filewatch/namespace"
require "filewatch/stat"
require "filewatch/exception"

class FileWatch::Watch
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
